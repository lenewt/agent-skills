---
name: {{product}}-board
description: Operate {{product}} target boards ({{board model / SoC}}, {{distro}}) from the serial console or ssh - log in, bring up networking, locate {{main components}}, services, databases and logs, restart components, and build/deploy new versions. Use for any task touching a {{product}} board.
---

# {{product}}-board: {{product}} target boards from serial / ssh

Tool: `devsh` from the `board-discovery` skill runs shell commands on the board and prints each output with its
exit code. Define it at the top of each command block, then `D CMD [CMD...]` (`T=ssh:<ip> D …` once the network is up):
`D() { ~/.claude/skills/board-discovery/bin/devsh -T "${T:-{{target}}}" {{--noise '<regex>'}} "$@"; }` References: `reference/layout.md` (components, units, files, DBs, logs){{, reference/networking.md}}{{, reference/build-deploy.md}}.
Drift check: `discover -T {{target}} && discover --diff --name {{board id}}` (board-discovery). Facts below were
verified on {{board id}}, {{date}}.

## Connect

- Console `{{console device}}` at {{baud}} 8N1, host adapter {{/dev/ttyUSBn, chip}}. Login `{{user}}`, {{password policy}}.
- {{console noise and the --noise regex}}
- Userland: {{BusyBox/bash, notable missing or present tools}}.
- Identity check: `D 'hostname; {{version file}}'`.

## Network

{{manager, interface names, how to bring it up, who rewrites the config at start, how to verify}}

## Component map

| Piece | Where | Started by | Built from |
|---|---|---|---|
| {{component}} | {{path}} | {{unit or parent}} | {{repo, target, local output (discover --repo)}} |

Restart: {{command, duration, what else it restarts}}. Stop for a quiet console: {{command}}.

## Data and logs

- {{live config/DB paths, how the live one is selected}}
- {{log paths, which one shows what}}

## Safety

- {{physical side effects: what never to tap/send}}
- Leave network profiles, radios and unit drop-ins as found unless asked.
- Do not edit databases while the writer runs; stop it first or copy them out.
- {{disk space constraints: where scratch files go}}
