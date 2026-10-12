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
check("the binding reaches the config", written, [("select", 715)])

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
