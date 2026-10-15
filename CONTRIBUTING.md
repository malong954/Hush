# Contributing to Hush

Thanks for helping. Bug reports, fixes and small focused features are all welcome.

## Reporting a bug

[Open an issue](https://github.com/malong954/Hush/issues/new/choose) and include:

- macOS version and Mac (Apple silicon or Intel)
- Hush version (shown at the top of the ⚙ menu)
- What the Hush panel shows for the app or simulator in question (a screenshot helps)
- Whether the sound leaks continuously, only at launch, or only after something specific
  (switching output device, waking from sleep, updating Hush)

## Building

```bash
./build.sh install
```

Xcode 15.3+ on macOS 14.2+. You can also `open Package.swift` in Xcode to edit, but run through
`build.sh` to test: the audio permission prompt needs the `.app` bundle's `Info.plist`.

## Pull requests

- Keep changes focused; one fix or feature per PR.
- The I/O callback in `AppVolumeTap.render` runs on Core Audio's real-time thread: no
  allocations, locks, logging or Objective-C calls in there.
- Never let a change destroy a process's tap before its replacement is running — that's what
  causes sound to leak through. `Mixer.reconcileOnce` builds new taps first and removes old ones
  last; keep that order.
- CI builds every PR for Apple silicon and Intel. Please also test with a few simulators running.
- New files start with the SPDX header used in the existing sources.

By contributing you agree your contribution is licensed under the project's
GPL-3.0-or-later license.
