# nosleep-toggle

[Japanese README](README.ja.md)

`nosleep-toggle` toggles lid-close suspend and idle sleep inhibition from the Ubuntu GNOME top bar.

It uses `systemd-inhibit`, so it temporarily blocks sleep without changing permanent power settings.
It is intended for short moves while a long-running CLI command keeps running.

## Supported Environment

- Ubuntu 24.04 with GNOME Shell 46
- Ubuntu 22.04 with GNOME Shell 42
- systemd
- `systemd-inhibit`, `setsid`, and `flock`

Other GNOME Shell versions are not supported.
The installer warns about them and links the extension anyway, but GNOME Shell may report it as out of date.

## Install

```bash
git clone https://github.com/rsuwa/nosleep-toggle.git
cd nosleep-toggle
./install.sh
```

The installer creates symlinks into this checkout.
Keep the cloned repository in place after installation.
Because the installed CLI and extension are symlinks, later edits, branch changes, or `git pull` in this checkout immediately affect the installed behavior.
Install only from a checkout you control.

The extension link points at the variant for the installed GNOME Shell version: `extension/` for GNOME Shell 46 and `extension-legacy/` for GNOME Shell 42.
Run `./install.sh` again after upgrading Ubuntu or GNOME Shell, for example from Ubuntu 22.04 to 24.04.
Also run it again once if you installed on Ubuntu 22.04 before nosleep-toggle supported it.

GNOME Shell only picks up a new or changed extension when it starts.
After a first install, restart GNOME Shell first.
To do that, log out and log back in (on an X11 session you can press Alt+F2, type `r`, and press Enter instead).
After the restart, enable the extension with the command below, or run `./install.sh` again.

```bash
gnome-extensions enable nosleep-toggle@systemd-inhibit.local
```

When the installer only switched the link of an extension that was already enabled, restarting GNOME Shell is enough.
The installer prints the steps that apply to your case.

## Uninstall

```bash
./uninstall.sh
```

The uninstaller turns persistent NoSleep off, disables the extension when possible, and removes only symlinks that point to this checkout.

## Usage

Click the status indicator in the top bar.

- `Sleep`: sleep is allowed
- `Awake`: sleep is blocked until NoSleep is turned off
- `Run`: sleep is blocked while a command is running through `nosleep`

Clicking `Sleep` turns NoSleep on.
Clicking `Awake` turns NoSleep off.
Clicking `Run` keeps the running command untouched and promotes NoSleep to `Awake`.

CLI usage:

```bash
nosleep on
nosleep off
nosleep toggle
nosleep status
```

`nosleep status` prints `off`, `on`, or `running`.
`nosleep --raw-status` prints the raw global `systemd-inhibit` list for troubleshooting.
The older `nosleep --status` alias is still accepted.

Use the same `nosleep` command to inhibit sleep only while a command runs:

```bash
nosleep long-command --option
nosleep run long-command --option
nosleep shell
nosleep
```

`nosleep run ...` is the explicit form.
Use it when the command name conflicts with a `nosleep` subcommand.
Running `nosleep` without arguments starts an inhibited shell.

## Test

```bash
npm install
npm run lint:js
./tests/run.sh
```

The lint tooling (ESLint 9) needs Node.js 18.18 or newer (`^18.18.0 || ^20.9.0 || >=21.1.0`).
Ubuntu 22.04's packaged Node.js 12 is too old; use a newer Node.js there, for example via nvm.
Using nosleep-toggle itself does not require Node.js.

The test script uses temporary runtime and home directories.
When npm dependencies are installed and a supported Node.js version is detected, it also runs the JavaScript lint check; otherwise it skips that step and says why.
It skips the CLI state test if another `nosleep` inhibitor is already active.

## Safety

Running a laptop while it is inside a bag can generate heat.
Use this for short moves, not long unattended runs.

NoSleep requests logind inhibitors for the lid switch, sleep/hibernate, and idle sleep.
It does not block shutdown, critical battery actions, thermal shutdown, administrator policy, crashes, logout, or system updates.
Disabling the GNOME extension removes the top-bar control, but it does not guarantee that an already active persistent inhibitor is stopped.
Run `nosleep off` before disabling the extension if NoSleep is active.
