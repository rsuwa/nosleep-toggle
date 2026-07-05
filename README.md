# nosleep-toggle

[Japanese README](README.ja.md)

`nosleep-toggle` toggles lid-close suspend and idle sleep inhibition from the Ubuntu GNOME top bar.

It uses `systemd-inhibit`, so it temporarily blocks sleep without changing permanent power settings.
It is intended for short moves while a long-running CLI command keeps running.

## Supported Environment

- Ubuntu 24.04
- GNOME Shell 46
- systemd
- `systemd-inhibit`, `setsid`, and `flock`

Ubuntu 22.04 / GNOME Shell 42 is not supported yet.

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

If GNOME Shell does not detect the new extension immediately, log out and log back in.

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
./tests/run.sh
```

The test script uses temporary runtime and home directories.
It skips the CLI state test if another `nosleep` inhibitor is already active.

## Safety

Running a laptop while it is inside a bag can generate heat.
Use this for short moves, not long unattended runs.

NoSleep requests logind inhibitors for the lid switch, sleep/hibernate, and idle sleep.
It does not block shutdown, critical battery actions, thermal shutdown, administrator policy, crashes, logout, or system updates.
Disabling the GNOME extension removes the top-bar control, but it does not guarantee that an already active persistent inhibitor is stopped.
Run `nosleep off` before disabling the extension if NoSleep is active.
