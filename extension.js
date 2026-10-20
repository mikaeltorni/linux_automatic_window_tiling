/** Register the extension's shortcuts and D-Bus interface, and release them on disable. */

import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import Gio from 'gi://Gio';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import { LOG_PREFIX, WindowTiler } from './tiling.js';

const TILE_KEY = 'tile-focused-application-windows';
const ALL_TILE_KEY = 'tile-all-windows';
const DBUS_BUS_NAME = 'org.gnome.shell.extensions.AutomaticWindowTiling';
const DBUS_OBJECT_PATH = '/org/gnome/shell/extensions/automatic_window_tiling';
const DBUS_INTERFACE_XML = `
<node name="/org/gnome/shell/extensions/automatic_window_tiling">
  <interface name="org.gnome.shell.extensions.AutomaticWindowTiling">
    <method name="TileWindowGroup">
      <arg type="s" name="windowId" direction="in"/>
    </method>
    <method name="TileWindowGroups">
      <arg type="as" name="windowIds" direction="in"/>
    </method>
  </interface>
</node>`;

/** Own the GNOME resources associated with one enabled extension instance. */
export default class AutomaticWindowTilingExtension extends Extension {
  /**
   * Register both shortcuts and expose the existing background-placement API.
   * Parameters: this - GNOME extension instance.
   * Returns: undefined after registering callbacks and the bus name.
   */
  enable() {
    console.log('AutomaticWindowTilingExtension.enable parameters', { 'this': this });
    this._settings = this.getSettings();
    this._tiler = new WindowTiler(this._settings);
    Main.wm.addKeybinding(TILE_KEY, this._settings, Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL, () => this._tiler.tileFocusedApplicationWindows());
    Main.wm.addKeybinding(ALL_TILE_KEY, this._settings, Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL, () => this._tiler.tileAllWindows());
    this._dbusObject = Gio.DBusExportedObject.wrapJSObject(DBUS_INTERFACE_XML, {
      TileWindowGroup: windowId => this._tiler.tileWindowGroup(windowId),
      TileWindowGroups: windowIds => this._tiler.tileWindowGroups(windowIds),
    });
    this._dbusObject.export(Gio.DBus.session, DBUS_OBJECT_PATH);
    this._dbusOwnerId = Gio.bus_own_name_on_connection(
      Gio.DBus.session, DBUS_BUS_NAME, Gio.BusNameOwnerFlags.NONE, null, null,
    );
    console.log(`${LOG_PREFIX}: enabled; focused-application and all-window tiling keybindings registered`);
    console.log(undefined);
  }

  /**
   * Remove shortcuts, unexport D-Bus callbacks and release retained settings.
   * Parameters: this - GNOME extension instance.
   * Returns: undefined after releasing registered resources.
   */
  disable() {
    console.log('AutomaticWindowTilingExtension.disable parameters', { 'this': this });
    if (this._dbusOwnerId) {
      Gio.bus_unown_name(this._dbusOwnerId);
      this._dbusOwnerId = null;
    }
    if (this._dbusObject) {
      this._dbusObject.unexport();
      this._dbusObject = null;
    }
    Main.wm.removeKeybinding(TILE_KEY);
    Main.wm.removeKeybinding(ALL_TILE_KEY);
    this._tiler = null;
    this._settings = null;
    console.log(`${LOG_PREFIX}: disabled; tiling keybinding removed`);
    console.log(undefined);
  }
}
