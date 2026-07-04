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

const STATES = {
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
};

const NoSleepIndicator = GObject.registerClass(
class NoSleepIndicator extends PanelMenu.Button {
    _init(extensionDir) {
        super._init(0.0, 'NoSleep Toggle');

        this._extensionDir = extensionDir;
        this._ctlPath = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'nosleep']);
        this._state = 'off';
        this._refreshSourceId = 0;

        this._buildPanelButton();
        this._buildMenu();
        this._refresh();

        this._refreshSourceId = GLib.timeout_add_seconds(
            GLib.PRIORITY_DEFAULT,
            3,
            () => {
                this._refresh();
                return GLib.SOURCE_CONTINUE;
            }
        );
    }

    _buildPanelButton() {
        this._box = new St.BoxLayout({
            style_class: 'panel-status-menu-box',
            style: STATES.off.style,
        });

        this._icon = new St.Icon({
            gicon: this._iconForState('off'),
            style_class: 'system-status-icon',
        });

        this._label = new St.Label({
            text: STATES.off.label,
            y_align: Clutter.ActorAlign.CENTER,
            style: 'font-size: 11px; font-weight: 700;',
        });

        this._box.add_child(this._icon);
        this._box.add_child(this._label);
        this.add_child(this._box);
    }

    _buildMenu() {
        this._statusItem = new PopupMenu.PopupMenuItem(STATES.off.status);
        this._statusItem.setSensitive(false);
        this.menu.addMenuItem(this._statusItem);

        this._toggleItem = new PopupMenu.PopupMenuItem(STATES.off.toggle);
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

    _runCtl(args) {
        try {
            const proc = Gio.Subprocess.new(
                [this._ctlPath, ...args],
                Gio.SubprocessFlags.STDOUT_PIPE | Gio.SubprocessFlags.STDERR_PIPE
            );
            const [, stdout, stderr] = proc.communicate_utf8(null, null);

            if (!proc.get_successful()) {
                const message = (stderr || stdout || 'nosleep failed').trim();
                throw new Error(message);
            }

            return (stdout || '').trim();
        } catch (error) {
            logError(error);
            Main.notify('NoSleep', error.message);
            return null;
        }
    }

    _refresh() {
        const state = this._runCtl(['status']);
        if (state && STATES[state])
            this._setState(state);
    }

    _toggle() {
        const command = this._state === 'on' ? 'off' : 'on';
        const state = this._runCtl([command]);
        if (state === 'on') {
            this._setState('on');
            Main.notify('NoSleep', 'Sleep is blocked until you turn NoSleep off.');
        } else if (state === 'off') {
            this._setState('off');
            Main.notify('NoSleep', 'Sleep behavior is back to normal.');
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
        if (this._refreshSourceId) {
            GLib.Source.remove(this._refreshSourceId);
            this._refreshSourceId = 0;
        }

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
