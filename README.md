# stable-sync

Keeps a fixed-path copy of `op` (1Password CLI) so macOS privacy permissions such as Full Disk
Access are granted once and survive every update.

> The Claude Code half (`claude-stable-sync`) was removed: Claude Code is now updated by a separate,
> stricter tool that is the only thing allowed to replace its fixed copy, because two automatic
> replacers running side by side caused a macOS permission jam.

## Why

macOS stores privacy permissions (TCC: Full Disk Access, Documents, Desktop, cloud drives...) by
the executable's path. Homebrew installs each `op` update into a new folder
(`Caskroom/1password-cli/<version>/op`). The path changes, the permission is lost, and macOS asks
again, or a scheduled job silently fails to read a protected folder.

A symlink does not help: macOS follows it and records the real, versioned file. A real copy at a
fixed path does: grant the permission to the copy once, and it keeps working after every update.

## What it does

`op-stable-sync` copies Homebrew's `op` (followed to the real file) to `~/.local/bin/op`. A launchd
job runs it when the Homebrew cask changes, at load, and every hour.

The copy is made in a temp file of its own next to the target, checked with `codesign -v` against
1Password's Team ID (a bad or ad-hoc signature keeps the previous copy), then moved into place in
one step. Nothing happens when the copy already has identical bytes. After 3 failures in a row, one
alert goes out beyond the log (a macOS notification, or your own command).

```
$ op-stable-sync
2026-11-08 13:22:15 ok: copied /opt/homebrew/Caskroom/1password-cli/2.41.1/op -> /Users/you/.local/bin/op
```

## Install

```
git clone https://github.com/lucas-saldanha-werneck/stable-sync
cd stable-sync
./install.sh --dry-run   # shows the file and the launchd job it would write
./install.sh             # copies the tool to ~/.local/bin and writes the job (with your real paths)
./install.sh --load      # same, and loads the job
```

`install.sh` loads nothing unless you pass `--load`. Option: `--prefix com.example.` (launchd label
prefix, default `com.stable-sync.`). No job is written when `op` is not installed (set
`OP_STABLE_SOURCE` to write it anyway).

Then, once:

1. Run `op-stable-sync` (or load the job) so the copy exists.
2. Make sure `~/.local/bin` comes before Homebrew on your PATH, and point scripts and scheduled jobs
   that start `op` at `~/.local/bin/op`.
3. Grant the permission to the copy: System Settings → Privacy & Security → Full Disk Access →
   `+`, press Cmd+Shift+G and paste `~/.local/bin/op`.

## Settings

Environment variables. When set during `./install.sh`, they are written into the launchd job.

| Variable | Default | What it does |
|---|---|---|
| `OP_STABLE_SOURCE` | `/opt/homebrew/bin/op`, else `/usr/local/bin/op` | `op` to copy from |
| `OP_STABLE_DEST` | `~/.local/bin/op` | the copy |
| `STABLE_SYNC_LOG_DIR` | `~/Library/Logs` | where `op-stable-sync.log` goes (and the job's `.err` file) |
| `OP_STABLE_TEAM_ID` | `2BUA8C4S2C` (1Password) | Team ID the signature must carry; empty = any valid signature |
| `STABLE_SYNC_ALERT_AFTER` | `3` | failures in a row before the one alert |
| `STABLE_SYNC_ALERT_CMD` | macOS notification | command run with the alert text as its only argument |

## Good to know

- The terminal app's Full Disk Access does not necessarily cover a command it starts: macOS can
  treat a process as responsible for itself, so grant the permission to the binary.
- In a launchd job, a wrapper in between can become the "responsible" process and the permission
  is checked against it instead. In testing, Homebrew's `timeout` (`gtimeout`) did that and the
  system `/usr/bin/timeout` (recent macOS) did not.

## Requirements

- **1Password CLI (`op`)**. Without it, `op-stable-sync` does nothing and `install.sh` writes no job.
- **Homebrew** (optional): the job watches Homebrew's cask folder. With `op` from somewhere else,
  set `OP_STABLE_SOURCE`; the hourly run still picks up updates.
- **`codesign`** (part of macOS): without it the signature check is skipped with a note in the log.

## Platform

macOS (launchd, TCC, `codesign`). The script runs on Linux too, but there is nothing to fix there
and no job is written. Tests run on macOS, Linux and Windows (Git Bash) with a fake `op`, a fake
`codesign` and a fake `launchctl`: `bash tests/run.sh`.

## Uninstall

```
./install.sh --uninstall
```

Unloads and removes the job and the tool. The copy stays, because your permissions point at it;
delete `~/.local/bin/op` yourself if you no longer want it.

If you installed an earlier version with the Claude Code part, its job
(`com.stable-sync.claude-stable-sync`) and `~/.local/bin/claude-stable-sync` are left alone; remove
them yourself (`launchctl bootout gui/$(id -u)/com.stable-sync.claude-stable-sync`, then delete the
plist in `~/Library/LaunchAgents` and the script).

## License

MIT

Built with Claude Code
