# stable-sync

Keep a copy of the `claude` (Claude Code) and `op` (1Password CLI) binaries at a fixed path, so
macOS privacy permissions such as Full Disk Access are granted once and survive every update.

## Why

macOS stores privacy permissions (TCC: Full Disk Access, Documents, Desktop, cloud drives...) by
the executable's path. Claude Code installs each update into a new folder
(`~/.local/share/claude/versions/<version>`) and Homebrew does the same for `op`
(`Caskroom/1password-cli/<version>/op`). The path changes, the permission is lost, and macOS asks
again, or a scheduled job silently fails to read a protected folder
([anthropics/claude-code#49282](https://github.com/anthropics/claude-code/issues/49282)).

A symlink does not help: macOS follows it and records the real, versioned file. A real copy at a
fixed path does: grant the permission to the copy once, and it keeps working after every update.

## What it does

| Tool | Copy | Runs |
|---|---|---|
| `claude-stable-sync` | `~/.local/bin/claude` (followed to the real file) → `~/.local/libexec/claude-stable/claude` | launchd: when `versions/` or `~/.local/bin` changes, at load, every 15 min |
| `op-stable-sync` | Homebrew's `op` → `~/.local/bin/op` | launchd: when the Homebrew cask changes, at load, every hour |

Each copy is made next to the target, checked with `codesign -v` (a bad signature keeps the
previous copy), then moved into place in one step. Nothing happens when the copy is current.

```
$ claude-stable-sync
2026-11-08 13:22:15 ok: copied /Users/you/.local/share/claude/versions/2.1.319 -> /Users/you/.local/libexec/claude-stable/claude
$ ~/.local/libexec/claude-stable/claude --version
2.1.319 (Claude Code)
```

## Install

```
git clone https://github.com/lucas-saldanha-werneck/stable-sync
cd stable-sync
./install.sh --dry-run   # shows the files and the launchd jobs it would write
./install.sh             # copies the tools to ~/.local/bin and writes the jobs (with your real paths)
./install.sh --load      # same, and loads the jobs
```

`install.sh` loads nothing unless you pass `--load`. Options: `--only claude` or `--only op`,
`--prefix com.example.` (launchd label prefix, default `com.stable-sync.`). The `op` job is skipped
when `op` is not installed.

Then, once:

1. Run `claude-stable-sync` (or load the job) so the copy exists.
2. Put the copy first on your PATH, e.g. in `~/.zshenv`:
   `export PATH="$HOME/.local/libexec/claude-stable:$PATH"`.
   Point scripts and scheduled jobs that start `claude` at the copy too.
3. Grant the permission to the copy: System Settings → Privacy & Security → Full Disk Access →
   `+`, press Cmd+Shift+G and paste `~/.local/libexec/claude-stable/claude`. For `op`, add
   `~/.local/bin/op`.

## Settings

Environment variables. When set during `./install.sh`, they are written into the launchd jobs.

| Variable | Default | What it does |
|---|---|---|
| `CLAUDE_STABLE_SOURCE` | `~/.local/bin/claude` | link or file to copy Claude Code from |
| `CLAUDE_STABLE_DIR` | `~/.local/libexec/claude-stable` | folder of the Claude Code copy |
| `OP_STABLE_SOURCE` | `/opt/homebrew/bin/op`, else `/usr/local/bin/op` | `op` to copy from |
| `OP_STABLE_DEST` | `~/.local/bin/op` | the `op` copy |
| `STABLE_SYNC_LOG_DIR` | `~/Library/Logs` | where `claude-stable-sync.log` and `op-stable-sync.log` go |

## Good to know

- The terminal app's Full Disk Access does not necessarily cover `claude`: macOS can treat each
  `claude` process as responsible for itself, so grant the permission to the binary.
- In a launchd job, a wrapper in between can become the "responsible" process and the permission
  is checked against it instead. In testing, Homebrew's `timeout` (`gtimeout`) did that and the
  system `/usr/bin/timeout` (recent macOS) did not.
- Background processes that Claude Code starts by itself from its versioned path are not covered.

## Optional requirements

- **1Password CLI (`op`)**: only for `op-stable-sync`. Without it, that tool does nothing and
  `install.sh` skips its job.
- **Homebrew**: the `op` job watches Homebrew's cask folder. With `op` from somewhere else, set
  `OP_STABLE_SOURCE`; the hourly run still picks up updates.
- **`codesign`** (part of macOS): without it the signature check is skipped with a note in the log.

## Platform

macOS (launchd, TCC, `codesign`). The scripts run on Linux too, but there is nothing to fix there and
no job is written. Tests run on macOS, Linux and Windows (Git Bash) with fake binaries, a fake
`codesign` and a fake `launchctl`: `bash tests/run.sh`.

## Uninstall

```
./install.sh --uninstall
```

Unloads and removes the jobs and the two tools. The copies stay, because your permissions point at
them; delete `~/.local/libexec/claude-stable` and `~/.local/bin/op` yourself if you no longer want
them (and take them off your PATH first).

## License

MIT

Built with Claude Code
