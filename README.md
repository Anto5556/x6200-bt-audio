# BT Audio — a Bluetooth audio-out app for the Xiegu X6200

The X6200 runs an embedded Linux with a Qt GUI. Its built-in **BLUETOOTH** screen
pairs devices, but only for CAT/serial work — there is no way to send the radio's
audio to a Bluetooth headset or speaker, and pairing headphones through it has
been reported to crash the radio.

**BT Audio** adds that missing piece: a purpose-built screen that pairs an A2DP
device, connects it, and routes the radio's audio to it — without disturbing the
radio's own audio path.

```
                    ┌──────────────────────── the radio ────────────────────────┐
  FPGA/DSP ──┐      │                                                           │
   (RX audio)│      │   alsa_input.mixcapture ──┐                               │
             └──────┼──► codec (ADC)            │                               │
                    │                          │  module-loopback              │
                    │   codec (DAC) ──► speaker│        │                      │
                    │         ▲                │        ▼                      │
                    │         └── stock UI ────┘   bluez_sink.<MAC>.a2dp_sink   │
                    │        (untouched)              │                        │
                    └─────────────────────────────────┼────────────────────────┘
                                                      ▼
                                              Bluetooth headset
```

## Why it works this way

Three facts about the X6200 drove the design:

1. **The radio's audio bypasses PulseAudio.** The stock UI (Qt) plays to ALSA
   directly, so nothing appears in PulseAudio while the radio talks — a naive
   "set the default sink" approach would do nothing.
2. **The audio *is* available on a shared ALSA capture device.** The demodulated
   audio lands on `mixcapture`, which is a `dsnoop` PCM, so several readers can
   share it. Tapping it is non-invasive: the radio keeps playing to its own
   speaker exactly as before.
3. **The display allows only one full-screen client.** The stock GUI owns it
   through Qt EGLFS, so the app swaps places with it (the same way the firmware's
   own `/usr/share/support/userapp` starts and stops the main UI).

So the bridge is a PulseAudio loopback from `alsa_input.mixcapture` into the
Bluetooth sink that PulseAudio creates when an A2DP device connects. Nothing in
the radio's existing audio chain is modified.

## Layout

| Path (on the radio)            | What it is                                            |
|--------------------------------|-------------------------------------------------------|
| `/usr/app_qt/btaudio/btaudiod` | Backend daemon: BlueZ control, audio bridge, JSON API |
| `/usr/app_qt/btaudio/BtAudio.qml` | The 800×480 screen, rendered by the radio's own Qt 5.12 |
| `/usr/share/support/btaudio`   | Launcher: swaps the screen in and out                 |
| `/etc/init.d/S52btaudiod`      | Starts the backend at boot                            |
| `/etc/btaudio.conf`            | Front-panel key bindings and orientation              |

In this repo, `radio/` mirrors those files, `dev/` holds development aids and
captured screenshots, and `deploy.sh` pushes it all to the radio. Two aids are
worth knowing about when changing anything visible: `dev/panelrun.sh` shows the
screen on the radio's real panel for a few seconds and *always* hands the display
back (the build has no `timeout`, `pgrep` or `pkill`, so a screen that hangs
otherwise leaves the stock GUI parked, invisibly), and `btaudio snapshot FILE`
renders the screen offscreen to a PNG without touching the panel.

## Install

```sh
./deploy.sh                    # copy to the radio and install there
./deploy.sh uninstall          # remove it again
RADIO=root@192.168.0.99 ./deploy.sh
```

`deploy.sh` only needs SSH access as root. Nothing outside the paths above is
touched, and `/etc/btaudio.conf` is never overwritten once it exists.

## Using it

```sh
/usr/share/support/btaudio start        # show the screen (also starts the backend)
/usr/share/support/btaudio stop         # stop backend, restore the stock screen
/usr/share/support/btaudio status
/usr/share/support/btaudio daemon restart
/usr/share/support/btaudio snapshot /tmp/screen.png   # render offscreen to a PNG
/usr/share/support/btaudio calibrate    # only if the screen is ever sideways
/usr/share/support/btaudio keymap       # map the front-panel navigation buttons
```

On screen:

* **SCAN** looks for nearby devices for 30 seconds; discovered devices appear
  with signal strength. Devices marked `AUDIO` can receive audio; `AUDIO READY`
  means PulseAudio has published a sink for them (the A2DP link is up).
* **PAIR / CONNECT / DISCONNECT / FORGET** act on the selected device.
  Pairing also connects it and switches routing on, so pairing is a one-step
  "make this headset play the radio".
* **RADIO AUDIO TO BLUETOOTH** is the master switch. `STREAMING` means the
  bridge is live. It stays on across screen closes and reboots.
* **VOL** sets the level sent to the headset. Select it and it **takes the knob**:
  from then on turning the knob moves the volume and the ring stays on it, and
  selecting again lets go. That is how a knob and one button cover a control with
  no left/right key.
* **SPKR ON/OFF** mutes the radio's own speaker while the headset keeps
  playing — useful for headphone listening. It does not touch the capture path.
* **CLOSE**, `Esc`, the mapped back button, or **three quick presses of the
  front-panel launch button** returns to the radio.

Navigation: mouse, the USB keyboard, or the front panel once mapped (below).
The whole screen is one walk: an amber ring moves through the route switch, the
volume, the speaker toggle, SCAN and then every device row, and select acts on
whatever it is on.

## Front-panel buttons

The keypad is a 5×6 matrix whose device-tree keymap assigns vendor keycodes
704–733 (0x2C0–0x2DD). Qt can drop codes that high, so the backend reads the
keypad itself and relays presses to the screen — it works regardless of what Qt
does with them.

Nothing has to be typed in or guessed: the radio can map its own buttons.

```sh
/usr/share/support/btaudio keymap      # then just follow the screen
```

That screen has two phases. First it asks for a button per navigation role
(`UP`, `DOWN`, `SELECT`, `BACK`) and records the keycode it sees for each, then it
asks for **the knob to scroll with**: turn it a few clicks and the backend
reports which of the radio's encoders moved. Press the button you want on the
radio and each binding is written into `/etc/btaudio.conf` as it goes, so a run
cut short still keeps what it captured. `SKIP` leaves a role unbound, `RESTART`
starts over, `CLEAR` drops all four, `FLIP` reverses the knob. The launch button
is never captured — it stays the way in and out — and the screen closes itself
when both phases are answered.

Once the knob is bound, that is usually all you need: the knob walks the ring and
one button selects. The screen the config below describes is exactly that — a
knob, one select button, and the launch button.

```ini
launch=717            # opened with 2 quick presses, closed with 3
exit_presses=3
select=704            # one press acts on whatever the amber ring is on
scroll_device=/dev/input/event2
scroll_invert=1       # which way round the knob feels right
```

**Moving a single button** (no need to walk the whole set again): arm the capture
from the radio's own terminal, then press the button once. The screen shows an
amber `MAPPING — press the button you want for SELECT` strip while a capture is
armed, so it can never happen by surprise; an armed capture gives up after its
timeout.

```sh
curl -X POST http://127.0.0.1:8637/cmd \
     -d '{"action":"keymap","cmd":"arm","role":"select","seconds":120}'
```

The launch button's press counts are separate, so a single stray press can never
steal the screen from whatever that button normally does — and the gesture that
closes it is the one you already used to open it. Presses and knob steps reach
the screen through the `/state` poll as a rising `nav.seq`, which is why
navigation works even though Qt drops the keymap's vendor keycodes; the mouse and
a USB keyboard work alongside.

To see what the keypad is sending at any time:

```sh
tail -f /tmp/btaudio.log      # "keywatch:" presses, "keymap:" captures
```

## Configuration

`/etc/btaudio.conf` holds the key bindings and the screen orientation.

**Orientation** is normally `rotation=auto` and needs no attention. The panel's
DRM mode is 480×800 portrait while the glass is 800×480 landscape, and on this
driver EGLFS will not turn the surface for us: measured on the panel,
`QT_QPA_EGLFS_ROTATION=90` (the value the stock GUI runs with) leaves an 800×480
layout a quarter turn out and Qt logs `Framebuffer size format is invalid.` So
the launcher asks for **no** EGLFS rotation and the screen rotates its own
800×480 layout into the panel's raw 480×800 frame instead — `auto` picks the
quarter turn from the shape of the frame Qt hands over, which is 270 here.

If the screen is ever sideways anyway, `/usr/share/support/btaudio calibrate`
opens showing the angle in use; TRY NEXT turns the layout a quarter turn at a
time until `TOP` is at the top of the radio, and USE THIS saves that angle here.
USE AUTO puts the automatic behaviour back. The frame and angle the screen
actually used are logged to `/tmp/btaudio-screen.log` on every start.

**The scroll knob** is `scroll_device`, an evdev path learned by `btaudio keymap`
(the radio exposes its encoders as `rotary@0..3`, one REL axis each, and the one
you turn during the knob phase is the one written here). `scroll_invert` flips
which way is "down" to match the knob's feel, and `scroll_step` is how many raw
units make one step for encoders that report two per detent. The knob is only
read, never grabbed, so the radio's own knobs are untouched whenever the BT Audio
screen is not up — while it is up the stock GUI is parked, so that knob scrolls
this list instead of tuning anything.

```ini
scroll_device=/dev/input/event2
scroll_invert=1
scroll_step=1
```

Environment variables override everything else and are useful for testing:

| Variable                 | Default                 | Purpose                          |
|--------------------------|-------------------------|----------------------------------|
| `BTAUDIO_SOURCE`         | `alsa_input.mixcapture` | What gets sent to the headset    |
| `BTAUDIO_PORT`           | `8637`                  | JSON API port (loopback only)    |
| `BTAUDIO_POLL`           | `1.0`                   | BlueZ refresh interval (seconds) |
| `BTAUDIO_MIXER_CONTROL`  | `Headphone`             | Control used for the speaker mute |
| `BTAUDIO_KEYPAD`         | `/dev/input/event0`     | Front-panel input device         |
| `BTAUDIO_CONF`           | `/etc/btaudio.conf`     | Config file                      |

## The API

The screen is a thin client of a loopback-only JSON API. It is handy on its own:

```sh
curl http://127.0.0.1:8637/state
curl -X POST http://127.0.0.1:8637/cmd -d '{"action":"scan","on":true}'
curl -X POST http://127.0.0.1:8637/cmd -d '{"action":"connect","addr":"AA:BB:CC:DD:EE:FF"}'
```

Actions: `scan`, `pair`, `connect`, `disconnect`, `forget`, `route`, `volume`,
`local`, `power`, `rotation`, `keymap`, `rotary`, `refresh`. Three of them are
front-panel plumbing worth knowing about:

```sh
# the screen tells the front end which button the panel is on
curl -X POST http://127.0.0.1:8637/cmd -d '{"action":"keymap","cmd":"state"}'
# move one binding (the screen shows a MAPPING strip while it is armed)
curl -X POST http://127.0.0.1:8637/cmd -d '{"action":"keymap","cmd":"arm","role":"select","seconds":120}'
# learn the scroll knob / flip its direction / drop it
curl -X POST http://127.0.0.1:8637/cmd -d '{"action":"rotary","cmd":"learn"}'
curl -X POST http://127.0.0.1:8637/cmd -d '{"action":"rotary","cmd":"invert","invert":true}'
```

## Troubleshooting

| Symptom                     | Check                                                                  |
|-----------------------------|------------------------------------------------------------------------|
| Screen will not appear      | `/tmp/btaudio.log`; is another Qt app holding the display?              |
| Device connects, no audio   | `pactl list short sink-inputs` — is the loopback there? Look for `AUDIO READY`. |
| No audio at all             | `parec --device=alsa_input.mixcapture ...` — is the radio producing audio? |
| `btaudiod` will not start   | `python3 -c "import dbus"`; the PyPID file is `/tmp/btaudiod.pid`.      |
| Screen is up but keys do nothing | Configure `/etc/btaudio.conf`, then `btaudio daemon restart`.      |
| Screen is up but sideways   | `/tmp/btaudio-screen.log` says which frame Qt handed over. `btaudio calibrate` fixes it and saves the angle. |
| Knob does not scroll        | `scroll_device` in `/etc/btaudio.conf`; re-run `btaudio keymap` and do the knob phase again, or `{"action":"rotary","cmd":"learn"}`. If it scrolls the wrong way, `scroll_invert`. |
| MAPPING strip will not go   | An armed capture was left open: post `{"action":"keymap","cmd":"cancel"}`, or wait out its timeout. |
| Ring stuck on the volume    | That is the volume lock: select again to release it, or select any other control. |

The captures in `dev/renders/` are real frames from the radio, produced with
`btaudio snapshot`.

## Notes and limits

* A **firmware update re-flashes the root filesystem** and will erase this
  install; re-run `deploy.sh` afterwards.
* The X6200 has **no touchscreen** — plan on the mouse, a keyboard, or the
  front-panel bindings. The screen is designed to be legible and drivable
  without a pointer.
* One Bluetooth audio device is routed at a time (the most recently used one).
* The stock GUI is a closed binary, so the app swaps the whole screen rather
  than adding a tile to the radio's own menus.
