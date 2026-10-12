#! /bin/sh
# Install BT Audio into the Xiegu X6200's firmware layout.  Run as root ON the
# radio, from a copy of this directory (see deploy.sh to push it from a host).
#
# Nothing outside these paths is touched, and nothing is overwritten that was
# not installed by a previous run of this script.
#
#   /usr/app_qt/btaudio/          the app itself (backend + QML screen)
#   /usr/share/support/btaudio    launcher, alongside the firmware's own helpers
#   /etc/init.d/S52btaudiod       starts the backend at boot
#
# Uninstall with:  ./install.sh uninstall

HERE=$(cd "$(dirname "$0")" && pwd)
APP_DIR=/usr/app_qt/btaudio
CTL=/usr/share/support/btaudio
INIT=/etc/init.d/S52btaudiod

if [ "$(id -u)" != "0" ]; then
    echo "install.sh: must run as root on the radio" >&2
    exit 1
fi

case "$1" in
    uninstall)
        [ -x "$CTL" ] && "$CTL" daemon stop
        # Put the radio back on its own screen before removing anything.
        [ -x /usr/share/support/userapp ] && /usr/share/support/userapp start >/dev/null 2>&1
        [ -x /etc/init.d/S99-1-monit ] && /etc/init.d/S99-1-monit start >/dev/null 2>&1
        rm -f "$INIT" "$CTL" /etc/btaudio.conf
        rm -rf "$APP_DIR"
        rm -f /var/lib/btaudio.state /tmp/btaudio.log /tmp/btaudiod.pid \
              /tmp/btaudio.snapshot /tmp/btaudio-screen.log
        echo "BT Audio removed."
        exit 0
        ;;
esac

for f in radio/btaudiod radio/BtAudio.qml radio/Calibrate.qml radio/KeyMap.qml \
         radio/btaudio radio/S52btaudiod radio/btaudio.conf; do
    if [ ! -f "$HERE/$f" ]; then
        echo "install.sh: missing $HERE/$f" >&2
        exit 1
    fi
done

mkdir -p "$APP_DIR"
mkdir -p /var/lib

cp "$HERE/radio/btaudiod"  "$APP_DIR/btaudiod"
cp "$HERE/radio/BtAudio.qml" "$APP_DIR/BtAudio.qml"
cp "$HERE/radio/Calibrate.qml" "$APP_DIR/Calibrate.qml"
cp "$HERE/radio/KeyMap.qml" "$APP_DIR/KeyMap.qml"
chmod 0755 "$APP_DIR/btaudiod"
chmod 0644 "$APP_DIR/BtAudio.qml" "$APP_DIR/Calibrate.qml" "$APP_DIR/KeyMap.qml"

cp "$HERE/radio/btaudio" "$CTL"
chmod 0755 "$CTL"

cp "$HERE/radio/S52btaudiod" "$INIT"
chmod 0755 "$INIT"

# Never clobber a config the user has already edited.
if [ -f /etc/btaudio.conf ]; then
    echo "Kept existing /etc/btaudio.conf"
else
    cp "$HERE/radio/btaudio.conf" /etc/btaudio.conf
    chmod 0644 /etc/btaudio.conf
fi

echo "Installed:"
echo "  $APP_DIR/btaudiod      backend + the audio bridge (taps the radio's audio)"
echo "  $APP_DIR/BtAudio.qml   the screen"
echo "  $CTL                   launcher (start|stop|status|snapshot)"
echo "  $INIT                  starts the backend at boot"
echo "  $APP_DIR/Calibrate.qml  screen-orientation calibration"
echo "  $APP_DIR/KeyMap.qml     front-panel button mapping"
echo "  /etc/btaudio.conf      front-panel key bindings and rotation"
echo "  /var/lib/btaudio.state routing preference (survives reboots)"
echo
echo "Show the screen with:   /usr/share/support/btaudio start"
