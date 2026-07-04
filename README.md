# nosleep-toggle

[Japanese README](README.ja.md)

`nosleep-toggle` toggles lid-close suspend and idle sleep inhibition from the Ubuntu GNOME top bar.

It uses `systemd-inhibit`, so it temporarily blocks sleep without changing permanent power settings.
It is intended for short moves while a long-running CLI command keeps running.

## Supported Environment

- Ubuntu 24.04
- GNOME Shell 46
- systemd

Ubuntu 22.04 / GNOME Shell 42 is not supported yet.

## Install

```bash
git clone https://github.com/rsuwa/nosleep-toggle.git
cd nosleep-toggle
./install.sh
```

If GNOME Shell does not detect the new extension immediately, log out and log back in.

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

Use the same `nosleep` command to inhibit sleep only while a command runs:

```bash
nosleep long-command --option
nosleep run long-command --option
nosleep shell
```

`nosleep run ...` is the explicit form.
Use it when the command name conflicts with a `nosleep` subcommand.

## Safety

Running a laptop while it is inside a bag can generate heat.
Use this for short moves, not long unattended runs.
