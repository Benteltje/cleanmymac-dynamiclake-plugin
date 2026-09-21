# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.11] - 2026-09-21

### Added

- Official CleanMyMac 5 module artwork (`Assets/`, 8 modules) with
  module-matched DynamicLake tints and inline Sneak Peek / compact icons.
- New `compactPresentation` setting: `Module icon` (smallest icon-and-progress
  layout, default) or `Module name` (wider layout with full module label).
- Dedicated `My Clutter`, `Space Lens`, and `Cloud Cleanup` module support
  with own colors, SF Symbols, artwork, and 12-language detection.
- `scripts/build.sh`: universal arm64/x86_64 build plus versioned release ZIP
  (`dist/CleanMyMac-<version>.dynamiclakeplugin.zip`).
- `tests/run.sh`: self-test, settings payload checks, 48 KiB asset /
  64 KiB frame limit checks, and universal-binary verification.
- `THIRD_PARTY_NOTICES.md` with MacPaw / DynamicLake attribution.
- Gated verbose diagnostics via `DYNAMICLAKE_CLEANMYMAC_DEBUG=1`; debug log at
  `~/Library/Application Support/DynamicLake/PluginLogs/cleanmymac-debug.log`.

### Changed

- Progress now mirrors CleanMyMac's accessible percentage immediately; when
  none is exposed it shows a stable phase checkpoint that advances only on
  real phase changes (no permanently spinning indicator, no drifting
  time-based estimate).
- Adaptive polling: configured refresh while active, 2s when idle, 15s when
  closed; settings are cached and re-checked at most every 5s.
- Accessibility tree is now read in a single pass per window
  (`collectAXWindowSnapshot`), reducing IPC overhead.
- Active-work detection (`hasActiveOperation`) only matches real in-progress
  phrases, so result-screen buttons (e.g. `Remove`) and stale sidebar content
  no longer trigger false runs.
- PID handling caches the verified main-app PID with a throttled `libproc`
  fallback and separates main-app from helper bundle IDs
  (Menu, HealthMonitor, FinderSyncExtension, Agent).
- `plugin.json`: active refresh default `0.5s` (was `1.0s`), `systemImage` /
  `tint` metadata for all settings, clearer descriptions.
- README: module-appearance table, updated install via
  DynamicLake Settings → Plugins → Install Local, expanded
  "How it works" section.
- Release packaging now ships `LICENSE` and `THIRD_PARTY_NOTICES.md` inside
  the `.dynamiclakeplugin` bundle.

### Fixed

- `My Clutter` no longer grouped under Space Lens; both modules (plus
  Cloud Cleanup) have separate result-screen handling and stale execution
  state is cleared when navigating between intro / result screens.
- My Clutter explicit results page takes priority over stale accessibility
  progress nodes, so progress ends with the completion check.
- Space Lens recognized while visualizing storage and on both its normal
  storage-map and empty-folder completion screens.
- Empty `ModuleNameLabel` / `IntroViewTitleLabel` values are ignored instead
  of overwriting the detected module.
- Robust settings parsing for numeric / boolean values supplied as strings
  by DynamicLake.
