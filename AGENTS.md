# Repository Guidelines

## Project Structure & Module Organization

This repository provides a Bash CLI plus a GNOME Shell extension for toggling sleep inhibition.

- `bin/nosleep`: main CLI entrypoint. It manages persistent and per-command `systemd-inhibit` sessions.
- `extension/extension.js`: GNOME Shell 46 variant of the extension, an ES module with the top-bar indicator, menu logic, async CLI polling, and error state handling.
- `extension/metadata.json`: extension UUID, name, supported Shell version, and version. Both variants share the UUID; their metadata files differ only in `shell-version`.
- `extension/icons/`: symbolic SVG status icons named by state. The SVGs live only here; `extension-legacy/icons` is a relative symlink to this directory.
- `extension-legacy/`: GNOME Shell 42 (Ubuntu 22.04) variant of the same extension. `extension.js` is a legacy `imports.*` script with an `init()` entry point, and `metadata.json` declares only Shell 42.
- `install.sh` and `uninstall.sh`: symlink the CLI and extension into the user's local GNOME paths; uninstall only stops/disables links owned by this checkout.
- `tests/run.sh`: Bash smoke/regression test script for CLI lifecycle, adversarial inhibitor parsing, state setup, installer, metadata and icon contracts of both extension variants, and extension variant parity.
- `package.json`, `package-lock.json`, and `eslint.config.mjs`: pinned JavaScript lint tooling for both GNOME Shell extension variants.
- `README.md` and `README.ja.md`: user-facing documentation.
- `.serena/memories/`: local Serena project notes. Keep them aligned with stable repository contracts after behavior changes.

## Build, Test, and Development Commands

There is no build step. Development usually happens directly from the checked-out tree.

- `./install.sh`: installs local symlinks for `bin/nosleep` and the GNOME extension.
- `./uninstall.sh`: when installed links point to this checkout, stops persistent NoSleep, disables the extension when possible, and removes only owned links.
- `./tests/run.sh`: runs the repository smoke/regression tests, including adversarial inhibitor parsing, interrupted start cleanup, delayed startup readiness, duplicate blocker cleanup, PATH poisoning, concurrent state directory setup, state directory and lock handling, installer behavior, metadata and icon references of both extension variants, and extension variant parity.
- `npm install`: installs JavaScript lint tooling from `package-lock.json`.
- `npm run lint:js`: runs ESLint against both GNOME Shell extension variants.
- `bash -n bin/nosleep install.sh uninstall.sh tests/run.sh`: checks Bash syntax.
- `shellcheck bin/nosleep install.sh uninstall.sh tests/run.sh`: runs optional Bash linting if ShellCheck is installed.
- `nosleep status`: verifies CLI state after installation; expected output is `off`, `on`, or `running`.
- `nosleep --raw-status`: prints the raw global `systemd-inhibit` list for troubleshooting; `--status` remains as a legacy alias.

## Coding Style & Naming Conventions

Bash files use `#!/bin/bash`, `set -euo pipefail`, two-space indentation, `snake_case` function names, and `local` variables inside functions. Keep CLI output stable because the extension parses `nosleep status`.
Internal helper commands are resolved from trusted system paths in `bin/nosleep`; keep user command execution via `nosleep run` using the caller's original `PATH`.
Separate `systemd-inhibit` options from the inhibited command with `--`.
Persistent state uses pid, process start time, and boot ID files under the runtime state directory; keep writes atomic and cleanup under the CLI lock.
The runtime state directory itself must not be a symlink; tolerate concurrent first creation and recheck ownership/type before locking or writing.
The CLI locks the runtime state directory file descriptor with `flock`; do not reintroduce a writable lock file under the state directory.
When reading `systemd-inhibit --list`, treat the text table as a source of candidate rows only.
Before trusting or killing a listed PID, revalidate the real process through `/proc`: current UID, `systemd-inhibit` argv[0], expected `--who`, exact `--what`, and `--mode=block`.
When the inhibitor list is available, treat logind state as authoritative over pid/start/boot files for status decisions.
For `off`, still stop a recorded PID when pid/start/boot/cmdline identity proves it is this tool's persistent blocker, even if the current list misses it.
After stopping any recorded PID, `off` must still drain all remaining matching persistent blockers, including duplicates.
Persistent blocker stop paths should signal the process group first and use direct PID signals only as fallback, including list-based fallback stops.
If `nosleep on` is interrupted or fails before validation completes, clean up the just-started blocker and any partial state files with one-shot traps on return, exit, and common termination signals.
Startup readiness should wait for the spawned process to become the expected listed `systemd-inhibit` inhibitor; do not assume `setsid` has already execed immediately after spawn.

GNOME Shell JavaScript uses four-space indentation, `const` for immutable values, `UPPER_CASE` constants, and private helper methods with a leading underscore. Keep CLI-backed state keys aligned with the CLI status values: `off`, `on`, and `running`; the extension also has internal `loading` and `unknown` states.
The extension ships as two variants because GNOME Shell 42 and GNOME Shell 45+ load `extension.js` in incompatible ways; the rules below apply to both variants unless they name one.
`extension/extension.js` is an ES module for GNOME Shell 46: `import` declarations and a default-exported `Extension` subclass. Do not use the legacy `imports` object there.
`extension-legacy/extension.js` is a single-file legacy script for GNOME Shell 42: `imports.gi` and `imports.ui.*`, `/* exported init */`, and a `function init(extension)` declaration that returns an object with `enable()` and `disable()`. Do not use ES module syntax (`import`/`export`) there, and nothing newer than ES2021 because Ubuntu 22.04 ships gjs 1.72.
The code from `const UUID` to the end of the indicator class must stay identical in both files, except for the click-policy method and the legacy-only `style: ICON_STYLE,` line. `tests/run.sh` enforces this parity, so change both files in the same commit.
On GNOME Shell 42 the click policy must live in a `vfunc_event(event)` override: `PanelMenu.Button.vfunc_event` toggles the menu on every button press before `button-press-event` is emitted, and `vfunc_button_press_event` receives a struct without `get_button()`.
Only declare a Shell version in a `metadata.json` after running that variant on that Shell version.
JavaScript linting is enforced through the repository ESLint v9 flat config, which lints `extension/` as an ES module and `extension-legacy/` as an ES2021 script; keep both variants compatible with `npm run lint:js`.
Keep repeated panel style fragments centralized through the local style helper instead of duplicating state-specific CSS strings.
The extension should not present or act on a false `off` state before the first status refresh completes; guard toggles until initial status is loaded.
Status-only retry/loading paths must not advance stale-refresh generations; only mutating `on`/`off` actions should suppress older refresh results.
Track in-flight subprocesses from `destroy()`.
Launch CLI controls in their own session/process group, cancel them by signaling the process group with SIGTERM first, and use delayed SIGKILL/`force_exit()` only as a fallback.
Guard status refresh results so older async refreshes cannot overwrite a newer user action.

Icon assets should remain symbolic SVGs named `nosleep-<state>-symbolic.svg`.

## Testing Guidelines

Before opening a pull request, run `./tests/run.sh`, `npm run lint:js`, the Bash syntax check, and ShellCheck when available. On Ubuntu 24.04 with GNOME Shell 46, run `./install.sh`, then verify the top-bar states: `Sleep`, `Awake`, `Run`, and the error/unknown path if the helper is unavailable. Also test `nosleep on`, `nosleep off`, `nosleep toggle`, `nosleep status`, `nosleep --raw-status`, and `nosleep run <command>`.
For process-detection and stop changes, include regression coverage for spoofed `--who` values with whitespace, pid files that point at a process without a logind inhibitor, successful inhibitor-list queries that miss a recorded blocker, duplicate matching persistent inhibitors, recorded-plus-duplicate blockers, and fallback stops that must not leave blocker process groups behind.
For lifecycle changes, include coverage that interrupted `nosleep on` does not leave a blocker or partial state files, delayed `setsid`/exec readiness still succeeds, and startup failure cleanup does not leave stale traps.
For locking/state-directory changes, include coverage that a preexisting `lock` symlink is not opened or truncated, a symlink runtime state directory is rejected, and concurrent first-time state directory creation succeeds.
For installer tests, isolate `gnome-extensions` with `NOSLEEP_GNOME_EXTENSIONS_CMD`; the scripts reset `PATH` before normal command lookup.
Neither `gjs -m extension/extension.js` nor `gjs extension-legacy/extension.js` is a reliable test outside GNOME Shell because both files import modules that only exist inside the Shell.
For extension subprocess termination code, a local `gjs -c` smoke check can verify that a `setsid`-launched subprocess tree is released when its process group receives SIGTERM.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Improve NoSleep status indicator` and `Generalize install path in README`. Follow that style: one focused change per commit, no trailing punctuation, and a clear verb.

Pull requests should describe behavior changes, list manual verification steps, and mention the Ubuntu/GNOME versions used for testing. Include screenshots only when the top-bar UI changes.

## Install Notes

Installation is symlink-based.
Changes in the checkout affect the installed CLI and extension immediately.
GNOME Shell may not recognize a newly installed extension UUID until logout/login; keep that distinction separate from file installation failures.
