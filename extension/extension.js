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

const NoSleepIndicator = GObject.registerClass(
class NoSleepIndicator extends PanelMenu.Button {
    _init(extensionDir) {
        super._init(0.0, 'NoSleep Toggle');

        this._extensionDir = extensionDir;
        this._ctlPath = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'bin', 'nosleep']);
        this._enabled = false;
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
        });

        this._icon = new St.Icon({
            gicon: this._iconForState(false),
            style_class: 'system-status-icon',
        });

        this._label = new St.Label({
            text: 'OFF',
            y_align: Clutter.ActorAlign.CENTER,
            style: 'padding-left: 4px;',
        });

        this._box.add_child(this._icon);
        this._box.add_child(this._label);
        this.add_child(this._box);
    }

    _buildMenu() {
        this._statusItem = new PopupMenu.PopupMenuItem('NoSleep: OFF');
        this._statusItem.setSensitive(false);
        this.menu.addMenuItem(this._statusItem);

        this._toggleItem = new PopupMenu.PopupMenuItem('Turn On');
        this._toggleItem.connect('activate', () => this._toggle());
        this.menu.addMenuItem(this._toggleItem);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());

        const refreshItem = new PopupMenu.PopupMenuItem('Refresh Status');
        refreshItem.connect('activate', () => this._refresh());
        this.menu.addMenuItem(refreshItem);
    }

    _iconForState(enabled) {
        const iconName = enabled ? 'nosleep-on-symbolic.svg' : 'nosleep-off-symbolic.svg';
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
        if (state === 'on')
            this._setState(true);
        else if (state === 'off')
            this._setState(false);
    }

    _toggle() {
        const state = this._runCtl(['toggle']);
        if (state === 'on') {
            this._setState(true);
            Main.notify('NoSleep', 'Lid-close suspend is blocked.');
        } else if (state === 'off') {
            this._setState(false);
            Main.notify('NoSleep', 'Lid-close suspend is back to normal.');
        }
    }

    _setState(enabled) {
        this._enabled = enabled;
        this._icon.gicon = this._iconForState(enabled);
        this._label.text = enabled ? 'ON' : 'OFF';
        this._statusItem.label.text = enabled ? 'NoSleep: ON' : 'NoSleep: OFF';
        this._toggleItem.label.text = enabled ? 'Turn Off' : 'Turn On';
        this.set_accessible_name(enabled ? 'NoSleep Toggle On' : 'NoSleep Toggle Off');
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
