#! /bin/sh
# panelrun.sh -- show the BT Audio screen on the radio's real panel for a while
# and then hand the display back, whatever happens.
#
#   sh panelrun.sh [SECONDS] [screen|keymap|calibrate]
#
# Why this exists: the radio has no timeout(1), no pgrep and no pkill (only
# pidof and killall), and a screen that does not exit leaves the stock GUI
# parked -- which is completely invisible over SSH.  A test run once left the
# panel on the BT Audio screen for minutes because its "watchdog" used pkill and
# silently did nothing.  So here the watchdog is an independent shell that kills
# the renderer *and* then makes sure the stock GUI and its supervision are back,
# and it is armed before the screen is started.
#
# Start it detached so the SSH session that launched it cannot take it down:
#
#     setsid sh /tmp/panelrun.sh 90 >/tmp/panelrun.out 2>&1 &
#
# Copy it to the radio with:
#
#     scp dev/panelrun.sh root@<radio>:/tmp/panelrun.sh

SECS=${1:-90}
WHAT=${2:-screen}
CTL=/usr/share/support/btaudio
UI=x6200_ui_v100
SELF=panelrun.sh

# One test at a time.  Two runs overlapping used to mean the older one's watchdog
# killed the newer one's screen halfway through -- the panel just went back to the
# radio mid-test and nothing said why.
for pid in $(ps -ef | grep "[$]SELF" | sed -n "s/^[^ ]* *\([0-9]*\).*/\1/p"); do
    [ "$pid" = "$$" ] && continue
    echo "stopping an earlier panelrun (pid $pid)"
    kill "$pid" 2>/dev/null
    sleep 0.5
    kill -9 "$pid" 2>/dev/null
done

# ...and never start on top of a screen that is already up: it would answer
# "already showing" and this run would sit out its whole window doing nothing.
if pidof qmlscene >/dev/null 2>&1; then
    echo "a screen was already up; closing it first"
    killall qmlscene 2>/dev/null
    sleep 3
fi

restore() {
    killall qmlscene 2>/dev/null
    sleep 3
    if ! pidof "$UI" >/dev/null 2>&1; then
        /usr/share/support/userapp start >/dev/null 2>&1
        sleep 3
    fi
    if ! pidof monit >/dev/null 2>&1; then
        /etc/init.d/S99-1-monit start >/dev/null 2>&1
    fi
}

# Watchdog first: it must already be sleeping by the time the screen takes the
# panel, otherwise a hung screen has nothing to rescue it.
(
    sleep "$SECS"
    echo "watchdog: ${SECS}s are up, handing the panel back"
    restore
) &

case "$WHAT" in
    screen) "$CTL" start ;;
    *)      "$CTL" "$WHAT" ;;    # keymap, calibrate, ...
esac
rc=$?
echo "screen returned rc=$rc (ran for up to ${SECS}s)"

# Idempotent: usually the launcher has already restored everything itself.
restore

echo "--- /tmp/btaudio-screen.log ---"
cat /tmp/btaudio-screen.log 2>/dev/null
echo "--- afterwards ---"
if pidof "$UI" >/dev/null 2>&1; then
    echo "stock GUI running"
else
    echo "STOCK GUI MISSING -- press the front-panel launch button or reboot"
fi
