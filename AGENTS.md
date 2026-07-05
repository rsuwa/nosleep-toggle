# Repository Guidelines

## Project Structure & Module Organization

This repository provides a Bash CLI plus a GNOME Shell extension for toggling sleep inhibition.

- `bin/nosleep`: main CLI entrypoint. It manages persistent and per-command `systemd-inhibit` sessions.
- `extension/extension.js`: GNOME Shell 46 top-bar indicator, menu logic, async CLI polling, and error state handling.
- `extension/metadata.json`: extension UUID, name, supported Shell version, and version.
- `extension/icons/`: symbolic SVG status icons named by state.
- `install.sh` and `uninstall.sh`: symlink the CLI and extension into the user's local GNOME paths.
- `tests/run.sh`: Bash smoke/regression test script for CLI, installer, metadata, and icon contracts.
- `README.md` and `README.ja.md`: user-facing documentation.
- `.serena/memories/`: local Serena project notes. Keep them aligned with stable repository contracts after behavior changes.

## Build, Test, and Development Commands

There is no build step. Development usually happens directly from the checked-out tree.

- `./install.sh`: installs local symlinks for `bin/nosleep` and the GNOME extension.
- `./uninstall.sh`: stops persistent NoSleep through this checkout, disables the extension when possible, and removes only links owned by this checkout.
- `./tests/run.sh`: runs the repository smoke/regression tests, including adversarial inhibitor parsing, PATH poisoning, lock handling, installer behavior, metadata, and icon references.
- `bash -n bin/nosleep install.sh uninstall.sh tests/run.sh`: checks Bash syntax.
- `shellcheck bin/nosleep install.sh uninstall.sh tests/run.sh`: runs optional Bash linting if ShellCheck is installed.
- `nosleep status`: verifies CLI state after installation; expected output is `off`, `on`, or `running`.
- `nosleep --raw-status`: prints the raw global `systemd-inhibit` list for troubleshooting; `--status` remains as a legacy alias.

## Coding Style & Naming Conventions

Bash files use `#!/bin/bash`, `set -euo pipefail`, two-space indentation, `snake_case` function names, and `local` variables inside functions. Keep CLI output stable because the extension parses `nosleep status`.
Internal helper commands are resolved from trusted system paths in `bin/nosleep`; keep user command execution via `nosleep run` using the caller's original `PATH`.
Separate `systemd-inhibit` options from the inhibited command with `--`.
Persistent state uses pid, process start time, and boot ID files under the runtime state directory; keep writes atomic and cleanup under the CLI lock.
The CLI locks the runtime state directory file descriptor with `flock`; do not reintroduce a writable lock file under the state directory.
When reading `systemd-inhibit --list`, treat the text table as a source of candidate rows only.
Before trusting or killing a listed PID, revalidate the real process through `/proc`: current UID, `systemd-inhibit` argv[0], expected `--who`, exact `--what`, and `--mode=block`.
When the inhibitor list is available, treat logind state as authoritative over pid/start/boot files.

GNOME Shell JavaScript uses ES modules, four-space indentation, `const` for immutable values, `UPPER_CASE` constants, and private helper methods with a leading underscore. Keep CLI-backed state keys aligned with the CLI status values: `off`, `on`, and `running`; the extension also has an internal `unknown` state for failed status refreshes.
Track in-flight subprocesses from `destroy()`.
Cancel them by sending SIGTERM first and using delayed `force_exit()` only as a fallback.
Guard status refresh results so older async refreshes cannot overwrite a newer user action.

Icon assets should remain symbolic SVGs named `nosleep-<state>-symbolic.svg`.

## Testing Guidelines

Before opening a pull request, run `./tests/run.sh`, the Bash syntax check, and ShellCheck when available. On Ubuntu 24.04 with GNOME Shell 46, run `./install.sh`, then verify the top-bar states: `Sleep`, `Awake`, `Run`, and the error/unknown path if the helper is unavailable. Also test `nosleep on`, `nosleep off`, `nosleep toggle`, `nosleep status`, `nosleep --raw-status`, and `nosleep run <command>`.
For process-detection changes, include regression coverage for spoofed `--who` values with whitespace and for pid files that point at a process without a logind inhibitor.
For locking changes, include coverage that a preexisting `lock` symlink is not opened or truncated.
Plain `gjs -m extension/extension.js` is not a reliable test outside GNOME Shell because the file imports Shell resource modules.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Improve NoSleep status indicator` and `Generalize install path in README`. Follow that style: one focused change per commit, no trailing punctuation, and a clear verb.

Pull requests should describe behavior changes, list manual verification steps, and mention the Ubuntu/GNOME versions used for testing. Include screenshots only when the top-bar UI changes.

## Install Notes

Installation is symlink-based.
Changes in the checkout affect the installed CLI and extension immediately.
GNOME Shell may not recognize a newly installed extension UUID until logout/login; keep that distinction separate from file installation failures.
