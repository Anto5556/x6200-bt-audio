#!/usr/bin/env python3
"""Mock btaudiod API so the QML front-end can be rendered off-device.

Serves the same /state and /cmd endpoints with plausible fake data, which makes
it possible to review the layout in a desktop QML runtime or on a build host
without a radio attached.

    python3 dev/mock-backend.py [port] [scenario]

Scenarios pick what the front panel is pretending to be doing, which is how the
remap overlay's states get reviewed without a radio:

    idle      nothing mapped, no session running (the default)
    pending   a session is holding a keycode, waiting to be confirmed -- the
              state the "RECEIVED nnn" readout exists for.  Set this and open
              the remap panel to see it.
    scanning  adapter discovering, so the SCAN button shows its busy state

The panel commands are handled for real enough for the overlay to step through:
`keymap arm` arms a role, `keymap cancel` drops it, `rotary learn` starts a
learn run and `rotary apply` commits the knob.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8637
SCENARIO = sys.argv[2] if len(sys.argv) > 2 else "idle"

#: The sequence the on-screen remap walks, as the real daemon publishes it.
REMAP_STEPS = ["launch", "rotary", "select"]

def device(addr, name, connected, audio=True, **rest):
    """One /state device entry, in the shape the real daemon emits.

    The front-end reads `ready` and `sink` as well as `name`/`connected`, so a
    mock that leaves them out renders a screen the radio would never show --
    and Qt complains about assigning undefined to `visible: bool`.
    """
    entry = {
        "addr": addr,
        "name": name,
        "alias": name,
        "paired": True,
        "trusted": True,
        "connected": connected,
        "rssi": rest.pop("rssi", -70),
        "icon": rest.pop("icon", "audio-card"),
        "audio": audio,
        # Only a connected audio device has a PulseAudio sink behind it, and
        # that is exactly what "ready" means.
        "ready": bool(connected and audio),
        "sink": ("bluez_sink.%s.a2dp_sink" % addr.replace(":", "_")
                 if connected and audio else None),
        "uuids": rest.pop("uuids", ["0000110b"]),
        "path": "/org/bluez/hci0/dev_%s" % addr.replace(":", "_"),
    }
    entry.update(rest)
    return entry


DEVICES = [
    device("0C:AE:BD:11:22:33", "Sony WH-1000XM4", True, rssi=-54,
           icon="audio-headset", uuids=["0000110b", "00001108"]),
    device("AC:80:0A:44:55:66", "Anker Soundcore 3", False, rssi=-71),
    device("58:68:7A:4E:C1:C9", "[TV] Samsung Q60 Series (65)", False, rssi=-66),
    device("24:A4:52:1F:4F:11", "Anthony's S25 FE", False, rssi=-78,
           icon="phone", uuids=["0000110b", "0000110a", "0000111e"]),
    device("C5:DD:3B:FB:5F:83", "Microsoft Bluetooth Mouse", False,
           audio=False, rssi=None, icon="input-mouse", uuids=["00001812"]),
]

KEYS = {"launch": 724, "up": None, "down": None, "select": 730, "back": 714,
        "scroll_device": "/dev/input/event4", "scroll_invert": 1, "scroll_step": 1}


def blank_session():
    return {"active": False, "step": 0, "codes": {}, "roles": list(REMAP_STEPS),
            "step_role": None, "expires": None, "message": "", "bound": dict(KEYS)}


STATE = {
    "ok": True,
    "adapter": {
        "present": True,
        "address": "84:FC:14:47:90:A5",
        "name": "X6200 Bluetooth",
        "powered": True,
        "discovering": SCENARIO == "scanning",
        "pairable": True,
    },
    "source": "alsa_input.mixcapture",
    "route": {
        "enabled": True,
        "addr": "0C:AE:BD:11:22:33",
        "sink": "bluez_sink.0C_AE_BD_11_22_33.a2dp_sink",
        "module": 31,
        "volume": 70,
        "active": True,
        "local_muted": False,
    },
    "devices": DEVICES,
    "keys": KEYS,
    "rotation": "auto",
    "keymap": blank_session(),
    "rotary": {"learning": False, "learned": None, "axis": None,
               "message": "Scrolling with /dev/input/event4",
               "device": "/dev/input/event4", "invert": True, "step": 1,
               "candidates": ["rotary@0", "rotary@1", "rotary@2", "rotary@3"]},
    "remap": {"steps": REMAP_STEPS},
    "nav": {"seq": 0, "action": None},
    "screen_up": True,
    "error": None,
    "log": ["2026-10-12 07:10:00 --- btaudiod starting (source=alsa_input.mixcapture) ---"],
}

if SCENARIO == "pending":
    # A keycode has arrived and is waiting to be confirmed: this is the state
    # the readout is for, so a render of it is worth being able to make.
    STATE["keymap"] = {
        "active": True, "step": 0, "codes": {}, "roles": ["launch", "select"],
        "step_role": "launch", "expires": None,
        "message": "Received 717 for LAUNCH -- press the same button again to save",
        "pending_role": "launch", "pending_code": 717, "bound": dict(KEYS),
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, payload):
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._send(STATE)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(length) or b"{}")
        action = req.get("action")
        session = STATE["keymap"]

        if action == "volume":
            STATE["route"]["volume"] = req.get("percent", 70)
        elif action == "route":
            STATE["route"]["enabled"] = bool(req.get("on"))
            STATE["route"]["active"] = bool(req.get("on"))
        elif action == "local":
            STATE["route"]["local_muted"] = bool(req.get("muted"))
        elif action == "scan":
            STATE["adapter"]["discovering"] = bool(req.get("on"))
        elif action == "keymap":
            cmd = req.get("cmd")
            if cmd in ("start", "restart"):
                session.update(blank_session())
                session.update({"active": True, "roles": req.get("roles") or REMAP_STEPS})
                session["step_role"] = session["roles"][0]
                session["message"] = "Press the button you want for %s" % session["step_role"].upper()
            elif cmd == "arm":
                role = req.get("role")
                session.update(blank_session())
                session.update({"active": True, "roles": [role], "step_role": role})
                session["message"] = "Press the button you want for %s" % str(role).upper()
            elif cmd == "skip":
                session["step_role"] = None
                session["active"] = False
                session["message"] = "Skipped"
            elif cmd in ("stop", "cancel"):
                session.update(blank_session())
                session["message"] = "Mapping cancelled"
        elif action == "rotary":
            cmd = req.get("cmd")
            if cmd == "learn":
                STATE["rotary"]["learning"] = True
                STATE["rotary"]["learned"] = None
                STATE["rotary"]["message"] = "Turn the knob you want to scroll with"
            elif cmd == "apply":
                STATE["rotary"]["learning"] = False
                STATE["rotary"]["learned"] = STATE["rotary"]["device"]
                STATE["rotary"]["message"] = "Scrolling with " + STATE["rotary"]["device"]
            elif cmd == "set" and req.get("device"):
                STATE["rotary"]["device"] = req["device"]
            elif cmd == "invert":
                STATE["rotary"]["invert"] = bool(req.get("invert"))
                KEYS["scroll_invert"] = 1 if req.get("invert") else 0

        self._send({"ok": True, "action": action})


if __name__ == "__main__":
    print("mock btaudiod on 127.0.0.1:%d (scenario %s)" % (PORT, SCENARIO))
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
