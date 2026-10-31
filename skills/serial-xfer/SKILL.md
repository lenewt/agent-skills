---
name: serial-xfer
description: Transfer a file to or from an embedded Linux board over its serial console (UART, ttyUSB, ttyACM) as base64 text, for boards with no network, no adb and no lrzsz/zmodem - push or pull with gzip, chunked resume, retries and a sha256/md5 check. Also works over ssh, adb and local targets. Use when asked to copy, upload, download, push or pull a file, binary, config, log or firmware to or from a board that only has a serial console, or when scp/adb/rz are not available on the board.
---

# serial-xfer: copy files over a serial console with base64

One tool, `bin/sxfer`, Python 3 on the host. It needs the **board-discovery** skill next to it (it loads that skill's
`bin/devsh` for the transport: login, markers, console-noise handling) and `pyserial` for serial targets. The board needs
only a shell with `base64` (`-d`), `printf`, `wc`, `head`, `mv`, `dd` (pull) and `truncate` (else `dd`/`head`, to roll
back a bad chunk); `gzip` and `sha256sum`/`md5sum` are used when present.

| Command | Does |
|---|---|
| `sxfer -T TARGET --check` | which of base64 / gzip / gunzip / md5sum / sha256sum the board has, and whether `base64 -d` works |
| `sxfer -T TARGET push LOCAL REMOTE [--mode 0755] [--no-gzip] [--no-resume] [--no-clobber] [--chunk N]` | host gzip when it helps, base64 chunks appended to `REMOTE.b64.part`, decode to `REMOTE.part`, size + checksum check, `mv` over REMOTE, temp files removed |
| `sxfer -T TARGET pull REMOTE LOCAL [--gzip]` | size + checksum on the board, 16 KB `dd | base64` ranges, each range length-checked, whole file checksum-checked, LOCAL written atomically |

TARGET (or `$DEVSH_TARGET`), `-u`/`$DEVSH_USER`, `$DEVSH_PASSWORD`, `--noise REGEX`, `-t SECONDS` (per board command):
exactly as in `devsh`; see `board-discovery/SKILL.md`, for example `serial:/dev/serial/by-id/<adapter>@115200`.
Progress goes to stderr; the last stdout line is `OK push|pull ... <checksum>`. Exit 0 ok, 1 transfer or verify failure,
2 target unreachable.

## Workflow

1. **Prefer a real channel.** If the board has network or adb, use `scp` / `adb push` instead; this tool is for serial-only boards.
2. **Check the board:** `sxfer -T <target> --check`. No `base64`: use U-Boot `loady` (ymodem, needs the bootloader) or
   `rz` / lrzsz with picocom if the board has them; there is no fallback in this tool. No checksum tool: size only, warned.
3. **Look before writing:** `devsh -T <target> 'mount | grep " / "; df -h /tmp; ls -l <REMOTE>'`. Temp files sit next to REMOTE
   and need about 1.4x the file size free there (base64 text); `/tmp` (tmpfs) is the usual choice.
4. **Transfer:** `sxfer -T <target> push build/app /tmp/app --mode 0755`, or `pull /var/log/app.log ./app.log`.
   On interruption rerun the same push: it resumes from `REMOTE.b64.part` after checking the part against the file
   (a different file or a damaged part restarts from 0). `--no-resume` forces a restart.
5. **Verify:** the OK line carries the sha256 (md5, or "size only"); compare it with `sha256sum LOCAL` when it matters.

## Throughput and tuning

~11 KB/s raw at 115200 baud, base64 adds 33%, so 1 MB takes about 2 min (gzip makes text and unstripped binaries much
smaller; random or already-compressed data is sent as is). devsh paces writes 16 bytes / 4 ms by default, which caps a push
near 3 KB/s: on a quiet console try `--pace 64/1` (or `$DEVSH_PACE`); lost characters are caught by the size check every
8 chunks, which rolls back and resends, and a persistent mismatch aborts telling you to slow down. A failed or timed-out
chunk is retried 3 times. Raise `-t` for a big file's decode and checksum on a slow CPU.

## Rules

- **Ask before writing** to a board path outside `/tmp` (or another scratch area) and before overwriting an existing file;
  the tool warns `replacing existing` (use `--no-clobber` to refuse). It never touches REMOTE until the verified file is moved over it.
- **Read-only rootfs:** check `mount` first; a push to a read-only directory fails at once. Do not remount rw without asking.
- **Secrets:** never pull `shadow`, SSH/TLS keys, `*.nmconnection`, wpa configs, tokens or credential DBs into the host repo or
  the transcript. Do not print pulled files that may contain them; pull to a scratch dir outside any git repo.
- Files on `/proc`, `/sys` and devices cannot be pulled (size is not real); `cat` them to `/tmp` on the board first.
- Do not run the transfer while another process reads the same console (a log viewer, picocom): characters get interleaved.
