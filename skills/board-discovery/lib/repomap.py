"""repomap - link a host workspace (git repos, build outputs) with what runs on a board.

Used by `discover --repo`. Board side: read-only shell (sizes, sha256, first ELF bytes, strings).
Host side: git and a stat walk of the workspace; nothing is built or changed.
"""
import collections, hashlib, os, re, shlex, struct, subprocess, time

SYS = ('/bin/', '/sbin/', '/usr/bin/', '/usr/sbin/', '/lib/', '/usr/lib/', '/usr/libexec/', '/lib64/', '/usr/lib64/')
PRUNE = {'.git', 'node_modules', '__pycache__', '.cache', '.venv', 'venv'}
DATA = re.compile(r'\.(log|txt|sqlite3?|db|wal|shm|csv|bak)(\.\d+)?$|-(wal|shm|journal)$', re.I)
VERSION = re.compile(r'(?<![\w.])v?(\d+\.\d+\.\d+(?:[.-]\d+)?)(?![\w.])')

# Board: product processes -> their files. Lines "exe|arg|lib|unit PID VALUE".
ARTIFACTS = (
    "for d in /proc/[0-9]*; do p=${d#/proc/}; e=$(readlink $d/exe 2>/dev/null) || continue; s=0; "
    "case $e in " + '|'.join(x + '*' for x in SYS) + ") s=1;; esac; [ $s = 0 ] && echo \"exe $p $e\"; "
    "for a in $(tr '\\0' '\\n' 2>/dev/null <$d/cmdline | tail -n +2); do case $a in "
    + '|'.join(x + '*' for x in SYS) + "|/proc/*|/sys/*|/dev/*) ;; /*) [ -f \"$a\" ] && echo \"arg $p $a\";; esac; done; "
    "[ $s = 0 ] && awk -v p=$p '$6 ~ /\\.so/ && $6 !~ /^\\/(usr\\/)?lib(64)?\\// {print \"lib\", p, $6}' $d/maps 2>/dev/null; "
    "u=$(grep -o '[^/]*\\.service' $d/cgroup 2>/dev/null | head -n 1); [ $s = 0 ] && [ -n \"$u\" ] && echo \"unit $p $u\"; "
    "done | sort -u")

# Board: fingerprint of each file in {files}: F|path|size|sha256|mtime|first 2 KB as octal bytes when ELF
# (`od -b` is the only byte dump BusyBox and POSIX od share).
FINGERPRINT = (
    "for f in {files}; do s=$(wc -c <\"$f\" 2>/dev/null) || continue; h=-; [ \"$s\" -lt 400000000 ] && "
    "h=$(sha256sum \"$f\" | cut -d' ' -f1); m=$(date -r \"$f\" +%Y-%m-%d 2>/dev/null); "
    "x=$(dd if=\"$f\" bs=2048 count=1 2>/dev/null | od -v -b | awk '{{for(i=2;i<=NF;i++) printf \"%s.\", $i}}'); "
    "case $x in 177.105.114.106.*) ;; *) x=-;; esac; echo \"F|$f|$s|$h|$m|$x\"; done")

COMMITS = "for f in {files}; do strings -n 8 \"$f\" 2>/dev/null | grep -oE '[0-9a-f]{{8,40}}' | sort -u | head -n 400 | sed \"s|^|C|$f|\"; done"


def stem(name):
    """Comparable name: lower case, no lib prefix, no .so version, arch or debug suffix, no punctuation."""
    n = os.path.basename(name).lower()
    n = re.sub(r'\.so(\.\d+)*$', '', n)
    n = re.sub(r'\.(appimage|js|py|sh|bin|elf|exe)$', '', n)
    n = re.sub(r'[-_.](arm|arm64|aarch64|armhf|x86_64|amd64)$', '', n)
    n = re.sub(r'^lib', '', n)
    n = re.sub(r'_d$', '', n)
    return re.sub(r'[^a-z0-9]', '', n)


def git(repo, *args, stdin=None):
    p = subprocess.run(['git', '-C', repo] + list(args), input=stdin, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, text=True)
    return p.stdout if p.returncode == 0 else ''


# ---------------------------------------------------------------- host

def find_repos(root):
    root = git(root, 'rev-parse', '--show-toplevel').strip() or os.path.abspath(root)
    repos = [root]
    for d, dirs, files in os.walk(root):
        if d != root and ('.git' in dirs or '.git' in files):
            repos.append(d)
        dirs[:] = [x for x in dirs if x not in PRUNE and not x.startswith('build-')] if d.count(os.sep) - root.count(os.sep) < 4 else []
    return root, repos


def repo_state(repo, root):
    head = git(repo, 'log', '-1', '--format=%h %ad %s', '--date=short').strip()
    return {'path': os.path.relpath(repo, root), 'branch': git(repo, 'branch', '--show-current').strip() or '(detached)',
            'head': head, 'dirty': len([l for l in git(repo, 'status', '--porcelain', '-uno').split('\n') if l]),
            'remote': git(repo, 'remote', 'get-url', 'origin').strip()}


TARGET_RULES = [
    (re.compile(r'(^|/)[^/]+\.pro$'), re.compile(r'^\s*TARGET\s*=\s*([\w.$-]+)', re.M)),
    (re.compile(r'(^|/)CMakeLists\.txt$'), re.compile(r'add_(?:executable|library)\s*\(\s*([\w.-]+)')),
    (re.compile(r'(^|/)meson\.build$'), re.compile(r'(?:executable|library)\s*\(\s*[\'"]([\w.-]+)')),
    (re.compile(r'(^|/)Cargo\.toml$'), re.compile(r'^name\s*=\s*"([\w-]+)"', re.M)),
    (re.compile(r'(^|/)package\.json$'), re.compile(r'"(?:name|productName)"\s*:\s*"([^"]+)"')),
]


def build_targets(repos, root):
    """stem -> [(declared name, repo-relative file)] from the tracked build files of every repo."""
    out = collections.defaultdict(list)
    for r in repos:
        files = git(r, 'ls-files', '*.pro', '*CMakeLists.txt', '*meson.build', '*Cargo.toml', '*package.json', '*.bb', '*.service').split('\n')
        for f in filter(None, files):
            if 'node_modules/' in f:
                continue
            rel = os.path.relpath(os.path.join(r, f), root)
            names = []
            if f.endswith(('.bb', '.service')):
                names = [re.sub(r'_[^_]*$', '', os.path.basename(f)[:-3]) if f.endswith('.bb') else os.path.basename(f)]
            else:
                for fre, tre in TARGET_RULES:
                    if fre.search(f):
                        try:
                            txt = open(os.path.join(r, f), errors='replace').read(200000)
                        except OSError:
                            break
                        names = tre.findall(txt)[:3] if not f.endswith('package.json') else tre.findall(txt)[:2]
                        if f.endswith('.pro') and not names:
                            names = [os.path.basename(f)[:-4]]
                        break
            for n in names:
                n = re.sub(r'\$\$?[\w{}()]+', '', n)
                if stem(n):
                    out[stem(n)].append((n, rel))
    return out


def host_index(root):
    """basename -> [paths], stem -> [paths], ext -> [paths] for regular files in the workspace (stat only)."""
    by_name, by_stem, by_ext = (collections.defaultdict(list) for _ in range(3))
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in PRUNE]
        for f in files:
            p = os.path.join(d, f)
            by_name[f].append(p)
            by_stem[stem(f)].append(p)
            by_ext[os.path.splitext(f)[1].lower()].append(p)
    return by_name, by_stem, by_ext


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for b in iter(lambda: f.read(1 << 20), b''):
            h.update(b)
    return h.hexdigest()


def build_id(read):
    """GNU build-id from an ELF via read(offset, size) -> bytes|None, or None."""
    h = read(0, 64)
    if not h or h[:4] != b'\x7fELF':
        return None
    is64, end = h[4] == 2, '<' if h[5] == 1 else '>'
    if is64:
        phoff, phentsize, phnum = struct.unpack(end + 'Q', h[32:40])[0], *struct.unpack(end + 'HH', h[54:58])
    else:
        phoff, phentsize, phnum = struct.unpack(end + 'I', h[28:32])[0], *struct.unpack(end + 'HH', h[42:46])
    for i in range(min(phnum, 64)):
        ph = read(phoff + i * phentsize, phentsize)
        if not ph or len(ph) < phentsize:
            return None
        if struct.unpack(end + 'I', ph[:4])[0] != 4:      # PT_NOTE
            continue
        off, size = (struct.unpack(end + 'QQ', ph[8:16] + ph[32:40]) if is64
                     else struct.unpack(end + 'II', ph[4:8] + ph[16:20]))
        notes = read(off, size)
        if not notes:
            continue
        k = 0
        while k + 12 <= len(notes):
            nsz, dsz, typ = struct.unpack(end + 'III', notes[k:k + 12])
            name = notes[k + 12:k + 12 + nsz]
            d0 = k + 12 + ((nsz + 3) & ~3)
            if typ == 3 and name.rstrip(b'\0') == b'GNU':
                return notes[d0:d0 + dsz].hex()
            k = d0 + ((dsz + 3) & ~3)
    return None


def elf_payload(head, size):
    """Bytes appended after the ELF image (AppImage, self-extractor): its build-id then names only the runtime."""
    if not head or head[:4] != b'\x7fELF' or len(head) < 64:
        return 0
    end = '<' if head[5] == 1 else '>'
    if head[4] == 2:
        shoff, (shentsize, shnum) = struct.unpack(end + 'Q', head[40:48])[0], struct.unpack(end + 'HH', head[58:62])
    else:
        shoff, (shentsize, shnum) = struct.unpack(end + 'I', head[32:36])[0], struct.unpack(end + 'HH', head[46:50])
    extent = shoff + shentsize * shnum
    return size - extent if shoff and size - extent > max(1 << 20, extent // 10) else 0


def file_reader(path):
    def read(off, size):
        try:
            with open(path, 'rb') as f:
                f.seek(off)
                return f.read(size)
        except OSError:
            return None
    return read


def buf_reader(buf):
    return lambda off, size: buf[off:off + size] if off + size <= len(buf) else None


# ---------------------------------------------------------------- board

def board_artifacts(run):
    rc, out = run(100, ARTIFACTS, 60)
    arts, units = collections.OrderedDict(), {}
    for line in out.split('\n'):
        parts = line.split(' ', 2)
        if len(parts) != 3 or parts[0] not in ('exe', 'arg', 'lib', 'unit'):
            continue
        kind, pid, val = parts
        if kind == 'unit':
            units[pid] = val
        elif not DATA.search(val):
            arts.setdefault(val, {'kind': kind, 'pids': set()})['pids'].add(pid)
    for a in arts.values():
        a['units'] = sorted({units[p] for p in a['pids'] if p in units})
    return arts


def chunks(paths, n=20):
    for i in range(0, len(paths), n):
        yield ' '.join(shlex.quote(p) for p in paths[i:i + n])


def board_fingerprints(run, paths):
    fp = {}
    for i, files in enumerate(chunks(paths)):
        rc, out = run(110 + i, FINGERPRINT.format(files=files), 180)
        for line in out.split('\n'):
            p = line.split('|')
            if len(p) == 6 and p[0] == 'F':
                octs = p[5].strip('.').split('.') if p[5] not in ('-', '') else []
                # A serial console may interleave other output into the dump: then no build-id, not an error.
                elf = bytes(int(o, 8) for o in octs) if octs and all(re.fullmatch(r'[0-3][0-7]{2}', o) for o in octs) else None
                try:
                    size = int(p[2] or 0)
                except ValueError:
                    continue
                fp[p[1]] = {'size': size, 'sha': p[3], 'date': p[4], 'elf': elf}
    return fp


def board_commit_strings(run, paths):
    out = collections.defaultdict(set)
    for i, files in enumerate(chunks(paths, 10)):
        rc, txt = run(150 + i, COMMITS.format(files=files), 180)
        for line in txt.split('\n'):
            if line.startswith('C|'):
                _, f, h = line.split('|', 2)
                out[f].add(h)
    return out


# ---------------------------------------------------------------- matching

def match_artifact(path, fp, targets, idx, root, cache):
    by_name, by_stem, by_ext = idx
    st, base = stem(path), os.path.basename(path)
    cands = list(dict.fromkeys(by_name.get(base, []) + by_stem.get(st, [])))
    res = {'targets': [f'{n} ({f})' for n, f in targets.get(st, [])][:3], 'match': None, 'candidates': []}
    bid = build_id(buf_reader(fp['elf'])) if fp and fp.get('elf') else None
    res['build_id'] = bid
    res['payload'] = elf_payload(fp['elf'], fp['size']) if fp and fp.get('elf') else 0
    if fp and not cands and fp['size'] > 4096:
        # Renamed artifact: same extension and same size, else the nearest size.
        same_ext = by_ext.get(os.path.splitext(base)[1].lower(), [])
        sized = [(abs(os.path.getsize(p) - fp['size']), p) for p in same_ext if os.path.isfile(p)]
        cands = [p for d, p in sorted(sized)[:3] if d <= fp['size'] * 0.05]
        res['renamed'] = bool(cands)
    for p in cands[:20]:
        try:
            size = os.path.getsize(p)
        except OSError:
            continue
        rel, date = os.path.relpath(p, root), time.strftime('%Y-%m-%d', time.localtime(os.path.getmtime(p)))
        verdict = 'differs'
        if fp and fp['sha'] not in ('-', '') and size == fp['size']:
            if p not in cache:
                cache[p] = sha256(p)
            if cache[p] == fp['sha']:
                verdict = 'identical'
        if verdict != 'identical' and bid:
            if ('bid', p) not in cache:
                cache[('bid', p)] = build_id(file_reader(p))
            if cache[('bid', p)] == bid:
                verdict = 'same runtime only' if res['payload'] else 'same build-id'
        res['candidates'].append((verdict, rel, size, date))
    order = {'identical': 0, 'same build-id': 1, 'same runtime only': 2, 'differs': 3}
    bparts = path.split('/')[::-1]

    def shared(rel):
        n = 0
        for x, y in zip(bparts, rel.split('/')[::-1]):
            if x != y:
                break
            n += 1
        return n
    res['candidates'].sort(key=lambda c: (order[c[0]], -shared(c[1]), c[3] and -int(c[3].replace('-', ''))))
    if res['candidates'] and res['candidates'][0][0] in ('identical', 'same build-id'):
        res['match'] = res['candidates'][0]
    return res


def commits_in(repos, hexes, root):
    """{hex: [(repo rel, sha, subject, ahead-of-HEAD count)]} for strings that name commits."""
    found = collections.defaultdict(list)
    if not hexes:
        return found
    for r in repos:
        out = git(r, 'cat-file', '--batch-check=%(objectname) %(objecttype)', stdin='\n'.join(sorted(hexes)) + '\n')
        for h, line in zip(sorted(hexes), out.split('\n')):
            if line.endswith(' commit'):
                sha = line.split()[0]
                subj = git(r, 'log', '-1', '--format=%h %ad %s', '--date=short', sha).strip()
                behind = git(r, 'rev-list', '--count', f'{sha}..HEAD').strip()
                found[h].append((os.path.relpath(r, root), subj, behind))
    return found


def versions_in(repos, versions, root):
    """{version: [(repo rel, where, commit)]} for version strings seen in board paths: tracked files that
    hold it now, else a tag or the latest commit whose message names it."""
    out = collections.defaultdict(list)
    for v in sorted(versions):
        for r in repos:
            rr = os.path.relpath(r, root)
            files = [f for f in git(r, 'grep', '-l', '-F', v, '--', ':!*.lock', ':!*package-lock.json', ':!*.map').split('\n') if f][:3]
            for f in files:
                out[v].append((rr, f, git(r, 'log', '-S', v, '-1', '--format=%h %ad %s', '--date=short', '--', f).strip()))
            if not files:
                # A tag or a commit message naming the version (a diff search is minutes on big repos).
                tag = [t for t in git(r, 'tag', '-l', f'*{v}*').split('\n') if t][:1]
                ref = tag[0] if tag else None
                hit = git(r, 'log', '-1', '--format=%h %ad %s|%H', '--date=short',
                          *([ref] if ref else ['--fixed-strings', f'--grep={v}', 'HEAD'])).strip()
                if hit:
                    desc, sha = hit.rsplit('|', 1)
                    ahead = git(r, 'rev-list', '--count', f'{sha}..HEAD').strip()
                    out[v].append((rr, 'history', f'{"tag " + ref + ": " if ref else ""}{desc} (HEAD is {ahead} commits ahead)'))
    return out


def path_refs(repos, board_paths, root):
    """{board path: [(repo rel, file)]}: repo files that mention a board location (deploy scripts, constants)."""
    out = collections.defaultdict(list)
    for bp in sorted(board_paths):
        for r in repos:
            for f in [f for f in git(r, 'grep', '-l', '-F', bp, '--', ':!*.map', ':!*.lock').split('\n') if f][:6]:
                out[bp].append((os.path.relpath(r, root), f))
    return out


def board_locations(paths):
    """Directory prefixes worth searching for: drop version components and everything below them."""
    locs = set()
    for p in paths:
        if p.startswith('/tmp/') or p.startswith('/proc/'):
            continue
        parts, keep = p.split('/')[1:-1], []
        for x in parts:
            if VERSION.fullmatch(x) or re.search(r'\d{3,}', x):
                break
            keep.append(x)
        if len(keep) >= 2:
            locs.add('/' + '/'.join(keep[:3]))
    return locs


def unit_compare(run, units, repos, root):
    out = []
    for i, u in enumerate(sorted(units)):
        rc, board = run(200 + i, f'systemctl cat {shlex.quote(u)} --no-pager 2>/dev/null', 20)
        files = re.findall(r'^# (/\S+)$', board, re.M)
        base = re.split(r'^# /\S+$', board, flags=re.M)[1:2]
        repo_files = []
        for r in repos:
            repo_files += [(os.path.relpath(r, root), f) for f in git(r, 'ls-files', f'*{u}').split('\n') if f]
        verdicts = []
        for rr, f in repo_files:
            try:
                txt = open(os.path.join(root, rr, f)).read()
            except OSError:
                continue
            norm = lambda t: [l.strip() for l in t.split('\n') if l.strip() and not l.startswith('#')]
            verdicts.append((rr, f, 'same' if base and norm(base[0]) == norm(txt) else 'differs'))
        out.append({'unit': u, 'board_files': files, 'repo': verdicts})
    return out


# ---------------------------------------------------------------- report

def repo_map(run, repo_path, bid, outdir):
    root, repos = find_repos(repo_path)
    states = [repo_state(r, root) for r in repos]
    targets = build_targets(repos, root)
    idx = host_index(root)
    arts = board_artifacts(run)
    # Fingerprint what the workspace could have produced: names/stems known on the host, plus
    # executables and script arguments (they may be renamed builds).
    want = [p for p, a in arts.items()
            if a['kind'] in ('exe', 'arg') or os.path.basename(p) in idx[0] or stem(p) in idx[1] or stem(p) in targets]
    want = [p for p in want if not p.startswith('/tmp/')] + [p for p in want if p.startswith('/tmp/')]
    fps = board_fingerprints(run, want)
    cache, rows = {}, []
    for p in want:
        m = match_artifact(p, fps.get(p), targets, idx, root, cache)
        rows.append((p, arts[p], fps.get(p), m))
    elf_like = [p for p, a, fp, m in rows if fp and fp['size'] < 60_000_000 and (m['targets'] or m['candidates'] or a['kind'] != 'lib')]
    hexes = board_commit_strings(run, elf_like)
    commits = commits_in(repos, set().union(*hexes.values()) if hexes else set(), root)
    versions = {v for p in want for v in VERSION.findall(p)}
    vmap = versions_in(repos, versions, root)
    prefs = path_refs(repos, board_locations(arts), root)
    units = unit_compare(run, {u for a in arts.values() for u in a['units']}, repos, root)

    L = [f'# Repo map: {bid} <-> {root}', '', '## Workspace repos', '',
         '| repo | branch | HEAD | dirty | remote |', '|---|---|---|---|---|']
    L += [f"| {s['path']} | {s['branch']} | {s['head'][:70]} | {s['dirty']} | {s['remote']} |" for s in states]
    L += ['', '## Board artifacts', '', '| board file | kind | size, date | verdict | workspace evidence |', '|---|---|---|---|---|']
    for p, a, fp, m in rows:
        if not (m['targets'] or m['candidates']):
            continue
        verdict = m['match'][0] if m['match'] else (
            'same runtime only (payload differs)' if m['candidates'] and m['candidates'][0][0] == 'same runtime only' else
            'renamed? differs' if m.get('renamed') else 'differs from local builds' if m['candidates'] else 'source only')
        ev = []
        if m['match']:
            ev.append(f"{m['match'][1]} ({m['match'][3]})")
        ev += [f"{c[0]}: {c[1]} ({c[3]})" for c in m['candidates'] if c is not m['match']][:3]
        ev += [f"target {t}" for t in m['targets']]
        size = f"{fp['size']}, {fp['date']}" if fp else '?'
        L.append(f"| {p} | {a['kind']}{' ' + ','.join(a['units']) if a['units'] else ''} | {size} | {verdict} | {'<br>'.join(ev)} |")
    unknown = [p for p, a, fp, m in rows if not (m['targets'] or m['candidates']) and a['kind'] != 'lib']
    if unknown:
        L += ['', 'No workspace evidence: ' + ', '.join(unknown)]
    L += ['', '## Embedded commits', '']
    for f, hs in hexes.items():
        for h in sorted(hs):
            for rr, subj, behind in commits.get(h, []):
                L.append(f'- {f}: `{h}` = {rr} {subj} (HEAD is {behind} commits ahead)')
    if not any(commits.get(h) for hs in hexes.values() for h in hs):
        L.append('none found (binaries embed no commit id of these repos)')
    L += ['', '## Versions in board paths', '']
    for v, hits in vmap.items():
        L += [f'- {v}: ' + '; '.join(f'{rr}: {c}' if f == 'history' else f'{rr}/{f} (introduced {c or "?"})'
                                     for rr, f, c in hits[:4])]
    for v in sorted(versions - set(vmap)):
        L.append(f'- {v}: not in any repo or its history')
    L += ['', '## Board locations referenced in the workspace', '']
    for bp, hits in prefs.items():
        L.append(f'- `{bp}`: ' + ', '.join(f'{rr}/{f}'.lstrip('./') for rr, f in hits[:8]))
    L += ['', '## Units', '']
    for u in units:
        rep = '; '.join(f'{rr}/{f}: {v}'.lstrip('./') for rr, f, v in u['repo']) or 'not in the workspace'
        drop = [f for f in u['board_files'][1:]]
        L.append(f"- {u['unit']}: {rep}" + (f"; board drop-ins: {', '.join(drop)}" if drop else ''))
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, 'repo-map-' + time.strftime('%Y%m%dT%H%M%SZ', time.gmtime()) + '.md')
    open(path, 'w').write('\n'.join(L) + '\n')
    return path, rows
