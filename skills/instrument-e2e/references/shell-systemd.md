# Shell and systemd: points without source changes

Use this when the product cannot or should not be rebuilt. It gives hooks, stimuli and a log source, not
`E2E` debug lines from inside the app. Contract: `protocol.md`.

## Switch the environment on (drop-in)
```ini
# /etc/systemd/system/myapp.service.d/e2e.conf   (test image or board only, never shipped)
[Service]
Environment=E2E_PUPPET=/run/myapp/e2e.sock E2E_TRACE=1
RuntimeDirectory=myapp
ExecStartPre=-/usr/local/bin/e2e-reset      # state reset on start: rm cache, restore config
```
`systemctl daemon-reload && systemctl restart myapp`. Remove the drop-in to return to the stock unit. An
app without puppet support ignores the variables, so this is also how you enable a built-in puppet.

## Wrapper unit for the stimulus
A second unit runs the stimulus server next to the app and dies with it:
```ini
# e2e-puppet.service
[Unit]
PartOf=myapp.service
[Service]
ExecStart=/usr/local/bin/e2e-puppet-server /run/myapp/e2e.sock
```

## Log source: journal
If the app logs to the journal, use a log command in the profile instead of a file:
`journalctl -u myapp -f -o cat > $E2E_PRIV/app.log &` (spawn it), then `LOG_FILES` points at that file and
`wait_for` works as for any log. Mark readiness from the outside when the app has no `E2E ready`: a unit
`ExecStartPost=` that polls the app (port open, file exists) and then `logger -t e2e 'E2E ready'`.

## Fake device, sysfs, clock
- File the app reads (config, sensor value): `mount --bind /run/fake/sensor /etc/myapp/sensor` over a regular file.
  Real sysfs/procfs files cannot be bind-mounted over; bind a tmpfs copy of the parent directory, or point the
  app at another path by env.
- Serial or tty device: `socat -d pty,raw,echo=0,link=/run/fake-tty pty,raw,echo=0,link=/run/fake-tty-peer`
  creates a pair. The app opens one end, the puppet writes into the other.
- Clock: `faketime '2026-01-01 08:00:00' myapp` (libfaketime) in `ExecStart=`, or `date -s` on a test board.
- Network failure: `iptables -I OUTPUT -p tcp --dport 443 -j REJECT` as an `@action`, deleted by the next one.

## Tiny puppet server (bash + socat)
Stimulates by writing a value file the app polls. Replies `ok`/`err`, never a verdict.
```bash
#!/bin/bash
# e2e-puppet-server SOCK: usage: socat UNIX-LISTEN:SOCK,fork,mode=0600,unlink-early EXEC:"$0 --handle"
if [ "${1:-}" = --handle ]; then
    while read -r point arg; do
        case $point in
            help)    echo "ok sensor VALUE - write the sensor file | fail - make the sensor read error" ;;
            sensor)  [[ $arg =~ ^-?[0-9]+$ ]] && { echo "$arg" > /run/fake/sensor; echo ok; } || echo "err bad value" ;;
            fail)    echo "ERR" > /run/fake/sensor; echo ok ;;
            *)       echo "err unknown point $point" ;;
        esac
    done
    exit 0
fi
exec socat "UNIX-LISTEN:$1,fork,mode=0600,unlink-early" "EXEC:$0 --handle"
```
Test it with `puppet_send local /run/myapp/e2e.sock 'sensor 42'`.

## Release check
The drop-in and the server live outside the product package. Check the image: `ls /etc/systemd/system/*.d/e2e.conf`
must fail on a release image.

## Pitfalls
- `/run` is tmpfs and root-owned; create `/run/fake` in `ExecStartPre=` with the app user's ownership.
- `PrivateTmp=true` hides `/tmp` from other units. Keep sockets and fake files in `/run`.
- `socat ... fork` handles each client in a child; the handler must not keep state in variables.
- Never put judgement (comparisons of app output) in the server; that belongs to the tester.
