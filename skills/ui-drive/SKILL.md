---
name: ui-drive
description: Autonomously drive and visually verify GUIs on X11 (Qt, GTK, any toolkit) — on the local desktop, under headless Xvfb, or on remote embedded devices over SSH. Screenshots, taps, swipes, screen recording via the bundled uidrive CLI. Use for "test the app", "tap/click the UI", "screenshot the device", GUI smoke tests on kiosks, embedded panels and their desktop simulators.
---

# ui-drive: drive machine UIs locally or on embedded boards

The tool is `bin/uidrive` in this skill's folder (self-contained bash; run it with an
absolute path or add to PATH). It abstracts one loop over any X11 target:
**screenshot → Read the image → tap/swipe → screenshot → verify**.

```
uidrive [-t local|USER@HOST] [-d :N] COMMAND [ARGS]
```

Run `uidrive -h` for the full command list: `geom`, `shot`, `record`, `tap`, `swipe`,
`key`, `type`, `windows`, `winfo`, `raise`, `wintap`, `winshot`, `x` (raw xdotool).

## Targets

- **Remote board**: `-t root@<ip>` (key-based ssh required; uses a control socket, so
  repeated calls are fast). Default display `:0`. Boards need `xdotool` + `ffmpeg`
  on-image — typical for embedded Yocto images. Probe a new board first:
  `ssh root@<ip> 'ps ax w | grep -i -e Xorg -e <app>'` to learn the stack (often Xorg
  on `:0` with one or more fullscreen windows; the topmost one receives taps).
- **Local desktop app / simulator**: default `-t local` with `-d $DISPLAY` or an Xvfb
  display. For headless work, start `Xvfb :99 -screen 0 <WxH>x24` in the background at
  the board's native resolution and launch the app with `DISPLAY=:99`.
  (Qt desktop builds: reuse the env of the project's IDE launch configuration, typically
  `LD_LIBRARY_PATH`, `QML2_IMPORT_PATH` and `QT_QPA_PLATFORM=xcb`.)
- **Windowed app on the user's real display** (e.g. a desktop app on `:1`): find it
  with `windows` / `winfo`, then use `wintap NAME X Y` with window-relative
  coordinates — it raises the window first. Never `tap` raw screen coordinates on a
  user's live display without raising: X clicks land on whatever window is topmost,
  i.e. possibly the user's browser/editor. Warn the user their mouse pointer will move.

## Rules that prevent wasted cycles

1. **Screenshot immediately before any click, and verify with one right after.** UIs of
   this class have transient dialogs (some auto-confirm after ~1 s) and selections that
   auto-reset after short inactivity (~15 s is common). A screenshot from one model
   round-trip ago is stale.
2. **Chain time-critical sequences in a single Bash invocation** (select → confirm),
   with short sleeps between steps — a model round-trip between taps is enough to hit
   an inactivity reset and the second tap then lands on a different screen.
3. **Use app logs as a second channel.** Many embedded apps log state-machine transitions
   (e.g. `StateIdle`, `StateBusy`) to stdout / journal. On devices:
   `journalctl -u <app-service> -f` or the launcher service. Assert on states, not just
   pixels, when possible.
4. **Real devices have physical effects.** Only tap controls that actuate hardware when
   that is intended. For connectivity/coordinate smoke tests prefer reversible controls
   (view toggles, language, navigation). Simulators may offer on-screen stand-ins for
   physical sensors that real hardware lacks; when a step needs a person at the device,
   say so instead of retrying blindly.
5. **Portrait panels are common** (e.g. X reports 800x1280 while the framebuffer says
   1280x800 — trust `uidrive geom`, which asks X). Recheck `geom` per machine; models
   differ.
6. `record` is the right tool for animations, long hardware sequences and transient bugs:
   record while driving with a second Bash call, then review frames.

## Typical sessions

Board smoke test:
```bash
UID=<this skill's folder>/bin/uidrive
$UID -t root@<ip> geom
$UID -t root@<ip> shot /tmp/.../s0.png          # Read it, pick coordinates
$UID -t root@<ip> tap 605 1249                  # reversible control first
$UID -t root@<ip> shot /tmp/.../s1.png          # verify the change
```

Chained select→confirm (desktop simulator, one Bash call):
```bash
$UID -d :99 tap 140 300; sleep 1.5; $UID -d :99 shot sel.png; $UID -d :99 tap 612 1139; sleep 2; $UID -d :99 shot done.png
```

Windowed app on the user's display:
```bash
$UID -d :1 winfo MyApp          # ID, position, size -> scale factor vs native layout
$UID -d :1 wintap MyApp 850 1540
```
