# Mixy QA

Full pass on 2026-08-14 against the tree in this commit. Host: `ss-macbook-air.local`, Xcode 27.0 (27A5194q), destination **My Mac** (arm64).

`DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

## Automated tests

```
xcodebuild test -project mixy.xcodeproj -scheme mixy -destination 'platform=macOS,arch=arm64'
** TEST SUCCEEDED **
Executed 66 tests, with 0 failures.
```

| Suite | Tests | Result |
|-------|------:|--------|
| AirPlayPolicyTests | 5 | pass |
| ChannelMixerTests | 3 | pass |
| DeviceClassificationTests | 6 | pass |
| IOCycleTests | 7 | pass |
| InputCatalogTests | 7 | pass |
| LoopbackTests | 3 | pass |
| MixerChromeTests | 6 | pass |
| MixerControlTests | 6 | pass |
| MixerDeskTests | 7 | pass |
| OutputCatalogTests | 8 | pass |
| StripMixTests | 8 | pass |
| **Total** | **66** | **pass** |

Coverage of product features:

| Feature | How it was verified |
|---------|---------------------|
| Fader, mute, solo, pan, on/off | `MixerControlTests`, `StripMixTests` — values change the shipped `handleHardwareIO` mix |
| Output mute/fader without a new input | `testOutputMuteAppliesOnNextOutputCallbackWithoutNewInput` |
| Add / remove / clear desk | `MixerDeskTests`, `MixerControlTests` |
| View filter hides banks, does not disarm | `testViewFilterHidesBanksWithoutRemovingStrips`, `testViewFilterAndSearchDoNotDisableArmedControls` |
| I/O reassign keeps controls | `testReassignTransfersFaderMuteSoloPan` |
| Clear does not reseed | `testClearMixerDoesNotReseedBuiltInDesk` |
| Channel mix + remap | `ChannelMixerTests` |
| AirPlay not on local clock | `AirPlayPolicyTests`, `OutputCatalogTests` |
| AirPlay silence until cushion | `testAirPlayCallbackDoesNotEmitUntilSafeBufferIsPrimed` |
| AUHAL callback install | `testStartMixRegistersShippedAUHALCallbacksOnLiveDevices` |
| Stop Mix lifetime | `testStopKeepsHALContextsUntilAfterUnitDispose` |
| Duplex 18/20 widths | `testDuplexInterfaceUsesInputWidthForInputRoleAndOutputWidthForOutputs` |
| Hardware + app catalog | `InputCatalogTests` |
| Process tap adapter | `testProcessTapAdapterSourceIsFirstParty` |
| Bonjour Info.plist | `testShippedAppInfoPlistDeclaresAirPlayBonjourServices` |
| Video selection record | `testVideoSelectionUpdatesShippedRecord` |
| Chrome / empty desk copy | `MixerChromeTests` |
| Loopback ring | `LoopbackTests` |
| Live HAL classification | `testLiveHALEnumerationPopulatesClassificationFields` |
| MixerView source bindings | several tests read `MixerView.swift` |

## Builds

| Target | Result |
|--------|--------|
| mixy (Debug, via test) | **BUILD SUCCEEDED** — `mixy.app` at DerivedData `Build/Products/Debug` |
| MixyHAL | **BUILD SUCCEEDED** — Mach-O arm64 bundle |
| Embed | `mixy.app/Contents/PlugIns/MixyHAL.driver` present |

Signed entitlements on the test app: sandbox, audio-input, microphone, network client, user-selected files, audio-unit-host, plus XCTest `get-task-allow` / testmanagerd exceptions.

## Live HAL inventory

`MIXY_QUIT_AFTER_INVENTORY=1` against the Debug app. Exit 0.

| Kind | Name | In / out | Transport |
|------|------|----------|-----------|
| local | MacBook Air Microphone | 1 / 0 | Built-in |
| local | MacBook Air Speakers | 0 / 2 | Built-in |
| local | Continuity iPhone Microphone | 1 / 0 | Continuity Capture (Wired) |

Inputs also included **All Application Audio** (`app:system-wide`) and every Core Audio process object (Safari, Steam, Messages, Control Center, assistantd, …). One HAL output: built-in speakers. No AirPlay HAL device and no Mixy Loopback published on this host (`/Library/Audio/Plug-Ins/HAL` has only third-party drivers). `videoRoutes` empty — no HDMI / AirPlay video dest at probe time.

`MIXY_INVENTORY_PATH=/tmp/...` did not write: sandbox blocks that path. Inventory still printed on stdout.

## Start Mix (live)

`MIXY_START_MIX=1` registered the shipped render callback:

```json
{
  "uid": "BuiltInSpeakerDevice",
  "role": "localOutput",
  "propertyName": "SetRenderCallback",
  "procIsShippedAUHALCallback": true,
  "setPropertySucceeded": true
}
```

Matches `LiveMixStarter` (built-in outputs only). Exit 0.

## Process tap (live)

`MIXY_PROBE_TAP=1`:

```
created tap 4065858A-1B05-4CB6-A61B-F8472D3F13B1 aggregate mixy.tap.app:system-wide
```

System-wide tap create + teardown succeeded under the sandbox.

## GUI

`open mixy.app` started process **mixy** alongside Xcode. Window screenshot was blocked on this agent host (`screencapture`: *could not create image from display*; AppleScript System Events: *osascript is not allowed assistive access*). Console layout, menus, and bindings are locked by the MixerView source tests above. Interactive click-through of every menu was not possible in this environment.

## Xcode MCP

**Before:** Grok spawned `xcrun mcpbridge`. `xcode-select` = Command Line Tools → handshake closed immediately (`unable to find utility "mcpbridge"`).

**After:** config points at

`/Applications/Xcode-beta.app/Contents/Developer/usr/bin/mcpbridge`

with `DEVELOPER_DIR` set. Direct initialize:

```json
{"serverInfo":{"name":"xcode-tools","version":"25227.8"},"protocolVersion":"2024-11-05"}
```

This Grok session started before the config change, so its in-process MCP catalog still lacks Xcode tools. New sessions (or `/mcps` refresh) pick up the fix. Xcode 27 was running; `IDEAllowUnauthenticatedAgents = 1`.

`sudo xcode-select --switch` was not applied (needs an admin password).

## Not exercised on hardware (by design or environment)

| Item | Why | Residual risk |
|------|-----|----------------|
| AirPlay speaker as a live output | None published on the LAN during inventory; quit-after-inventory is too short for Bonjour | Isolation path is unit-tested; live AirPlay unit open is untested here |
| Video toggle to a TV | No video-capable dest in catalog | Selection record is unit-tested |
| MixyHAL install + coreaudiod publish | Needs admin; sandbox copy fails; driver not in `/Library` | Plugin builds and embeds; in-process loopback is tested |
| Continuity input as Start Mix source | `LiveMixStarter` skips non-built-in on purpose | Manual Start Mix can still add that strip |
| Full GUI click-through | No screen capture / Accessibility for the agent | View-source tests + successful launch |

## Verdict

The shipped mix path, desk model, AirPlay policy, catalogs, AUHAL callback registration, process-tap adapter, and MixyHAL build are green. Remaining gaps are environmental (no AirPlay hardware, no admin for HAL install, no GUI automation). No product defects were found that required a code change.
