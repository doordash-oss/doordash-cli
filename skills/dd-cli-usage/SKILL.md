---
name: dd-cli-usage
description: >-
  Use DoorDash CLI (dd-cli) to order food, groceries, or retail items from local businesses
  via DoorDash.
---

# DoorDash CLI

`dd-cli` is available on PATH. Its commands form a tree of command groups terminating in leaf commands.

"DoorDash CLI" and `dd-cli` refer to the same tool — the command you run is `dd-cli`. Treat either name from the user as interchangeable.

Use `--help` / `-h` to navigate on demand — start at the root and follow only
the path relevant to the user's request:

```
dd-cli --help               # root: all commands and groups
dd-cli cart --help          # group: lists subcommands
dd-cli cart add-items --help  # leaf: options and usage
```

Do not pre-map the full tree. Drill deeper only when you need the next level.
