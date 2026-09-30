# Agent notes for Mixy

Mixy is a native macOS mixer (`mixy.xcodeproj`). Open the project in Xcode before using Apple MCP tools.

## Xcode MCP

`xcrun mcpbridge` fails when `xcode-select` is Command Line Tools. Use the Xcode 27 binary:

```
/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge
```

with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Xcode must be running with this project open. Enable **Xcode → Settings → Intelligence → Allow external agents to use Xcode tools**.

Command-line builds:

```
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild test -project mixy.xcodeproj -scheme mixy -destination 'platform=macOS,arch=arm64'
```

or `make test`.

## Architecture rules

- Classification comes from HAL transport + channel counts, never from UI state.
- AirPlay destinations never join a local Core Audio aggregate or shared sample clock.
- UI, unit tests, and live AUHAL all share `StripMix` → `ChannelMixer` → `MixIOCycle` / `handleHardwareIO`.
- Application audio uses `CATapDescription` + a private aggregate; do not look those devices up by UID in `kAudioHardwarePropertyDevices`.
- MixyHAL is an Audio Server Plug-in, not AudioDriverKit.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
