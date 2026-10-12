#!/usr/bin/env python3
"""Mock btaudiod API so the QML front-end can be rendered off-device.

Serves the same /state and /cmd endpoints with plausible fake data, which makes
it possible to review the layout in a desktop QML runtime or on a build host
without a radio attached.

    python3 dev/mock-backend.py [port]
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8637

STATE = {
    "ok": True,
    "adapter": {
        "present": True,
        "address": "84:FC:14:47:90:A5",
        "name": "X6200 Bluetooth",
        "powered": True,
        "discovering": False,
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
    },
    "devices": [
        {"addr": "0C:AE:BD:11:22:33", "name": "Sony WH-1000XM4", "paired": True,
         "trusted": True, "connected": True, "rssi": -54, "icon": "audio-headset",
         "audio": True, "uuids": ["0000110b", "00001108"]},
        {"addr": "AC:80:0A:44:55:66", "name": "Anker Soundcore 3", "paired": True,
         "trusted": True, "connected": False, "rssi": -71, "icon": "audio-card",
         "audio": True, "uuids": ["0000110b"]},
        {"addr": "58:68:7A:4E:C1:C9", "name": "[TV] Samsung Q60 Series (65)",
         "paired": False, "trusted": False, "connected": False, "rssi": -66,
         "icon": "audio-card", "audio": True, "uuids": ["0000110b"]},
        {"addr": "24:A4:52:1F:4F:11", "name": "Anthony's S25 FE", "paired": True,
         "trusted": True, "connected": False, "rssi": -78, "icon": "phone",
         "audio": True, "uuids": ["0000110b", "0000110a", "0000111e"]},
        {"addr": "C5:DD:3B:FB:5F:83", "name": "Microsoft Bluetooth Mouse",
         "paired": True, "trusted": True, "connected": False, "rssi": None,
         "icon": "input-mouse", "audio": False, "uuids": ["00001812"]},
    ],
    "error": None,
    "log": ["2026-10-12 07:10:00 --- btaudiod starting (source=alsa_input.mixcapture) ---"],
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
        if action == "volume":
            STATE["route"]["volume"] = req.get("percent", 70)
        elif action == "route":
            STATE["route"]["enabled"] = bool(req.get("on"))
            STATE["route"]["active"] = bool(req.get("on"))
        elif action == "scan":
            STATE["adapter"]["discovering"] = bool(req.get("on"))
        self._send({"ok": True, "action": action})


if __name__ == "__main__":
    print("mock btaudiod on 127.0.0.1:%d" % PORT)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
