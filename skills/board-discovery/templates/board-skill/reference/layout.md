# {{product}} board layout (verified on {{board id}}, {{date}})

Hardware/OS: {{model, SoC, kernel, distro + version, init, package manager}}.
Kernel cmdline: `{{relevant parts}}`. Partitions: {{device -> mount, size, role, what survives an update}}.
Versions: {{how to read the system/app versions}}.

## Processes at runtime

```
{{cmdline}}    # {{unit / parent}}
```

## Units

| Unit | Role |
|---|---|
| {{unit}} | {{role; notable settings: Restart, StandardOutput, BindsTo, drop-ins}} |

Listening ports: {{port -> process}}.

## Filesystem map

```
{{path}}    {{what it holds}}
```

## Databases

- {{file, engine, live vs factory/backup, how the live one is selected, tables of interest (schema only)}}

## Update path

{{updater units/scripts, removable-media or OTA trigger, where packages land}}
