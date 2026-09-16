# Codex Crash Diagnostic Model Picker

An Omarchy service plugin that makes crash notifications easier to dismiss and
lets you choose the Codex model and reasoning level before diagnosis starts.

Crash notifications say **“Left-click diagnose · Right-click dismiss.”** The
notification action checks your default agent when you click it:

- Codex opens a terminal picker for the model and then the reasoning level.
- Any other Omarchy agent uses the standard `omarchy-agent-crash` flow.
- Changing the default agent after a notification appears is respected.
- If Codex is selected but unavailable, the plugin reports that clearly before
  handing control to Omarchy's standard diagnosis path.

## Install

```sh
omarchy plugin add https://github.com/cylon58/omarchy-codex-crash-model-picker.git --enable
```

The service plugin activates itself when enabled. No root privileges are used.

## Codex choices

The picker currently offers:

- GPT-5.6 Sol, Terra, and Luna: `none`, `low`, `medium`, `high`, `xhigh`, `max`
- GPT-6 Astra: `low`, `medium`, `high`, `xhigh`, `max`

The values in `~/.codex/config.toml` are preselected when supported. Escape at
either picker cancels the diagnosis.

## Requirements

- Omarchy Quattro with crash capture enabled
- `systemd-coredump`, `jq`, and `gum` (included by Omarchy)
- Codex CLI for the Codex-specific picker
- Any non-Codex default agent continues to use Omarchy's normal crash workflow

## Files and commands used

The plugin reads systemd-coredump events and the current Omarchy default agent.
It invokes `journalctl`, `coredumpctl`, `jq`, `gum`, `codex`,
`omarchy-agent-crash`, `omarchy-notification-send`, and `systemctl --user`.

Enabling the plugin writes two user-owned integration files:

- `~/.local/bin/omarchy-crash-watch-plugin-adapter`
- `~/.config/systemd/user/omarchy-crash-watch.service.d/zz-codex-crash-model-picker.conf`

The adapter fails safely: when this plugin is disabled or absent, it executes
Omarchy's packaged `/usr/bin/omarchy-crash-watch`.

## Disable

```sh
omarchy plugin disable io.github.cylon58.codex-crash-model-picker
```

Disabling immediately returns crash handling to Omarchy's packaged watcher.

## Remove

Run the bundled cleanup first, then remove the plugin:

```sh
~/.config/omarchy/plugins/io.github.cylon58.codex-crash-model-picker/bin/plugin-lifecycle uninstall
omarchy plugin remove io.github.cylon58.codex-crash-model-picker
```

If the plugin directory is removed without cleanup, crash handling still falls
back safely to Omarchy. The two integration files listed above can then be
removed manually before running:

```sh
systemctl --user daemon-reload
systemctl --user restart omarchy-crash-watch.service
```

## Development

```sh
omarchy plugin validate .
tests/test-crash-picker.sh
tests/test-plugin-lifecycle.sh
bash -n bin/* tests/*.sh
```

## License

MIT
