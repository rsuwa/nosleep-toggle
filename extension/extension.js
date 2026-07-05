import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import St from 'gi://St';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';

const UUID = 'nosleep-toggle@systemd-inhibit.local';
const REFRESH_INTERVAL_SECONDS = 3;
const MAX_REFRESH_INTERVAL_SECONDS = 30;
const COMMAND_TIMEOUT_SECONDS = 5;
const FORCE_EXIT_DELAY_SECONDS = 1;
const KILL_PATH = '/bin/kill';
const SETSID_PATH = '/usr/bin/setsid';
const SIGTERM = 15;
const SIGKILL = 9;

Gio._promisify(Gio.Subprocess.prototype, 'communicate_utf8_async');

const STATES = {
    loading: {
        icon: 'nosleep-off-symbolic.svg',
        label: '...',
        status: 'NoSleep: Checking status',
        toggle: 'Checking',
        accessible: 'NoSleep Toggle Checking',
        style: 'spacing: 5px; padding: 0 7px; margin: 2px 0; border-radius: 999px; background-color: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.16);',
    },
    off: {
        icon: 'nosleep-off-symbolic.svg',
        label: 'Sleep',
        status: 'NoSleep: Sleep allowed',
        toggle: 'Turn On',
        accessible: 'NoSleep Toggle Off',
        style: 'spacing: 5px; padding: 0 7px; margin: 2px 0; border-radius: 999px; background-color: rgba(255, 255, 255, 0.08); border: 1px solid rgba(255, 255, 255, 0.16);',
    },
    on: {
        icon: 'nosleep-on-symbolic.svg',
        label: 'Awake',
        status: 'NoSleep: Always awake',
        toggle: 'Turn Off',
        accessible: 'NoSleep Toggle On',
        style: 'spacing: 5px; padding: 0 7px; margin: 2px 0; border-radius: 999px; background-color: rgba(46, 194, 126, 0.22); border: 1px solid rgba(46, 194, 126, 0.48);',
    },
    running: {
        icon: 'nosleep-running-symbolic.svg',
        label: 'Run',
        status: 'NoSleep: Active for command',
        toggle: 'Keep On',
        accessible: 'NoSleep Toggle Running',
        style: 'spacing: 5px; padding: 0 7px; margin: 2px 0; border-radius: 999px; background-color: rgba(245, 169, 71, 0.22); border: 1px solid rgba(245, 169, 71, 0.52);',
    },
    unknown: {
        icon: 'nosleep-off-symbolic.svg',
        label: 'Error',
        status: 'NoSleep: Status unknown',
        toggle: 'Retry',
        accessible: 'NoSleep Toggle Unknown',
        style: 'spacing: 5px; padding: 0 7px; margin: 2px 0; border-radius: 999px; background-color: rgba(226, 82, 82, 0.22); border: 1px solid rgba(226, 82, 82, 0.52);',
    },
};

const NoSleepIndicator = GObject.registerClass(
class NoSleepIndicator extends PanelMenu.Button {
    _init(extensionDir) {
        super._init(0.0, 'NoSleep Toggle');

        this._extensionDir = extensionDir;
        this._ctlPath = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'nosleep']);
        this._state = 'loading';
        this._statusLoaded = false;
        this._refreshSourceId = 0;
        this._refreshIntervalSeconds = REFRESH_INTERVAL_SECONDS;
        this._refreshInFlight = false;
        this._actionInFlight = false;
        this._stateGeneration = 0;
        this._destroyed = false;
        this._activeControls = new Set();

        this._buildPanelButton();
        this._buildMenu();
        this._refresh();
        this._scheduleRefresh(REFRESH_INTERVAL_SECONDS);
    }

    _buildPanelButton() {
        this._box = new St.BoxLayout({
            style_class: 'panel-status-menu-box',
            style: STATES.loading.style,
        });

        this._icon = new St.Icon({
            gicon: this._iconForState('loading'),
            style_class: 'system-status-icon',
        });

        this._label = new St.Label({
            text: STATES.loading.label,
            y_align: Clutter.ActorAlign.CENTER,
            style: 'font-size: 11px; font-weight: 700;',
        });

        this._box.add_child(this._icon);
        this._box.add_child(this._label);
        this.add_child(this._box);
    }

    _buildMenu() {
        this._statusItem = new PopupMenu.PopupMenuItem(STATES.loading.status);
        this._statusItem.setSensitive(false);
        this.menu.addMenuItem(this._statusItem);

        this._toggleItem = new PopupMenu.PopupMenuItem(STATES.loading.toggle);
        this._toggleItem.setSensitive(false);
        this._toggleItem.connect('activate', () => this._toggle());
        this.menu.addMenuItem(this._toggleItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const refreshItem = new PopupMenu.PopupMenuItem('Refresh Status');
        refreshItem.connect('activate', () => this._refresh());
        this.menu.addMenuItem(refreshItem);
    }

    _iconForState(state) {
        const iconName = STATES[state]?.icon ?? STATES.off.icon;
        const path = this._extensionDir.get_child('icons').get_child(iconName).get_path();
        return new Gio.FileIcon({file: Gio.File.new_for_path(path)});
    }

    _scheduleRefresh(delaySeconds) {
        if (this._destroyed || this._refreshSourceId)
            return;

        this._refreshSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            delaySeconds,
            () => {
                this._refreshSourceId = 0;
                this._refresh().finally(() => this._scheduleRefresh(this._refreshIntervalSeconds));
                return GLib.SOURCE_REMOVE;
            }
        );
    }

    async _runCtl(args, {notify = true} = {}) {
        const cancellable = new Gio.Cancellable();
        const control = {cancellable, proc: null, processGroupId: null, forceExitSourceId: 0};
        let proc = null;
        let cancelId = 0;
        let timeoutId = 0;
        let timedOut = false;

        this._activeControls.add(control);
        try {
            proc = Gio.Subprocess.new(
                [SETSID_PATH, this._ctlPath, ...args],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            control.proc = proc;
            control.processGroupId = proc.get_identifier?.() ?? null;

            cancelId = cancellable.connect(() => this._terminateControl(control));
            timeoutId = GLib.timeout_add_seconds(
                GLib.PRIORITY_DEFAULT,
                COMMAND_TIMEOUT_SECONDS,
                () => {
                    timeoutId = 0;
                    timedOut = true;
                    cancellable.cancel();
                    return GLib.SOURCE_REMOVE;
                }
            );

            const [stdout, stderr] = await proc.communicate_utf8_async(null, null);

            if (!proc.get_successful()) {
                const message = (stderr || stdout || 'nosleep failed').trim();
                throw new Error(message);
            }

            return (stdout || '').trim();
        } catch (error) {
            if (notify && !this._destroyed) {
                logError(error);
                Main.notify('NoSleep', timedOut ? 'nosleep timed out' : error.message);
            }
            return null;
        } finally {
            if (timeoutId)
                GLib.Source.remove(timeoutId);
            if (control.forceExitSourceId)
                GLib.Source.remove(control.forceExitSourceId);
            if (cancelId)
                cancellable.disconnect(cancelId);
            this._activeControls.delete(control);
        }
    }

    _signalControl(control, signal) {
        if (control.processGroupId?.match(/^[0-9]+$/)) {
            try {
                Gio.Subprocess.new(
                    [KILL_PATH, `-${signal}`, '--', `-${control.processGroupId}`],
                    Gio.SubprocessFlags.NONE
                );
                return true;
            } catch (error) {
                logError(error);
            }
        }

        try {
            control.proc.send_signal(signal);
            return true;
        } catch {
            return false;
        }
    }

    _terminateControl(control) {
        if (!control.proc)
            return;

        if (!this._signalControl(control, SIGTERM)) {
            control.proc.force_exit();
            return;
        }

        if (control.forceExitSourceId)
            return;

        control.forceExitSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            FORCE_EXIT_DELAY_SECONDS,
            () => {
                control.forceExitSourceId = 0;
                if (control.proc) {
                    this._signalControl(control, SIGKILL);
                    control.proc.force_exit();
                }
                return GLib.SOURCE_REMOVE;
            }
        );
    }

    async _refresh({notify = false, force = false} = {}) {
        if (this._refreshInFlight || (!force && this._actionInFlight))
            return;

        const generation = this._stateGeneration;
        this._refreshInFlight = true;
        try {
            const state = await this._runCtl(['status'], {notify});
            if (!force && (this._destroyed || this._actionInFlight || generation !== this._stateGeneration))
                return;

            if (!this._destroyed && state && STATES[state]) {
                this._setState(state);
                this._statusLoaded = true;
                this._refreshIntervalSeconds = REFRESH_INTERVAL_SECONDS;
            } else if (!this._destroyed) {
                this._setState('unknown');
                this._statusLoaded = true;
                this._refreshIntervalSeconds = Math.min(this._refreshIntervalSeconds * 2, MAX_REFRESH_INTERVAL_SECONDS);
            }
        } finally {
            this._refreshInFlight = false;
        }
    }

    async _toggle() {
        if (this._actionInFlight)
            return;

        this._actionInFlight = true;
        this._stateGeneration++;
        try {
            if (!this._statusLoaded) {
                await this._refresh({notify: true, force: true});
                return;
            }

            if (this._state === 'unknown') {
                await this._refresh({notify: true, force: true});
                return;
            }

            const command = this._state === 'on' ? 'off' : 'on';
            const state = await this._runCtl([command]);
            if (this._destroyed)
                return;

            if (state === 'on') {
                this._setState('on');
                Main.notify('NoSleep', 'Sleep is blocked until you turn NoSleep off.');
            } else if (state === 'off') {
                this._setState('off');
                Main.notify('NoSleep', 'Sleep behavior is back to normal.');
            } else if (state === 'running') {
                this._setState('running');
                Main.notify('NoSleep', 'Sleep is still blocked while a command is running.');
            } else {
                this._setState('unknown');
            }
        } finally {
            this._actionInFlight = false;
        }
    }

    _setState(state) {
        const stateInfo = STATES[state] ?? STATES.off;
        this._state = state;
        this._box.set_style(stateInfo.style);
        this._icon.gicon = this._iconForState(state);
        this._label.text = stateInfo.label;
        this._statusItem.label.text = stateInfo.status;
        this._toggleItem.label.text = stateInfo.toggle;
        this._toggleItem.setSensitive(state !== 'loading');
        this.set_accessible_name(stateInfo.accessible);
    }

    vfunc_button_press_event(event) {
        if (event.get_button() === Clutter.BUTTON_PRIMARY) {
            this._toggle();
            return Clutter.EVENT_STOP;
        }

        if (event.get_button() === Clutter.BUTTON_SECONDARY) {
            this.menu.toggle();
            return Clutter.EVENT_STOP;
        }

        return Clutter.EVENT_PROPAGATE;
    }

    destroy() {
        this._destroyed = true;

        if (this._refreshSourceId) {
            GLib.Source.remove(this._refreshSourceId);
            this._refreshSourceId = 0;
        }

        for (const control of [...this._activeControls]) {
            control.cancellable.cancel();
            this._terminateControl(control);
        }
        this._activeControls.clear();

        super.destroy();
    }
});

export default class NoSleepToggleExtension extends Extension {
    enable() {
        this._indicator = new NoSleepIndicator(Gio.File.new_for_path(this.path));
        Main.panel.addToStatusArea(UUID, this._indicator, 1, 'right');
    }

    disable() {
        if (this._indicator) {
            this._indicator.destroy();
            this._indicator = null;
        }
    }
}
