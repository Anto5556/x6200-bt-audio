#!/usr/bin/env python3
"""Check the front-panel shortcut rule (run on the radio, where python3-dbus is).

    python3 dev/keywatch-test.py [/usr/app_qt/btaudio/btaudiod]
"""
import importlib.util
import sys
import threading

PATH = sys.argv[1] if len(sys.argv) > 1 else "/usr/app_qt/btaudio/btaudiod"

spec = importlib.util.spec_from_loader("btaudiod", importlib.machinery.SourceFileLoader("btaudiod", PATH))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

failures = []


def check(name, got, want):
    if got == want:
        print("  PASS  %s" % name)
    else:
        print("  FAIL  %s  (got %r, want %r)" % (name, got, want))
        failures.append(name)


print("press_is_shortcut(needed=2, window=2s)")

# A single press must never fire -- otherwise the button would hijack the radio.
times, fired = mod.press_is_shortcut([], 100.0, 2)
check("one press does not fire", fired, False)
check("one press is remembered", len(times), 1)

# Two presses in quick succession is the shortcut.
times, fired = mod.press_is_shortcut(times, 100.5, 2)
check("two presses inside the window fire", fired, True)
check("counter resets after firing", times, [])

# Slow presses are just normal button use, not a shortcut.
times, fired = mod.press_is_shortcut([], 100.0, 2)
times, fired = mod.press_is_shortcut(times, 103.0, 2)
check("two presses 3s apart do not fire", fired, False)

# Three presses: the first two fire, the third starts a new attempt.
times, fired = mod.press_is_shortcut([], 100.0, 2)
times, fired = mod.press_is_shortcut(times, 100.3, 2)
check("second press fires", fired, True)
times, fired = mod.press_is_shortcut(times, 100.6, 2)
check("third press does not fire again", fired, False)

# launch_presses=1 must work too.
times, fired = mod.press_is_shortcut([], 100.0, 1)
check("needed=1 fires on the first press", fired, True)

print()
print("launch_press_outcome (open with 2 presses, close with 3)")

# Two quick presses while the screen is down open it.
times, what = mod.launch_press_outcome([], 100.0, 2, 3, False)
check("one press while down does nothing", what, None)
times, what = mod.launch_press_outcome(times, 100.4, 2, 3, False)
check("two presses while down launch", what, "launch")
check("counter resets after launching", times, [])

# ...and while the screen is up, two presses must not close it.
times, what = mod.launch_press_outcome([], 100.0, 2, 3, True)
check("one press while up does nothing", what, None)
times, what = mod.launch_press_outcome(times, 100.3, 2, 3, True)
check("two presses while up do not close", what, None)
times, what = mod.launch_press_outcome(times, 100.6, 2, 3, True)
check("three presses while up close", what, "exit")
check("counter resets after closing", times, [])

# Slow presses are normal button use, not a gesture.
times, what = mod.launch_press_outcome([], 100.0, 2, 3, True)
times, what = mod.launch_press_outcome(times, 105.0, 2, 3, True)
times, what = mod.launch_press_outcome(times, 110.0, 2, 3, True)
check("presses spread out never close", what, None)

print()
print("toggle mode (launch_presses=1, exit_presses=1)")

# A single press is the whole gesture in this mode: open while down, close
# while up, so the one button both raises and dismisses the screen.
times, what = mod.launch_press_outcome([], 100.0, 1, 1, False)
check("one press opens", what, "launch")
check("counter resets after opening", times, [])
times, what = mod.launch_press_outcome(times, 100.5, 1, 1, True)
check("the next press closes", what, "exit")
check("counter resets after closing", times, [])

# The two counts are independent: open on one press, but keep the deliberate
# three-press exit if that is what the config asks for.
times, what = mod.launch_press_outcome([], 100.0, 1, 3, True)
check("launch=1 still needs 3 presses to close", what, None)
times, what = mod.launch_press_outcome(times, 100.3, 1, 3, True)
times, what = mod.launch_press_outcome(times, 100.6, 1, 3, True)
check("the third press closes", what, "exit")

print()
print("keymap session")

session = {"active": True, "step": 0, "codes": {},
           "message": mod.keymap_message({"step": 0, "codes": {}})}
check("roles are asked for in order", mod.KEYMAP_ROLES, ("up", "down", "select", "back"))
check("starts by asking for up", "UP" in session["message"], True)

check("712 binds to up", mod.keymap_capture(session, 712), "up")
check("up recorded", session["codes"].get("up"), 712)
check("moves on to down", "DOWN" in session["message"], True)

# The launch button is never captured over: it stays the way in and out.
check("launch button is refused", mod.keymap_capture(session, 724, 724), None)
check("refused press does not advance", session["step"], 1)

# Skip leaves a role unbound.
check("skip consumes the role", mod.keymap_advance(session), "down")
check("down stays unbound", "down" in session["codes"], False)

check("714 binds to select", mod.keymap_capture(session, 714, 724), "select")
check("715 binds to back", mod.keymap_capture(session, 715, 724), "back")
check("session finishes", session["active"], False)
check("summary lists every role", "UP=712" in session["message"], True)
check("unbound role shows as empty", "DOWN=-" in session["message"], True)
check("finished session captures nothing", mod.keymap_capture(session, 716, 724), None)

# A brand new session starts clean.
fresh = {"active": True, "step": 0, "codes": {}, "message": ""}
fresh["message"] = mod.keymap_message(fresh)
check("fresh session asks for up again", "UP" in fresh["message"], True)

print()
print("single-button remap (arm) and session expiry")

narrow = {"active": True, "step": 0, "codes": {}, "roles": ["select"],
          "expires": None, "message": ""}
narrow["message"] = mod.keymap_message(narrow)
check("narrowed session asks for select", "SELECT" in narrow["message"], True)
check("select captured", mod.keymap_capture(narrow, 715, 724), "select")
check("narrowed session finishes at once", narrow["active"], False)
check("summary is just that role", narrow["message"], "Saved   SELECT=715")
check("session_roles narrows", mod.session_roles({"roles": ["back"]}), ["back"])
check("session_roles defaults to all four", mod.session_roles({}), list(mod.KEYMAP_ROLES))
check("rubbish role list falls back", mod.session_roles({"roles": ["nope"]}),
      list(mod.KEYMAP_ROLES))


class FakeDaemon(object):
    pass


def fake_daemon(expires):
    fake = FakeDaemon()
    fake.keys = {"launch": 724}
    fake.keymap_lock = threading.Lock()
    fake.keymap = {"active": True, "step": 0, "codes": {}, "roles": ["select"],
                   "expires": expires, "message": ""}
    return fake


written = []
mod.write_config_value = lambda name, value: written.append((name, value))

stale = fake_daemon(1.0)                      # armed long ago, never answered
check("expired session refuses the press", mod.BtAudioDaemon.capture_code(stale, 715), False)
check("expired session closes itself", stale.keymap["active"], False)
check("expired session writes nothing", written, [])

live = fake_daemon(mod.time.time() + 60)
check("armed session accepts the press", mod.BtAudioDaemon.capture_code(live, 715), True)
check("one press alone writes nothing", written, [])
check("the press is held as a candidate", live.keymap.get("pending_code"), 715)
check("for the role being asked for", live.keymap.get("pending_role"), "select")
check("and the screen is told what arrived",
      "715" in (live.keymap.get("message") or ""), True)

check("pressing it again commits", mod.BtAudioDaemon.capture_code(live, 715), True)
check("the binding reaches the config", written, [("select", 715)])
check("the candidate is let go once it is settled",
      live.keymap.get("pending_code"), None)

print()
print("the two-stage capture rule (shown, then confirmed)")

# A first press is only a candidate, so a mis-press costs nothing.
candidate = {"active": True, "step": 0, "codes": {}, "roles": ["select"],
             "message": ""}
check("a first press previews", mod.keymap_preview(candidate, 715), "preview")
check("and writes nothing", candidate.get("codes"), {})

# The same press again is the confirmation.
candidate["pending_role"] = "select"
candidate["pending_code"] = 715
check("the same press confirms", mod.keymap_preview(candidate, 715), "confirm")

# A different press replaces the candidate instead of committing the wrong one.
check("a different press previews instead", mod.keymap_preview(candidate, 712),
      "preview")
check("previewing alone stores nothing -- capture_code does the storing",
      (candidate.get("pending_role"), candidate.get("pending_code")),
      ("select", 715))

check("a finished session previews nothing",
      mod.keymap_preview({"active": False, "step": 0, "roles": ["select"]}, 715),
      None)
check("nor does an idle one", mod.keymap_preview(None, 715), None)

# The same protection as before still applies: the shortcut button is refused
# unless the step is actually asking to move it.
check("preview refuses the screen button in a normal walk",
      mod.keymap_preview({"active": True, "step": 0, "roles": ["up"]}, 724, 724),
      None)
check("but allows it when that is the step",
      mod.keymap_preview({"active": True, "step": 0, "roles": ["launch"]}, 724, 724),
      "preview")

check("clear_pending lets go of a candidate",
      mod.clear_pending({"pending_role": "select", "pending_code": 715}), None)

dropped = {"pending_role": "select", "pending_code": 715}
mod.clear_pending(dropped)
check("  and the session is empty afterwards", dropped, {})

# SKIP while a candidate is showing must not carry it into the next role, or a
# button pressed for one step could land on the following one.
skipping = {"active": True, "step": 0, "codes": {},
            "roles": ["launch", "select"], "pending_role": "launch",
            "pending_code": 717, "message": ""}
check("skipping a step deals with that role", mod.keymap_advance(skipping), "launch")
check("  and lets go of its candidate",
      (skipping.get("pending_role"), skipping.get("pending_code")), (None, None))
check("  and the session moved on", skipping["step"], 1)
check("  so the next role starts clean",
      mod.session_step(skipping), "select")
check("  and the skipped role stays unbound", skipping["codes"], {})

print()
print("on-screen remap: the step sequence")

check("the plan is button, knob, button",
      mod.remap_plan(), ["launch", "rotary", "select"])
check("unrecognised steps are dropped, not left as dead steps",
      mod.remap_plan(["launch", "nope", "rotary", "select"]),
      ["launch", "rotary", "select"])
check("the plan can be reordered from one place",
      mod.remap_plan(["select", "rotary"]), ["select", "rotary"])
check("launch is a bindable capture role", "launch" in mod.CAPTURE_ROLES, True)
check("but the four-role walk still never asks for it",
      "launch" in mod.KEYMAP_ROLES, False)
check("session_step reports the role being asked for",
      mod.session_step({"active": True, "step": 1, "roles": ["launch", "select"]}),
      "select")
check("session_step is None once the session is over",
      mod.session_step({"active": False, "step": 0, "roles": ["launch"]}), None)

print()
print("on-screen remap: moving the screen button")

# A session that is *asking* for the screen button may capture it -- that is
# the whole first step of the remap.
asks_launch = {"active": True, "step": 0, "codes": {}, "roles": ["launch"],
               "message": ""}
check("the screen button can be captured when it is asked for",
      mod.keymap_capture(asks_launch, 724, 724), "launch")
check("and the press is recorded", asks_launch["codes"].get("launch"), 724)

# ...while a normal four-role walk must still refuse it, or the way in and out
# of the screen could be captured over by accident.
walk = {"active": True, "step": 0, "codes": {}, "roles": None, "message": ""}
check("a normal walk still refuses the screen button",
      mod.keymap_capture(walk, 724, 724), None)
check("the refused press does not advance the walk", walk["step"], 0)

screen = fake_daemon(None)
screen.keys = {"launch": 724, "select": 730}
screen.keymap = {"active": True, "step": 0, "codes": {}, "roles": ["launch"],
                 "expires": None, "message": ""}
written[:] = []
check("the screen button previews on the first press",
      mod.BtAudioDaemon.capture_code(screen, 717), True)
check("and nothing is written yet", written, [])
check("the screen button moves on the second",
      mod.BtAudioDaemon.capture_code(screen, 717), True)
check("and the new keycode is written", written, [("launch", 717)])
check("and it is live straight away", screen.keys.get("launch"), 717)
check("bound_codes reports the screen button",
      mod.BtAudioDaemon.bound_codes(screen).get("launch"), 717)
check("nav_codes never does, so it cannot be relayed as navigation",
      mod.BtAudioDaemon.nav_codes(screen).get("launch"), None)

# Moving the screen button onto a key another role already uses must free that
# role, so one keycode never means two different things.
swap = fake_daemon(None)
swap.keys = {"launch": 724, "select": 730}
swap.keymap = {"active": True, "step": 0, "codes": {}, "roles": ["launch"],
               "expires": None, "message": ""}
written[:] = []
mod.BtAudioDaemon.capture_code(swap, 730)          # preview
check("moving the screen button onto select's key",
      mod.BtAudioDaemon.capture_code(swap, 730), True)   # confirm
check("select is released", swap.keys.get("select"), None)
check("both changes reach the config", written, [("select", ""), ("launch", 730)])

print()
print("on-screen remap: cancelling a step")


class FakeRotary(object):
    scroll_device = mod.BtAudioDaemon.scroll_device
    scroll_invert = mod.BtAudioDaemon.scroll_invert
    scroll_step = mod.BtAudioDaemon.scroll_step
    rotary_state = mod.BtAudioDaemon.rotary_state

    def __init__(self):
        self.keys = {"scroll_device": "/dev/input/event2", "scroll_invert": 1,
                     "scroll_step": 1}
        self.rotary_lock = threading.Lock()
        self.rotary = {"learning": True, "device": "/dev/input/event4",
                       "axis": 3, "delta": 1, "message": ""}


fr = FakeRotary()
fr_state = mod.BtAudioDaemon.action_rotary(fr, "cancel")
check("cancel stops the learn run", fr.rotary.get("learning"), False)
check("cancel drops the knob that was learnt but never applied",
      fr.rotary.get("device"), None)
check("cancel leaves the configured knob alone", fr_state.get("device"),
      "/dev/input/event2")

print()
print("on-screen remap: the knob step (learn -> apply)")

# A knob may only be picked up while a learn run is actually waiting, or a
# stray turn of any encoder on the radio would silently become the scroll knob.
idle = FakeRotary()
idle.rotary.update({"learning": False, "device": None, "axis": None})
check("a turn with no learn run is ignored",
      mod.BtAudioDaemon.record_rotary(idle, "/dev/input/event4", 3, 1), False)
check("and nothing is remembered", idle.rotary.get("device"), None)

learning = FakeRotary()
check("a turn during a learn run is picked up",
      mod.BtAudioDaemon.record_rotary(learning, "/dev/input/event4", 3, 1), True)
check("the evdev device is remembered", learning.rotary.get("device"),
      "/dev/input/event4")
check("and which axis it reports on", learning.rotary.get("axis"), 3)
check("the learn run stops once a knob answers", learning.rotary.get("learning"),
      False)
check("a later turn cannot steal the learnt knob",
      mod.BtAudioDaemon.record_rotary(learning, "/dev/input/event1", 0, 1), False)
check("so the first knob stands", learning.rotary.get("device"),
      "/dev/input/event4")

# apply is what actually commits the learnt knob.
written[:] = []
committed = FakeRotary()
committed.rotary.update({"learning": False, "device": "/dev/input/event4"})
check("apply reports the learnt knob",
      mod.BtAudioDaemon.action_rotary(committed, "apply")["device"],
      "/dev/input/event4")
check("apply writes it to the config", written,
      [("scroll_device", "/dev/input/event4")])
check("and it is live", committed.keys.get("scroll_device"),
      "/dev/input/event4")

# Applying with nothing learnt must fail loudly rather than quietly unset the
# knob that is already working.
empty = FakeRotary()
empty.rotary.update({"learning": False, "device": None})
written[:] = []
try:
    mod.BtAudioDaemon.action_rotary(empty, "apply")
    check("apply with nothing learnt is refused", "no error raised", "RuntimeError")
except RuntimeError:
    check("apply with nothing learnt is refused", "RuntimeError", "RuntimeError")
check("and the working knob is left alone", empty.keys.get("scroll_device"),
      "/dev/input/event2")
check("with nothing written", written, [])

print()
print("rotary_steps (knob -> navigation)")

# One unit per detent: the common case.
leftover, steps = mod.rotary_steps(0, 1, 1)
check("one click clockwise", steps, [1])
check("nothing left pending", leftover, 0)
check("one click the other way", mod.rotary_steps(0, -1, 1)[1], [-1])

# Encoders that report two units per detent must not double-step.
check("two units = one step when step=2", mod.rotary_steps(0, 2, 2)[1], [1])
leftover, steps = mod.rotary_steps(0, 1, 2)
check("half a detent does not step", steps, [])
check("half a detent is remembered", leftover, 1)
leftover, steps = mod.rotary_steps(leftover, 1, 2)
check("the second half completes it", steps, [1])
check("and then nothing is pending", leftover, 0)

# A fast spin gives one step per detent, not one per event burst.
check("five units = five steps", mod.rotary_steps(0, 5, 1)[1], [1, 1, 1, 1, 1])
check("three the other way", mod.rotary_steps(0, -3, 1)[1], [-1, -1, -1])

# Jitter cancels instead of half-scrolling.
leftover, _ = mod.rotary_steps(0, 1, 2)
leftover, steps = mod.rotary_steps(leftover, -1, 2)
check("a click and back cancels", (leftover, steps), (0, []))

# A missing or silly step value must not stall scrolling.
check("step=None still steps", mod.rotary_steps(0, 1, None)[1], [1])
check("step=0 still steps", mod.rotary_steps(0, 1, 0)[1], [1])

print()
if failures:
    print("%d FAILED: %s" % (len(failures), ", ".join(failures)))
    sys.exit(1)
print("all checks passed")
