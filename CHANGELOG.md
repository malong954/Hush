# Changelog

All notable changes to Hush. Versions follow [Semantic Versioning](https://semver.org).

## [1.3.0] — 2026-10-14

### Added
- App icon.
- Notarized, universal (Apple silicon + Intel) DMG builds via `release.sh` and GitHub Actions.
- Open source under GPL-3.0-or-later, with credits to FineTune and AudioCap.

### Changed
- Development builds use the hardened runtime, the same as releases.

## [1.2.1] — 2026-10-14

### Fixed
- Mutes had no effect in 1.2.0: a process tap only mutes while it's being read. Every muted
  process now has its own always-running reader.
- A mute that fails to start (for example, a process still launching) now retries every few
  seconds instead of never.

### Changed
- Muting and volume use the same mechanism, so switching between them is just a gain change.
- Processes that are making sound are muted first.

## [1.2.0] — 2026-10-14

### Added
- Each simulator window is its own row, named from its `device.plist`, with its own mute and
  volume. Expand it to mute single apps inside it.
- Mac apps with several audio processes expand to mute processes one by one.
- Android emulators are split per AVD.

### Changed
- The most specific setting wins: all Simulators → one simulator → one app in it.

## [1.1.0] — 2026-10-14

### Fixed
- Brief bursts of sound from muted Simulator apps when another copy launched or relaunched.

### Added
- macOS 26: standing taps keep known apps muted from their first sample after a relaunch.

### Changed
- Faster detection of new processes.

## [1.0.0] — 2026-10-13

- First version: menu bar mixer with per-app volume and mute, and a Mute Simulators switch that
  survives rebuilds.
