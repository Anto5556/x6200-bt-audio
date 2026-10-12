#!/bin/sh
# Push BT Audio to the radio and install it there.
#
#   ./deploy.sh                 install to the default radio
#   ./deploy.sh uninstall       remove it again
#   RADIO=root@192.168.0.55 ./deploy.sh
#
# The radio must be reachable over SSH as root (the X6200 ships with SSH enabled
# and a default root password; set up a key if you have not already).
set -e

RADIO="${RADIO:-root@192.168.0.103}"
here=$(cd "$(dirname "$0")" && pwd)
STAGE=/tmp/btaudio-install

echo "Deploying to $RADIO ..."
ssh "$RADIO" "rm -rf $STAGE && mkdir -p $STAGE/radio"
scp -q "$here/install.sh" "$RADIO:$STAGE/install.sh"
scp -q "$here/README.md" "$RADIO:$STAGE/README.md"
scp -q "$here/radio/btaudiod" \
       "$here/radio/BtAudio.qml" \
       "$here/radio/Calibrate.qml" \
       "$here/radio/KeyMap.qml" \
       "$here/radio/btaudio" \
       "$here/radio/S52btaudiod" \
       "$here/radio/btaudio.conf" \
       "$RADIO:$STAGE/radio/"
ssh "$RADIO" "chmod +x $STAGE/install.sh && cd $STAGE && ./install.sh $*"
