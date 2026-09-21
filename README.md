# CleanMyMac DynamicLake Plugin

Shows CleanMyMac scan and execution progress in the macOS notch via
[DynamicLake](https://www.dynamiclake.com). Displays the scan type, a live
progress circle with color-coded indicators, and the current action
(e.g. "Cleaning junk", "Running your tasks") in the Sneak Peek.

When a scan finishes it shows **Ready**, and when the run completes it shows
**Done** before dismissing.

## Requirements

- macOS with [DynamicLake Pro](https://www.dynamiclake.com) installed
- CleanMyMac 5 (`/Applications/CleanMyMac_5.app`)
- Accessibility permission for DynamicLake plugins (System Settings →
  Privacy & Security → Accessibility), so the plugin can read
  CleanMyMac's window state

## Install

1. Build the monitor binary (see below) or grab it from a release.
2. Copy these files to the DynamicLake JSON plugins folder, e.g.
   `~/Library/Application Support/DynamicLake/Plugins/JSON/com.dynamiclake.plugins.cleanmymac.dynamiclakeplugin/`:
   - `cleanmymac-monitor`
   - `plugin.json`
   - `CleanMyMacIcon.png`
3. In DynamicLake Settings, press **OK** on the CleanMyMac plugin to
   (re)load it. DynamicLake does not auto-reload plugins after a binary
   update.

## Build

```sh
swiftc -parse-as-library Sources/CleanMyMacPlugin.swift -o cleanmymac-monitor
```

No dependencies beyond the macOS SDK.

## Settings

| Setting       | Type   | Default | Description                                        |
| ------------- | ------ | ------- | -------------------------------------------------- |
| Refresh       | slider | 1.0s    | Poll interval (0.5–5s). An event observer drives faster updates while scanning. |
| Show when idle| switch | off     | Show status even when no scan is running.          |

## How it works

- Finds the CleanMyMac main app PID with a live kernel query (`libproc`),
  ignoring helpers (Menu, HealthMonitor, FinderSyncExtension, Agent).
- Reads scan/execution state from the Accessibility tree, with a
  `CGWindowList` fallback that needs no permissions.
- Tracks Smart Care phases (Cleanup → Protection → Performance →
  Applications → My Clutter) for both scanning and execution, in 12 UI
  languages.
- Smooths progress (slew limiter + fill-to-100 on completion) while
  respecting DynamicLake's update rate limit.
- Pushes `compactLiveActivity` (label + progress circle / Ready-Done text)
  and `sneakPeek` (icon + action text + phase icon) surfaces over
  DynamicLake's JSON socket protocol.

Debug log: `~/Library/Application Support/DynamicLake/PluginLogs/cleanmymac-debug.log`

## License

MIT — see [LICENSE](LICENSE).
