import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string lifecyclePath: decodeURIComponent(
    Qt.resolvedUrl("bin/plugin-lifecycle").toString().replace(/^file:\/\//, "")
  )

  Process {
    id: activateProcess
    command: [root.lifecyclePath, "activate"]
    running: false
  }

  Component.onCompleted: activateProcess.running = true

  // A disable, removal, update, or shell restart unloads this object. Restart
  // through the adapter; it checks the current shell configuration and safely
  // selects either this plugin or Omarchy's packaged watcher.
  Component.onDestruction: Quickshell.execDetached([root.lifecyclePath, "refresh"])
}
