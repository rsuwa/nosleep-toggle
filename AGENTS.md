# Repository Guidelines

## Project Structure & Module Organization

This repository provides a Bash CLI plus a GNOME Shell extension for toggling sleep inhibition.

- `bin/nosleep`: main CLI entrypoint. It manages persistent and per-command `systemd-inhibit` sessions.
- `extension/extension.js`: GNOME Shell 46 variant of the extension, an ES module with the top-bar indicator, menu logic, async CLI polling, and error state handling.
- `extension/metadata.json`: extension UUID, name, supported Shell version, and version. Both variants share the UUID; their metadata files differ only in `shell-version`.
- `extension/icons/`: symbolic SVG status icons named by state. The SVGs live only here; `extension-legacy/icons` is a relative symlink to this directory.
- `extension-legacy/`: GNOME Shell 42 (Ubuntu 22.04) variant of the same extension. `extension.js` is a legacy `imports.*` script with an `init()` entry point, and `metadata.json` declares only Shell 42.
- `install.sh` and `uninstall.sh`: symlink the CLI and the extension variant matching the installed GNOME Shell major version (`extension/` for 45 and newer, `extension-legacy/` for older) into the user's local GNOME paths; uninstall only stops/disables links owned by this checkout, and an extension link to either variant directory counts as owned.
- `tests/run.sh`: Bash smoke/regression test script for CLI lifecycle, adversarial inhibitor parsing, state setup, installer, metadata and icon contracts of both extension variants, and extension variant parity.
- `package.json`, `package-lock.json`, and `eslint.config.mjs`: pinned JavaScript lint tooling for both GNOME Shell extension variants.
- `README.md` and `README.ja.md`: user-facing documentation.
- `.serena/memories/`: local Serena project notes. Keep them aligned with stable repository contracts after behavior changes.

## Build, Test, and Development Commands

There is no build step. Development usually happens directly from the checked-out tree.

- `./install.sh`: installs local symlinks for `bin/nosleep` and the GNOME extension variant selected from `gnome-shell --version`; when the Shell version cannot be determined it installs only the CLI link and warns.
- `./uninstall.sh`: when installed links point to this checkout (the extension link may point at either variant), stops persistent NoSleep, disables the extension when possible, and removes only owned links.
- `./tests/run.sh`: runs the repository smoke/regression tests, including adversarial inhibitor parsing, interrupted start cleanup, delayed startup readiness, duplicate blocker cleanup, PATH poisoning, concurrent state directory setup, state directory and lock handling, installer behavior including extension variant selection and link ownership, metadata and icon references of both extension variants, and extension variant parity.
- `npm install`: installs JavaScript lint tooling from `package-lock.json`.
- `npm run lint:js`: runs ESLint against both GNOME Shell extension variants.
- `bash -n bin/nosleep install.sh uninstall.sh tests/run.sh`: checks Bash syntax.
- `shellcheck bin/nosleep install.sh uninstall.sh tests/run.sh`: runs optional Bash linting if ShellCheck is installed.
- `nosleep status`: verifies CLI state after installation; expected output is `off`, `on`, or `running`.
- `nosleep --raw-status`: prints the raw global `systemd-inhibit` list for troubleshooting; `--status` remains as a legacy alias.
- Node.js for the lint tooling must satisfy ESLint 9's range (`^18.18.0 || ^20.9.0 || >=21.1.0`); Ubuntu 22.04's packaged Node.js 12 is too old, so use a newer Node.js there (for example via nvm). `./tests/run.sh` skips the lint step with a `SKIP:` line when npm dependencies are missing, `node` or `npm` is not on `PATH`, the Node.js version cannot be determined from `node --version`, or that version is outside the range. Before any of those skips it self-checks the range helper `node_supports_eslint` against boundary versions, which needs no Node.js, so a wrong boundary fails the suite instead of silently skipping the lint; when the ESLint pin changes, update the helper, that version table, and the documented range together.

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
`tests/run.sh` pins the code lines of that override and of the legacy entry point (everything after the indicator class), because the parity check does not cover them; change them only together with the pinned text, after running the legacy variant on GNOME Shell 42 again.
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

Before opening a pull request, run `./tests/run.sh`, `npm run lint:js`, the Bash syntax check, and ShellCheck when available. Also test `nosleep on`, `nosleep off`, `nosleep toggle`, `nosleep status`, `nosleep --raw-status`, and `nosleep run <command>`.
For extension or installer changes, and for CLI changes that alter the output of `nosleep status`, `nosleep on`, or `nosleep off` (the extension parses all three), verify manually on both supported platforms, Ubuntu 24.04 with GNOME Shell 46 and Ubuntu 22.04 with GNOME Shell 42: run `./install.sh`, follow the restart and enable steps it prints, then verify the top-bar states: `Sleep`, `Awake`, `Run`, and the error/unknown path if the helper is unavailable.
On GNOME Shell 42, left-click the indicator and check that it toggles NoSleep while the menu stays closed, then right-click it and check that the menu opens.
On GNOME Shell 46, left-click the indicator and check that it toggles NoSleep, then record in the pull request what the menu does on a left click and on a right click. Do not expect the GNOME Shell 42 result there, because the menu's reaction to clicks was measured on GNOME Shell 42 only: `extension/` decides clicks in `vfunc_button_press_event`, and in the upstream GNOME Shell 46 and mutter 46 sources `PanelMenu.Button.vfunc_event` has already toggled the menu when that handler runs.
Static checks cannot replace these manual runs: lint and `tests/run.sh` do not see GNOME Shell API differences, and during the GNOME Shell 42 port a legacy file that read the mouse button through the wrong event accessor passed lint and every source contract check and still loaded as `ENABLED` while each click threw.
For process-detection and stop changes, include regression coverage for spoofed `--who` values with whitespace, pid files that point at a process without a logind inhibitor, successful inhibitor-list queries that miss a recorded blocker, duplicate matching persistent inhibitors, recorded-plus-duplicate blockers, and fallback stops that must not leave blocker process groups behind.
For lifecycle changes, include coverage that interrupted `nosleep on` does not leave a blocker or partial state files, delayed `setsid`/exec readiness still succeeds, and startup failure cleanup does not leave stale traps.
For locking/state-directory changes, include coverage that a preexisting `lock` symlink is not opened or truncated, a symlink runtime state directory is rejected, and concurrent first-time state directory creation succeeds.
For installer tests, isolate `gnome-extensions` with `NOSLEEP_GNOME_EXTENSIONS_CMD` and pin the GNOME Shell version with `NOSLEEP_GNOME_SHELL_CMD`, a command whose `--version` prints `GNOME Shell <version>` on stdout; the scripts reset `PATH` before normal command lookup, so fakes on `PATH` are ignored.
Both scripts accept only an executable file for these optional commands, whether it comes from an override or from the lookup on the reset `PATH`: a missing path, a file without the executable bit, a directory, or a name that is only a shell builtin or function is not run and counts as the command being unavailable. Tests use such a value to simulate a system without `gnome-shell` or `gnome-extensions`.
Every `install.sh` call in `tests/run.sh` must set both variables to a non-empty value (an empty one falls back to the host command), so the result never depends on the host's GNOME Shell.
New `uninstall.sh` test cases must go through `run_uninstall`, or set everything it sets: a temporary `HOME`, a temporary `XDG_RUNTIME_DIR`, a fake `systemd-inhibit` first in `NOSLEEP_TRUSTED_PATH`, and a non-empty `NOSLEEP_GNOME_EXTENSIONS_CMD`. The fake only empties the inhibitor list: `nosleep off` also stops a blocker recorded in the runtime state directory, so without the temporary `XDG_RUNTIME_DIR` a test can stop the developer's real persistent NoSleep and delete its state files.
For installer changes, include coverage that every Shell major declared in a variant's `metadata.json` selects that variant, an undeclared major warns but still links, an undetectable version leaves the extension link alone without calling `gnome-extensions`, the version line is parsed strictly (first stdout line only, nothing before `GNOME Shell`, a decimal major that ends at a dot or at the end of the line), an override that is not an executable file counts as a missing command in both scripts, switching between the variants of this checkout leaves no `*.bak.*` entry, links into another checkout are backed up by `install.sh` and preserved by `uninstall.sh`, and the restart/enable guidance matches the outcome of the enable call.
Neither `gjs -m extension/extension.js` nor `gjs extension-legacy/extension.js` is a reliable test outside GNOME Shell because both files import modules that only exist inside the Shell.
For extension subprocess termination code, a local `gjs -c` smoke check can verify that a `setsid`-launched subprocess tree is released when its process group receives SIGTERM.

## Commit & Pull Request Guidelines

Recent commits use short imperative subjects such as `Improve NoSleep status indicator` and `Generalize install path in README`. Follow that style: one focused change per commit, no trailing punctuation, and a clear verb.

Pull requests should describe behavior changes, list manual verification steps, and mention the Ubuntu/GNOME versions used for testing. Include screenshots only when the top-bar UI changes.

## Install Notes

Installation is symlink-based.
Changes in the checkout affect the installed CLI and extension immediately.
`install.sh` reads the GNOME Shell major version from the stdout of `gnome-shell --version` (run with `LC_ALL=C`; `NOSLEEP_GNOME_SHELL_CMD` overrides the command) and decides the variant before it creates any link: `extension/` for 45 and newer, `extension-legacy/` for older.
The installed link text is part of the interface: existing Ubuntu 24.04 installs are live symlinks to `<checkout>/extension`, so that directory must remain the GNOME Shell 45+ variant and `<checkout>/extension-legacy` the legacy one. Do not rename either directory, and keep the directory names in `install.sh` and `uninstall.sh` in sync.
A Shell major that the selected variant's `metadata.json` does not list is still linked, with a warning that the version is not supported.
When the Shell version cannot be determined, `install.sh` installs only the CLI link, neither creates nor changes the extension link, does not call `gnome-extensions`, prints a warning that names `NOSLEEP_GNOME_SHELL_CMD`, and exits 0.
Link ownership is an exact match of the link text. `install.sh` switches a link to the other variant of this checkout in place and backs up anything else in the way, including links into another checkout; `uninstall.sh` owns an extension link to either variant of this checkout, the CLI link to `<checkout>/bin/nosleep`, and nothing else.
Never back up an owned variant link: GNOME Shell tries to load every entry in the extensions directory, so a `*.bak.*` directory there logs a load error on each start.
GNOME Shell scans extension directories only when it starts, so the running Shell does not see a new or changed link. For a UUID it has not scanned, `gnome-extensions enable` fails without recording anything, and after the restart the extension stays disabled until it is enabled; for a link switched in a running session the enable call succeeds, but the Shell keeps the old state until it restarts. Keep that distinction separate from file installation failures.
The post-install guidance follows the enable call: when it failed, or no `gnome-extensions` command is available, print two unconditional ordered steps (restart GNOME Shell, then `gnome-extensions enable nosleep-toggle@systemd-inhibit.local`); when it succeeded and the extension link was created or changed, print the restart step only; otherwise print no restart hint.
The scripts must not write `org.gnome.shell` settings themselves, for example through `gsettings` or `dconf`: with a mismatched `HOME` and session bus, a read-modify-write could overwrite the real `enabled-extensions` list.
