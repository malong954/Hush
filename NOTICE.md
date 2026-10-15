# Notices and acknowledgements

Hush is Copyright (C) 2026 Flip Digital Labs and is licensed under the GNU General Public
License, version 3 or (at your option) any later version. See [LICENSE](LICENSE).

Hush builds on the work of two open-source projects. Thank you to both.

## FineTune — GPL-3.0

<https://github.com/ronitsingh10/FineTune> · Copyright (C) 2026 Ronit Singh

Hush adapts techniques and code from FineTune, a per-app volume mixer for macOS, licensed under
the GNU General Public License v3.0:

- telling the HAL an I/O proc doesn't use the output device's hardware inputs
  (`kAudioDevicePropertyIOProcStreamUsage`), so duplex devices don't power up their mic
  (`AppVolumeTap.disableHardwareInputs`)
- waiting for a new aggregate device to come alive, the 30 ms gain-ramp formula, and turning off
  tap drift compensation for Bluetooth outputs (`AppVolumeTap`, `CoreAudioHelpers`)
- crediting helper processes to their app via `responsibility_get_pid_responsible_for_pid` and
  the parent-process walk (`AudioProcessScanner`)

## AudioCap — BSD 2-Clause

<https://github.com/insidegui/AudioCap>

Hush's process-tap and aggregate-device setup, Core Audio property helpers and audio-permission
check follow AudioCap's sample code (`AppVolumeTap`, `CoreAudioHelpers`, `AudioPermission`).

```
Copyright (c) 2024 Guilherme Rambo

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Apple documentation

Process taps, `CATapDescription` (including `bundleIDs` and `isProcessRestoreEnabled` on
macOS 26) and `CATapMuteBehavior` are documented at
<https://developer.apple.com/documentation/coreaudio/catapdescription>.

Both license files are copied into every built `Hush.app` (`Contents/Resources`).
