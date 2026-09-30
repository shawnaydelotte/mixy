# Mixy user guide

Mixy is a mixer console, not a catalog dump. Add only the channels you want on the desk, then mix them.

## Window

The main window is a split view:

- **Track Manager** (sidebar) — search, “Playing apps only”, channels already on the mixer, then catalogs to add.
- **Console** — grouped channel-strip banks (Hardware Inputs, Application Audio, Outputs, AirPlay).
- **Status bar** — strip count, local-clock destinations, isolated AirPlay, present AirPlay, video routes, last status message.

First launch seeds the built-in microphone and built-in speakers when they exist. **Clear Mixer** does not reseed.

## Adding and removing channels

| Action | Where |
|--------|--------|
| Add hardware / app / output / AirPlay | Toolbar **Add Channel**, **Mixer** menu, or a catalog row in Track Manager |
| Remove one strip | Track Manager **Remove**, or strip context menu |
| Clear the desk | **Add Channel → Clear Mixer** or **Mixer → Clear Mixer** |
| Hide a bank without removing it | **VIEW** filter on the console, or **Mixer → View** |

Search in Track Manager filters catalogs. **Playing apps only** hides application rows that are not currently producing output (`kAudioProcessPropertyIsRunningOutput`).

## Channel strip

Each strip is 108 pt wide:

1. Group accent bar and I/O assignment menu (reassign an input among inputs, or an output among outputs; fader, mute, solo, pan, and on/off are kept).
2. Role badge (`IN` / `OUT`) and kind badge (`LOCAL`, `MUSIC`, `AP`, `VIRT`).
3. Pan readout (`L100` … `C` … `R100`) and slider (−1…1). Applied to the first two destination channels.
4. **S** solo and **M** mute pads.
5. Vertical fader, −96 dB to +12 dB.
6. Gain readout and **ON** / **OFF**.

Solo is per direction: soloing an input only silences other inputs; soloing an output only silences other outputs.

AirPlay strips get an extra AirPlay label and a warmer border. Application strips show `APP` or `ALL APPS`.

## Starting the mix

**Start Mix** (toolbar play button, or **Mix → Start Mix**, or **⌘↩**) opens AUHAL units on every enabled strip:

- Hardware inputs and local outputs use the live HAL device.
- Application inputs create a private Core Audio process tap and a private aggregate (`mixy.tap.{uid}`).
- AirPlay outputs use a larger buffer and read only from the isolated AirPlay ring.

**Stop Mix** (same control) tears those units and taps down.

Status text reports how many shipped AUHAL callbacks registered, or why start failed.

**Refresh Devices** (**⌘R**) re-enumerates HAL devices, session AirPlay, and app processes.

## AirPlay and video

AirPlay destinations come from two places:

1. HAL devices with transport type AirPlay.
2. Bonjour on the current Mac session: `_airplay._tcp` (audio + video capable) and `_raop._tcp` (audio only). RAOP names like `AABBCCDDEEFF@Living Room` display as `Living Room`.

They never share a sample clock or aggregate with local hardware. The Mixing settings pane shows the buffers:

| Path | Buffer | Extra latency |
|------|--------|----------------|
| Local | 512 frames | — |
| AirPlay | 4096 frames | 4096 frames |

Destinations that support video (AirPlay, HDMI, DisplayPort) show a **Video** toggle in Track Manager. That toggle records a route selection; Mixy does not encode or present video.

## Mixy Loopback

**Devices → Install Mixy Loopback Device…** copies the bundled Audio Server Plug-in to `/Library/Audio/Plug-Ins/HAL/MixyHAL.driver`.

The sandbox usually blocks that copy unless you run a privileged installer. After a successful copy, restart `coreaudiod` or log out. The device appears as **Mixy Loopback** (8 in / 8 out, virtual) and can sit on the desk like any local device.

Settings → **Loopback** shows the install path and whether the driver is present.

## Permissions

macOS will ask for:

- **Microphone / audio input** — hardware capture.
- **Audio capture** — application process taps.
- **Local network** — AirPlay / RAOP discovery.

Grant these in System Settings → Privacy & Security if catalogs look empty.

## Keyboard shortcuts

| Shortcut | Action |
|----------|--------|
| **⌘↩** | Start / stop mix |
| **⌘R** | Refresh devices |
| **⌘,** | Settings |

## Settings

- **Mixing** — read-only buffer constants and the AirPlay isolation rule.
- **Loopback** — driver name, mechanism (Audio Server Plug-in, not AudioDriverKit), install path, installed yes/no.
