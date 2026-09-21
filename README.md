# CleanMyMac DynamicLake Plugin

Shows CleanMyMac scan and execution progress in the macOS notch via
[DynamicLake](https://www.dynamiclake.com). It uses CleanMyMac's official
module artwork, module-matched colors, a live progress circle, and the current
action (e.g. "Cleaning junk", "Running your tasks") in the Sneak Peek.

The compact activity can show either the official module icon (the default) in
the smallest DynamicLake layout or the module name in a wider layout. The icon
layout shows only the logo and progress, then a plain completion checkmark.
Smart Care uses CleanMyMac's pink computer module icon with the closest
DynamicLake palette tint (`purple`); Cleanup, Protection,
Performance, Applications, My Clutter, Space Lens, and Cloud Cleanup use their
matching CleanMyMac 5 artwork.

When a scan finishes it shows **Ready**, and when the run completes it shows
**Done** before dismissing.

## Requirements

- macOS with [DynamicLake Pro](https://www.dynamiclake.com) installed
- CleanMyMac 5 (`/Applications/CleanMyMac_5.app`)
- Accessibility permission for DynamicLake plugins (System Settings →
  Privacy & Security → Accessibility), so the plugin can read
  CleanMyMac's window state

## Install

1. Run `./scripts/build.sh` or download the release ZIP.
2. Install the resulting `CleanMyMac.dynamiclakeplugin` package through
   DynamicLake Settings → Plugins → Install Local.
3. In DynamicLake Settings, press **OK** on the CleanMyMac plugin to
   (re)load it. DynamicLake does not auto-reload plugins after a binary
   update.

## Build

```sh
./scripts/build.sh
./tests/run.sh
```

The build produces a universal arm64/x86_64 package and release ZIP in
`build/` and `dist/`. No dependencies beyond Xcode's macOS SDK are required.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| Compact appearance | select | Module icon | Choose the official module icon or the current module name. |
| Refresh | slider | 0.5s | Active-work fallback (0.5–5s). Idle and closed states automatically slow down. |
| Show when idle | switch | off | Keep CleanMyMac status visible when no scan is running. |

## Module appearance

| CleanMyMac mode | DynamicLake tint | Artwork |
| --- | --- | --- |
| Smart Care | Pink | Smart Care computer icon |
| Cleanup | Green | Cleanup module icon |
| Protection | Pink | Protection module icon |
| Performance | Orange | Performance module icon |
| Applications | Blue | Applications module icon |
| My Clutter | Cyan | My Clutter module icon |
| Space Lens | Purple | Space Lens module icon |
| Cloud Cleanup | Blue | Cloud Cleanup module icon |

## How it works

- Watches CleanMyMac launch/quit events and caches the verified main-app PID,
  with a throttled `libproc` fallback that ignores helpers (Menu,
  HealthMonitor, FinderSyncExtension, Agent).
- Reads scan/execution state from the Accessibility tree, with a
  `CGWindowList` fallback that needs no permissions.
- Tracks Smart Care phases (Cleanup → Protection → Performance →
  Applications → My Clutter) for both scanning and execution, in 12 UI
  languages.
- Distinguishes My Clutter, Space Lens, and Cloud Cleanup instead of grouping
  them under one generic storage mode, and clears stale execution state when
  navigating between their intro and result screens.
- Mirrors CleanMyMac's accessible percentage immediately when one is exposed.
  Otherwise it shows a stable phase checkpoint that advances only when
  CleanMyMac changes phase—without a permanently spinning indicator or a
  drifting time-based estimate.
- Observes value and layout changes for prompt phase transitions, coalesces
  noisy UI event bursts, and switches directly to Ready/Done when CleanMyMac
  reaches its result screen.
- Polls adaptively: the chosen refresh rate while scanning, 2 seconds while
  CleanMyMac is idle, and 15 seconds while the app is closed. Settings are
  cached and checked at most once every 5 seconds instead of on every tick.
- Gives My Clutter's explicit results screen priority over stale accessibility
  progress nodes, so its progress ends immediately with the completion check.
- Recognizes Space Lens while it is visualizing storage and both its normal
  storage-map and empty-folder completion screens.
- Pushes `compactLiveActivity` (label + progress circle / Ready-Done text)
  and `sneakPeek` (icon + action text + phase icon) surfaces over
  DynamicLake's JSON socket protocol.

Debug log: `~/Library/Application Support/DynamicLake/PluginLogs/cleanmymac-debug.log`.
High-volume Accessibility diagnostics are off by default; launch the plugin
with `DYNAMICLAKE_CLEANMYMAC_DEBUG=1` only when detailed troubleshooting is
needed.

## License

MIT — see [LICENSE](LICENSE).

This is an independent community integration and is not endorsed by MacPaw or
DynamicLake. CleanMyMac and its module artwork are trademarks and assets of
MacPaw; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
