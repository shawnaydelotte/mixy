# Developing Mixy

## Toolchain

The project was created in Xcode 26.3 / 27 and targets **macOS 14.4**. On this machine the full IDE is **Xcode.app** (`/Applications/Xcode.app`, Xcode 27.0 / 27A266a). `xcode-select -p` is `/Library/Developer/CommandLineTools`, which has no `xcodebuild` schemes and no `mcpbridge`.

Always pin the developer directory:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

`make` does this when `DEVELOPER_DIR` is unset.

Switching the system default requires admin:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
```

Signing is ad-hoc (`CODE_SIGN_IDENTITY = "-"`). Debug is sandboxed. Release enables the hardened runtime.

## Build and test

```bash
make list          # targets: mixy, mixyTests, MixyHAL; schemes: mixy, MixyHAL
make build
make test          # 66 hosted unit tests
make test-hal      # MixyHAL.driver only
make run
make inventory     # live HAL JSON, then quit
make clean
```

From Xcode: open `mixy.xcodeproj`, scheme **mixy**, destination **My Mac**.

MixyHAL is a dependency of mixy and is copied into `mixy.app/Contents/PlugIns/MixyHAL.driver`.

## Project layout

```
mixy/                  SwiftUI app
  MixyApp.swift
  MixerController.swift
  MixerView.swift
  SettingsView.swift
  Core/                policy + mix math (no live I/O)
  HAL/                 enumeration, Bonjour, process tap, installer
  IO/                  AUHAL coordinator + shipped callback
MixyHAL/               C Audio Server Plug-in
mixyTests/             11 XCTest files, 66 cases
```

Folders are Xcode synchronized groups. Adding a Swift file under `mixy/` or `mixyTests/` picks it up automatically.

## Xcode MCP

Apple’s MCP server is `xcrun mcpbridge` (Xcode 26.3+). It talks to a **running** Xcode with a workspace open.

### Why it failed here

`~/.grok/logs/mcp/xcode.stderr.log`:

```
xcrun: error: unable to find utility "mcpbridge", not a developer tool or in PATH
```

`xcode-select` points at Command Line Tools. The binary on this machine is:

```
/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge
```

The 2026-08-14 handshake against the old Xcode-beta path is recorded in [QA.md](QA.md) (`serverInfo.name = xcode-tools`). That probe was not re-run for this doc pass.

### Wiring on this machine

1. `.grok/config.toml` launches `mcpbridge`, but its command is still `/Applications/Xcode-beta.app/Contents/Developer/usr/bin/mcpbridge` with `DEVELOPER_DIR` set to that same missing tree. `~/.grok/config.toml` has no `mcp_servers` entry.
2. `~/.grok/bin/xcode-mcpbridge` is not present.
3. Enable **Xcode → Settings → Intelligence → Allow external agents to use Xcode tools**.
4. Keep Xcode open on `mixy.xcodeproj`. Optional: `MCP_XCODE_PID=<pid of Xcode>`.

A session started before an MCP command change keeps the previous command until it is restarted or `/mcps` is refreshed.

## Launch probes

`MixyApp.init` always prints a HAL inventory JSON to stdout.

| Variable | Effect |
|----------|--------|
| `MIXY_INVENTORY_PATH` | Also write inventory JSON (sandbox may block `/tmp`) |
| `MIXY_PROBE_TAP=1` | Create and tear down a system-wide process tap; log the result |
| `MIXY_APP_TAP_PATH` | Write that tap string to a file |
| `MIXY_START_MIX=1` | `LiveMixStarter` on **built-in outputs** only, emit callback JSON, stop |
| `MIXY_QUIT_AFTER_INVENTORY=1` | Quit after the first main-queue turn |

`LiveMixStarter` enables built-in output devices. Continuity and wireless devices stay off this unattended path; those inputs can stall `AudioUnitInitialize`.

## Tests and the shipped path

UI, tests, and live I/O share:

- `StripMix` — fader / mute / solo / pan → `MixSource`
- `ChannelMixer` — sum onto the mix bus
- `MixIOCycle.run` — capture → mix → local vs AirPlay feed
- `AudioIOCoordinator.handleHardwareIO` — the AUHAL callback body

Several tests read `MixerView.swift` as source so the console bindings cannot drift from the desk model.

## Conventions

- Classify devices from transport type + channel counts (`DeviceClassifier`). Never infer kind from UI.
- Application UIDs (`app:…`) are inputs only. They must not enter `MixGraph` output sets.
- Private tap aggregates are not in `kAudioHardwarePropertyDevices`. Pass `AudioObjectID` into `makeHALUnit`.
- AirPlay writes `AirPlaySafeBuffer` only; the AirPlay callback is the sole consumer.
- Do not introduce AudioDriverKit. Loopback is an Audio Server Plug-in.

## Permissions in development

TCC prompts: microphone, audio capture, local network. Process taps need the audio-capture usage string already in `Info.plist`. Installing MixyHAL into `/Library/Audio/Plug-Ins/HAL` needs privileges the sandbox does not grant — expect `HALInstallerError.copyFailed` from the in-app menu unless you copy the driver yourself.
