#!/usr/bin/env python3
"""Drive the real front-panel key path with no keypad attached.

`dev/keywatch-test.py` checks the pure decision functions.  This goes further and
exercises the whole chain end to end on the radio: bytes on a keypad device ->
KeyWatch -> capture -> /etc/btaudio.conf -> the button that raises the screen.

It does that by standing up a *second*, fully isolated btaudiod:

  * BTAUDIO_KEYPAD points at a FIFO, so key presses are bytes we choose;
  * BTAUDIO_CONF, BTAUDIO_STATE, BTAUDIO_LOG and BTAUDIO_PID all point at
    throwaway files, so the real settings are never touched;
  * BTAUDIO_PORT moves it off 8637, so the live daemon keeps serving the panel;
  * BTAUDIO_APP_DIR points nowhere, so no screen counts as up;
  * BTAUDIO_LAUNCHER points at a stub that just records being called, so this
    can assert "the button raised the screen" without actually raising one.

The audio bridge is never engaged: with no state file, route_enabled is false.

    python3 dev/keypad-e2e.py [/usr/app_qt/btaudio/btaudiod]

Not installed by install.sh -- scp it to the radio and run it there.
"""
import json
import os
import signal
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request

DAEMON = sys.argv[1] if len(sys.argv) > 1 else "/usr/app_qt/btaudio/btaudiod"
PORT = int(os.environ.get("E2E_PORT", "8638"))
BASE = "http://127.0.0.1:%d" % PORT

FIFO = "/tmp/btaudio-e2e-keypad"
KNOB = "/tmp/btaudio-e2e-knob"
CONF = "/tmp/btaudio-e2e.conf"
STATE = "/tmp/btaudio-e2e.state"
LOG = "/tmp/btaudio-e2e.log"
PID = "/tmp/btaudio-e2e.pid"
LAUNCHER = "/tmp/btaudio-e2e-launcher.sh"
HITS = "/tmp/btaudio-e2e-hits"

EVI = struct.Struct("<IIHHi")          # struct input_event on 32-bit ARM
EV_KEY = 1
EV_REL = 2
REL_AXIS = 3                           # the axis rotary@3 reports on
KEY_LAUNCH = 724                        # the button as delivered
KEY_WANTED = 717                        # what the remap moves it to
KEY_OTHER = 712                         # a button pressed by mistake
KEY_SELECT = 730

failures = []


def check(name, got, want):
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s  (got %r, want %r)" % (name, got, want))
        failures.append(name)


def state():
    with urllib.request.urlopen(BASE + "/state", timeout=5) as fh:
        return json.load(fh)


def post(body):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(BASE + "/cmd", data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=5) as fh:
        return json.load(fh)


def wait_for(predicate, what, seconds=6.0):
    """Poll until PREDICATE holds, so the test never sleeps a fixed guess."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            if predicate():
                return True
        except (urllib.error.URLError, OSError, ValueError):
            pass
        time.sleep(0.2)
    print("  !! timed out waiting for %s" % what)
    return False


def conf():
    values = {}
    with open(CONF) as fh:
        for raw in fh:
            line = raw.split("#", 1)[0].strip()
            if "=" in line:
                name, value = line.split("=", 1)
                values[name.strip()] = value.strip()
    return values


def hits():
    try:
        with open(HITS) as fh:
            return len(fh.read().split())
    except OSError:
        return 0


class EventPipe(object):
    """The write end of a FIFO the daemon reads as an input device.

    Opened read-write so neither side blocks on the open: the daemon's own
    open(...O_RDONLY) then succeeds immediately instead of waiting for a writer.
    The keypad and the scroll knob get separate pipes -- if they shared one, the
    two reader threads would steal each other's bytes.
    """

    def __init__(self, path):
        self.path = path
        self.fh = os.open(path, os.O_RDWR)

    def _send(self, type_, code, value):
        os.write(self.fh, EVI.pack(0, 0, type_, code, value))

    def press(self, code):
        self._send(EV_KEY, code, 1)

    def release(self, code):
        self._send(EV_KEY, code, 0)

    def tap(self, code):
        self.press(code)
        self.release(code)

    def turn(self, detents, axis=REL_AXIS, value=1):
        """One REL event, the way an encoder reports a single detent."""
        for _ in range(detents):
            self._send(EV_REL, axis, value)

    def close(self):
        try:
            os.close(self.fh)
        except OSError:
            pass


def main():
    for path in (FIFO, KNOB, HITS, PID, STATE):
        try:
            os.unlink(path)
        except OSError:
            pass
    os.mkfifo(FIFO)
    os.mkfifo(KNOB)

    # A keypad device the daemon can read, plus a launcher stub that records
    # being called instead of putting a screen on the panel.
    with open(LAUNCHER, "w") as fh:
        fh.write("#!/bin/sh\necho \"$@\" >> %s\n" % HITS)
    os.chmod(LAUNCHER, 0o755)

    with open(CONF, "w") as fh:
        fh.write("# end-to-end test config\n"
                 "launch=%d\nlaunch_presses=2\nexit_presses=3\n"
                 "select=%d\nback=714\nscroll_device=\nscroll_invert=0\n"
                 % (KEY_LAUNCH, KEY_SELECT))

    keypad = EventPipe(FIFO)
    knob = EventPipe(KNOB)
    env = dict(os.environ)
    env.update({
        "BTAUDIO_KEYPAD": FIFO,
        "BTAUDIO_CONF": CONF,
        "BTAUDIO_STATE": STATE,
        "BTAUDIO_LOG": LOG,
        "BTAUDIO_PID": PID,
        "BTAUDIO_PORT": str(PORT),
        "BTAUDIO_APP_DIR": "/nonexistent-app-dir",
        "BTAUDIO_LAUNCHER": LAUNCHER,
    })

    daemon = subprocess.Popen([sys.executable, DAEMON], env=env,
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL)
    try:
        if not wait_for(lambda: state().get("ok"), "the test daemon's API"):
            print("  !! daemon log:\n" + log_tail())
            return 1

        print("start: the panel as delivered")
        check("the launch button is the delivered one", state()["keys"]["launch"],
              KEY_LAUNCH)
        check("the remap plan is published", state()["remap"]["steps"],
              ["launch", "rotary", "select"])

        print()
        print("remap step 1: moving the button that raises the screen")
        post({"action": "keymap", "cmd": "arm", "role": "launch", "seconds": 60})
        check("the session is armed for launch", state()["keymap"]["step_role"],
              "launch")

        keypad.tap(KEY_WANTED)
        if not wait_for(lambda: state()["keymap"].get("pending_code") == KEY_WANTED,
                        "the candidate keycode to be reported"):
            return 1
        check("the first press is only reported, not saved", conf()["launch"],
              str(KEY_LAUNCH))
        check("and the screen is handed the keycode that arrived",
              state()["keymap"]["pending_code"], KEY_WANTED)

        keypad.tap(KEY_WANTED)                    # the confirming press
        if not wait_for(lambda: conf().get("launch") == str(KEY_WANTED),
                        "the new button to reach the config"):
            return 1
        check("the press is written to the config", conf()["launch"],
              str(KEY_WANTED))
        check("and is live without a restart", state()["keys"]["launch"],
              KEY_WANTED)
        check("the session closed itself", state()["keymap"]["active"], False)
        check("the screen button is reported bound",
              state()["keymap"]["bound"].get("launch"), KEY_WANTED)

        print()
        print("the moved button really drives the screen")
        keypad.tap(KEY_WANTED)
        time.sleep(0.35)
        keypad.tap(KEY_WANTED)
        if not wait_for(lambda: hits() == 1, "the launcher to be called once"):
            print("  !! hits=%d" % hits())
        check("two presses of the new button raise the screen", hits(), 1)

        # The old button is unbound now and must not navigate either.
        time.sleep(2.2)                    # let the press window lapse
        keypad.tap(KEY_LAUNCH)
        time.sleep(0.35)
        keypad.tap(KEY_LAUNCH)
        time.sleep(0.6)
        check("the old button is inert", hits(), 1)

        print()
        print("a normal button walk still refuses the screen button")
        time.sleep(2.2)
        post({"action": "keymap", "cmd": "start"})
        check("the walk starts at the first role",
              state()["keymap"]["step_role"], "up")
        keypad.tap(KEY_WANTED)
        time.sleep(0.6)
        check("the screen button is not captured by the walk",
              state()["keymap"]["step"], 0)
        check("and nothing was recorded", state()["keymap"]["codes"], {})
        post({"action": "keymap", "cmd": "cancel"})

        print()
        print("one keycode never means two things")
        time.sleep(2.2)
        post({"action": "keymap", "cmd": "arm", "role": "launch", "seconds": 60})
        keypad.tap(KEY_SELECT)
        keypad.tap(KEY_SELECT)                    # confirm
        if not wait_for(lambda: conf().get("launch") == str(KEY_SELECT),
                        "the select key to become the screen button"):
            return 1
        check("the screen button takes the key", conf()["launch"],
              str(KEY_SELECT))
        check("select is released so it cannot mean two things",
              conf().get("select"), "")
        check("and the daemon agrees",
              state()["keymap"]["bound"].get("select"), None)

        print()
        print("remap step 2: turning the knob into scrolling")
        # Point the daemon's knob at the second pipe, then turn it for real.
        post({"action": "rotary", "cmd": "set", "device": KNOB})
        if not wait_for(lambda: ("rotary: watching " + KNOB) in log_text(),
                        "the daemon to open the test knob"):
            return 1
        check("the knob is the one configured", state()["rotary"]["device"], KNOB)

        before = state()["nav"]["seq"]
        knob.turn(1)
        if not wait_for(lambda: state()["nav"]["seq"] > before, "a knob step"):
            return 1
        check("turning the knob one way scrolls down",
              state()["nav"]["action"], "down")

        before = state()["nav"]["seq"]
        knob.turn(1, value=-1)
        if not wait_for(lambda: state()["nav"]["seq"] > before,
                        "a knob step the other way"):
            return 1
        check("and the other way scrolls up", state()["nav"]["action"], "up")

        # FLIP is what the remap screen offers while the knob is being chosen.
        post({"action": "rotary", "cmd": "invert", "invert": 1})
        before = state()["nav"]["seq"]
        knob.turn(1)
        if not wait_for(lambda: state()["nav"]["seq"] > before,
                        "a knob step after FLIP"):
            return 1
        check("FLIP reverses which way is down", state()["nav"]["action"], "up")
        check("and the new direction is saved", conf().get("scroll_invert"), "1")

        print()
        print("a mis-press costs nothing")
        # The whole point of showing the code before saving it.
        was = conf()["launch"]
        post({"action": "keymap", "cmd": "arm", "role": "launch", "seconds": 60})
        keypad.tap(KEY_OTHER)
        if not wait_for(lambda: state()["keymap"].get("pending_code") == KEY_OTHER,
                        "the mistaken press to be reported"):
            return 1
        check("the wrong button changes nothing on disk", conf()["launch"], was)

        keypad.tap(KEY_WANTED)                    # change your mind
        if not wait_for(lambda: state()["keymap"].get("pending_code") == KEY_WANTED,
                        "the candidate to follow the newest press"):
            return 1
        check("and still nothing is written", conf()["launch"], was)

        keypad.tap(KEY_WANTED)                    # confirm the right one
        if not wait_for(lambda: conf()["launch"] == str(KEY_WANTED),
                        "the corrected button to be saved"):
            return 1
        check("the corrected button is what lands", conf()["launch"],
              str(KEY_WANTED))
    finally:
        keypad.close()
        knob.close()
        daemon.send_signal(signal.SIGTERM)
        try:
            daemon.wait(timeout=5)
        except subprocess.TimeoutExpired:
            daemon.kill()
        # Read the log before deleting it, then leave nothing behind: this runs
        # on the radio, where stray files in /tmp would outlive the test.
        tail = log_tail()
        for path in (FIFO, KNOB, HITS, PID, STATE, CONF, LOG, LAUNCHER):
            try:
                os.unlink(path)
            except OSError:
                pass
        print()
        print("--- test daemon log")
        print(tail)

    print()
    if failures:
        print("%d FAILED: %s" % (len(failures), ", ".join(failures)))
        return 1
    print("all checks passed")
    return 0


def log_text():
    try:
        with open(LOG) as fh:
            return fh.read()
    except OSError:
        return ""


def log_tail(lines=12):
    try:
        with open(LOG) as fh:
            return "".join(fh.readlines()[-lines:]).rstrip()
    except OSError:
        return "(no log)"


if __name__ == "__main__":
    sys.exit(main())
