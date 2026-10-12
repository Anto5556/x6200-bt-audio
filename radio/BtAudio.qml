// BtAudio.qml -- "BT AUDIO", a Bluetooth audio-out manager for the Xiegu X6200.
//
// Rendered by the radio's own Qt 5.12 runtime (qmlscene) on the same EGLFS
// display the stock UI uses, so it feels like a native screen.
//
// Deliberately built from plain QtQuick primitives rather than QtQuick
// Controls 2: nothing extra to load, full control of the 800x480 layout, and it
// renders reliably on the Mali400 GPU.
//
// The backend daemon (btaudiod) owns all the Bluetooth and audio work and is
// reached over a loopback JSON API.

import QtQuick 2.12
import QtQuick.Window 2.12

Window {
    id: root

    // The launcher asks Qt for no EGLFS rotation, so the logical screen is the
    // panel's own 480x800 portrait frame: a 800x480 layout turned a quarter turn
    // fits it exactly, and turning it here (rather than asking the driver to do
    // it) is the only thing that works on this display -- EGLFS rotation was
    // measured to leave the surface 90 degrees out either way.  Which of the two
    // quarter turns is right lives in /etc/btaudio.conf; `btaudio calibrate`
    // shows the choice and saves it.
    readonly property int designWidth: 800
    readonly property int designHeight: 480

    width: Screen.width > 0 ? Screen.width : 480
    height: Screen.height > 0 ? Screen.height : 800
    visible: true
    color: theme.bg
    title: "BT Audio"

    // ---------------------------------------------------------------------
    // Palette and metrics
    // ---------------------------------------------------------------------
    QtObject {
        id: theme
        readonly property color bg: "#0b0f14"
        readonly property color panel: "#141b24"
        readonly property color panelHi: "#1c2733"
        readonly property color line: "#26333f"
        readonly property color text: "#e6edf3"
        readonly property color dim: "#8b98a5"
        readonly property color accent: "#39c6f2"
        readonly property color accentDim: "#1d6b85"
        readonly property color good: "#3fb950"
        readonly property color warn: "#d29922"
        readonly property color bad: "#f85149"
        readonly property string family: "DejaVu Sans"
    }

    readonly property string api: "http://127.0.0.1:8637"

    // Rotation of the design stage.
    //
    // The layout is authored at 800x480 and lives in a frame of the panel's own
    // shape, so it always needs a quarter turn: 270 (-90) for the raw 480x800
    // portrait frame, 0 if a display ever hands over an 800x480 landscape one.
    // An angle saved by `btaudio calibrate` in /etc/btaudio.conf wins over both.
    readonly property int autoRotation:
        (Screen.width > 0 && Screen.height > 0 && Screen.width < Screen.height) ? 270 : 0

    readonly property var storedRotation:
        (state && state.rotation !== undefined && state.rotation !== null
         && String(state.rotation) !== "auto") ? Number(state.rotation) : null

    readonly property int contentRotation:
        storedRotation !== null ? storedRotation : autoRotation

    // ---------------------------------------------------------------------
    // Live state
    // ---------------------------------------------------------------------
    property var state: null
    property bool backendUp: false
    property string banner: ""
    property bool bannerBad: false

    // Discovery auto-stops so the radio is not scanning forever.
    property bool scanning: false

    // What the front panel is currently on.  The whole screen is one list of
    // focusable items -- the route switch, volume, speaker, scan, then every
    // device row, then close -- so a knob or a pair of buttons can walk the
    // entire interface instead of being stuck in the device list.  The item the
    // panel is on is drawn with an amber ring.
    property int focus: 0
    property int deviceFocus: 0

    // The front panel is handled by the backend (see KeyWatch in btaudiod) and
    // relayed here as a rising sequence number, so navigation works even if Qt
    // never delivers the keymap's vendor keycodes to this process.
    property int navSeq: 0
    property bool navPrimed: false

    function focusItems() {
        var items = ["route", "volume", "speaker", "scan", "remap"];
        var list = devices();
        for (var i = 0; i < list.length; i++)
            items.push("device:" + i);
        items.push("close");
        return items;
    }

    function focused() {
        var items = focusItems();
        if (items.length === 0)
            return null;
        return items[Math.max(0, Math.min(root.focus, items.length - 1))];
    }

    function focusIsDevice(index) {
        return root.focused() === ("device:" + index);
    }

    function moveFocus(delta) {
        var items = focusItems();
        if (items.length === 0)
            return;
        root.focus = Math.max(0, Math.min(items.length - 1, root.focus + delta));
        var name = items[root.focus];
        if (name.indexOf("device:") === 0) {
            root.deviceFocus = parseInt(name.slice(7), 10) || 0;
            deviceList.positionViewAtIndex(root.deviceFocus, ListView.Contain);
        }
    }

    // Keep the panel and the mouse in step: touching a control with the mouse
    // moves the focus there too, so the amber ring never lies.
    function focusOn(name) {
        var items = focusItems();
        for (var i = 0; i < items.length; i++) {
            if (items[i] === name) {
                root.focus = i;
                if (root.volumeLocked && name !== "volume")
                    root.volumeLocked = false;
                if (name.indexOf("device:") === 0) {
                    root.deviceFocus = parseInt(name.slice(7), 10) || 0;
                    deviceList.positionViewAtIndex(root.deviceFocus, ListView.Contain);
                }
                return;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Front-panel remap (the REMAP entry in the menu)
    // ---------------------------------------------------------------------
    // Walks the sequence the backend declares in state.remap.steps: the button
    // that raises this screen, the knob to scroll with, then the button that
    // selects.  Each button step arms exactly one role, so the press that
    // arrives next cannot land on anything else; the knob step reuses the same
    // learn run `btaudio keymap` uses.  The sequence lives in the backend, so
    // changing the order is one edit there and no edit here.
    property bool remapOpen: false
    property int remapStep: 0
    property bool remapSeen: false     // backend confirmed the step is armed
    property bool remapDone: false

    function km() {
        return (root.state && root.state.keymap) ? root.state.keymap : null;
    }

    function knob() {
        return (root.state && root.state.rotary) ? root.state.rotary : null;
    }

    function remapSteps() {
        var r = root.state ? root.state.remap : null;
        if (r && r.steps && r.steps.length > 0)
            return r.steps;
        return ["launch", "rotary", "select"];
    }

    function remapStepName() {
        var list = root.remapSteps();
        return (root.remapStep < list.length) ? list[root.remapStep] : null;
    }

    function remapStepTitle(name) {
        if (name === "launch")
            return "Button that opens this screen";
        if (name === "select")
            return "Button that selects";
        if (name === "rotary")
            return "Knob that scrolls the list";
        return name;
    }

    // The keycode that has just arrived for the current step and is waiting to
    // be confirmed, or null.  This is the readout that makes a mis-press obvious
    // while it can still be changed -- nothing is written until it is confirmed.
    function remapPending() {
        var map = root.km();
        if (!map || !map.active)
            return null;
        var code = map.pending_code;
        if (code === undefined || code === null)
            return null;
        if (map.pending_role !== root.remapStepName())
            return null;
        return String(code);
    }

    function remapStepValue(name) {
        if (name === "rotary") {
            var k = root.knob();
            return (k && k.device) ? k.device : "--";
        }
        var map = root.km();
        var bound = map ? map.bound : null;
        if (bound && bound[name] !== undefined && bound[name] !== null)
            return String(bound[name]);
        return "--";
    }

    function openRemap() {
        root.remapOpen = true;
        root.remapStep = 0;
        root.remapDone = false;
        root.remapSeen = false;
        root.beginRemapStep();
    }

    function beginRemapStep() {
        var name = root.remapStepName();
        root.remapSeen = false;
        if (name === null) {
            root.remapDone = true;
            remapDoneTimer.restart();
            return;
        }
        if (name === "rotary")
            root.post({ action: "rotary", cmd: "learn" });
        else
            root.post({ action: "keymap", cmd: "arm", role: name, seconds: 180 });
    }

    // Called from the /state poll: the only place that decides a step finished.
    // Waiting to *see* the step armed before accepting its completion keeps a
    // stale poll from skipping a step outright.
    function pumpRemap() {
        if (!root.remapOpen || root.remapDone || !root.backendUp)
            return;
        var name = root.remapStepName();
        if (name === null)
            return;
        if (name === "rotary") {
            var r = root.knob();
            if (!r)
                return;
            if (!root.remapSeen) {
                if (r.learning)
                    root.remapSeen = true;
                return;
            }
            if (r.learned) {
                root.post({ action: "rotary", cmd: "apply" });
                root.advanceRemap();
            }
            return;
        }
        var map = root.km();
        if (!map)
            return;
        if (!root.remapSeen) {
            if (map.active && map.step_role === name)
                root.remapSeen = true;
            return;
        }
        if (!map.active)          // the press landed and the role is written
            root.advanceRemap();
    }

    function advanceRemap() {
        root.remapStep += 1;
        root.beginRemapStep();
    }

    function restartRemap() {
        root.post({ action: "keymap", cmd: "cancel" });
        root.post({ action: "rotary", cmd: "cancel" });
        remapDoneTimer.stop();
        root.remapStep = 0;
        root.remapDone = false;
        root.beginRemapStep();
    }

    function skipRemapStep() {
        var name = root.remapStepName();
        if (name === null) {
            root.closeRemap();
            return;
        }
        if (name === "rotary")
            root.post({ action: "rotary", cmd: "cancel" });
        else
            root.post({ action: "keymap", cmd: "skip" });
        root.advanceRemap();
    }

    function closeRemap() {
        // Never leave a step armed: a button pressed after the overlay is gone
        // would silently become the next binding.
        root.post({ action: "keymap", cmd: "cancel" });
        root.post({ action: "rotary", cmd: "cancel" });
        var saved = root.remapDone;
        root.remapOpen = false;
        root.remapDone = false;
        remapDoneTimer.stop();
        if (saved)
            root.flash("Front-panel mapping updated", false);
    }

    function toggleRoute() {
        var target = connectedAudioDevice();
        var on = !!(route() && route().enabled);
        if (!on && !target) {
            root.flash("Connect a Bluetooth headset first", true);
            return;
        }
        root.cmd("route", { on: !on, addr: target ? target.addr : (route() ? route().addr : null) });
    }

    // Volume is the one control with a continuous value and no left/right key
    // on the panel, so selecting it takes the knob: from then on turning the
    // knob moves the volume and the ring stays put, and selecting again lets go.
    property bool volumeLocked: false

    function bumpVolume(delta) {
        var v = (route() ? route().volume : 70) + delta;
        v = Math.max(0, Math.min(150, v));
        root.cmd("volume", { percent: v });
    }

    function setVolumeLock(on) {
        root.volumeLocked = on;
        root.flash(on ? "Volume: turn the knob    \u2022    select to let go"
                      : "Volume released", false);
    }

    // Use whatever the panel is on.
    function activate() {
        var name = focused();
        if (!name)
            return;
        if (name === "route") {
            root.toggleRoute();
        } else if (name === "volume") {
            root.setVolumeLock(!root.volumeLocked);
        } else if (name === "speaker") {
            root.cmd("local", { muted: !(route() && route().local_muted) });
        } else if (name === "scan") {
            root.toggleScan();
        } else if (name === "remap") {
            root.openRemap();
        } else if (name === "close") {
            Qt.quit();
        } else if (name.indexOf("device:") === 0) {
            var d = root.devices()[parseInt(name.slice(7), 10)];
            if (d)
                root.primaryAction(d);
        }
    }

    function applyNav(action) {
        // The remap overlay is modal: the front panel is being captured by the
        // backend, so the only thing a mapped button should still do is leave.
        if (root.remapOpen) {
            if (action === "back" || action === "exit")
                root.closeRemap();
            return;
        }
        // While the volume has the knob, arrows and turns change the volume
        // instead of walking the ring away from the control being adjusted.
        if (root.volumeLocked) {
            // Turning the knob the way that scrolls the list *down* raises the
            // volume, which is the direction a radio's volume knob goes.
            if (action === "down") {
                root.bumpVolume(5);
                return;
            }
            if (action === "up") {
                root.bumpVolume(-5);
                return;
            }
            if (action === "select") {
                root.setVolumeLock(false);
                return;
            }
            // back and exit still close the screen.
        }
        if (action === "down") {
            root.moveFocus(1);
        } else if (action === "up") {
            root.moveFocus(-1);
        } else if (action === "select") {
            root.activate();
        } else if (action === "back" || action === "exit") {
            // "exit" is the front-panel gesture -- three quick presses of the
            // launch button; "back" is whatever button the user mapped for it.
            Qt.quit();
        }
    }

    function handleNav(state) {
        if (!state || !state.nav)
            return;
        if (!root.navPrimed) {
            root.navSeq = state.nav.seq;
            root.navPrimed = true;
            return;
        }
        if (state.nav.seq === root.navSeq)
            return;
        root.navSeq = state.nav.seq;
        root.applyNav(state.nav.action);
    }

    function devices() {
        return (state && state.devices) ? state.devices : [];
    }

    function adapter() {
        return (state && state.adapter) ? state.adapter : null;
    }

    function route() {
        return (state && state.route) ? state.route : null;
    }

    // The device the route switch will feed.  "ready" means PulseAudio has
    // published a sink for it, i.e. the A2DP link is genuinely up.
    function connectedAudioDevice() {
        var list = devices();
        for (var i = 0; i < list.length; i++)
            if (list[i].connected && list[i].ready)
                return list[i];
        for (var j = 0; j < list.length; j++)
            if (list[j].connected && list[j].audio)
                return list[j];
        return null;
    }

    function pendingDevice() {
        var list = devices();
        for (var i = 0; i < list.length; i++)
            if (list[i].connected && !list[i].ready && list[i].audio)
                return list[i];
        return null;
    }

    function flash(msg, bad) {
        banner = msg;
        bannerBad = !!bad;
        bannerTimer.restart();
    }

    // ---------------------------------------------------------------------
    // Backend calls
    // ---------------------------------------------------------------------
    function fetchState() {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", root.api + "/state");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4)
                return;
            if (xhr.status === 200) {
                try {
                    root.state = JSON.parse(xhr.responseText);
                    root.backendUp = true;
                    root.handleNav(root.state);
                } catch (e) {
                    root.backendUp = false;
                }
                // Kept out of the block above on purpose: a fault in the remap
                // overlay must never mark the backend down and so freeze the
                // whole screen's navigation.
                try {
                    root.pumpRemap();
                } catch (e) {
                    console.log("remap error: " + e);
                }
            } else {
                root.backendUp = false;
            }
        };
        xhr.send();
    }

    // POST a fully-formed command body.  The remap helpers below build one
    // object (action plus its fields) and hand it over whole, so they need this
    // rather than cmd(), which takes the action separately.  Without it those
    // calls throw a TypeError, which used to leave the modal REMAP overlay open
    // and swallow every front-panel press.
    function post(body) {
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.api + "/cmd");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function () {
            if (xhr.readyState === 4)
                root.fetchState();
        };
        xhr.send(JSON.stringify(body));
    }

    function cmd(action, params) {
        var body = params || {};
        body.action = action;
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.api + "/cmd");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4)
                return;
            var reply = null;
            try {
                reply = JSON.parse(xhr.responseText);
            } catch (e) {
                reply = null;
            }
            if (reply && reply.ok === false)
                root.flash(reply.error || "command failed", true);
            else if (reply && reply.message && reply.message !== "paired")
                root.flash(reply.message, false);
            root.fetchState();
        };
        xhr.send(JSON.stringify(body));
    }

    function toggleScan() {
        if (root.scanning) {
            root.scanning = false;
            root.cmd("scan", { on: false });
        } else {
            root.scanning = true;
            root.cmd("scan", { on: true });
            scanTimeout.restart();
        }
    }

    function isTarget(d) {
        var r = route();
        return !!(r && r.addr && d.addr &&
                  r.addr.toUpperCase() === d.addr.toUpperCase());
    }

    function primaryLabel(d) {
        if (d.connected)
            return "DISCONNECT";
        if (d.paired)
            return "CONNECT";
        return "PAIR";
    }

    function primaryAction(d) {
        if (d.connected)
            cmd("disconnect", { addr: d.addr });
        else if (d.paired)
            cmd("connect", { addr: d.addr });
        else
            cmd("pair", { addr: d.addr });
    }

    // Development hook: if /tmp/btaudio.snapshot exists, its contents name a
    // PNG file. After the UI has settled we save a frame there and exit, which
    // makes the screen inspectable without photographing the radio.
    property string snapshotPath: ""

    function checkSnapshotHook() {
        var xhr = new XMLHttpRequest();
        try {
            xhr.open("GET", "file:///tmp/btaudio.snapshot", false);
            xhr.send();
            if (xhr.status === 200 && xhr.responseText)
                root.snapshotPath = String(xhr.responseText).replace(/\s+$/, "");
        } catch (e) {
            root.snapshotPath = "";
        }
        if (root.snapshotPath !== "")
            snapshotTimer.start();
    }

    Component.onCompleted: {
        // This is the frame Qt actually gave us, and the rotation that goes with
        // it.  If the screen ever comes up sideways, /tmp/btaudio-screen.log
        // answers "which of the two cases are we in?" in one line.
        console.log("bt audio: logical screen " + Screen.width + "x" + Screen.height
                    + ", content rotation " + root.contentRotation);
        fetchState();
        checkSnapshotHook();
    }

    Timer {
        id: snapshotTimer
        interval: 2500
        onTriggered: {
            root.contentItem.grabToImage(function (result) {
                result.saveToFile(root.snapshotPath);
                Qt.quit();
            });
        }
    }

    // ---------------------------------------------------------------------
    // Timers
    // ---------------------------------------------------------------------
    Timer {
        // Fast enough that a front-panel press feels immediate, cheap because
        // /state is served from the backend's cache.
        interval: 400
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.fetchState()
    }

    Timer {
        id: scanTimeout
        interval: 30000
        onTriggered: {
            if (root.scanning) {
                root.scanning = false;
                root.cmd("scan", { on: false });
            }
        }
    }

    Timer {
        id: bannerTimer
        interval: 4000
        onTriggered: root.banner = ""
    }

    // Front-panel and keyboard navigation.  A Window cannot carry Keys itself,
    // so a focusable full-screen Item receives them for the whole screen.
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.onPressed: {
            var keys = (root.state && root.state.keys) ? root.state.keys : {};
            var scan = event.nativeScanCode;

            var back = event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
                       || (keys.back && scan === keys.back);
            var down = event.key === Qt.Key_Down || event.key === Qt.Key_Tab
                       || (keys.down && scan === keys.down);
            var up = event.key === Qt.Key_Up || (keys.up && scan === keys.up);
            var select = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                         || event.key === Qt.Key_Space || (keys.select && scan === keys.select);

            if (back) {
                root.applyNav("back");
                event.accepted = true;
            } else if (down) {
                root.applyNav("down");
                event.accepted = true;
            } else if (up) {
                root.applyNav("up");
                event.accepted = true;
            } else if (select) {
                root.applyNav("select");
                event.accepted = true;
            }
        }
    }

    // ---------------------------------------------------------------------
    // Background
    // ---------------------------------------------------------------------
    Rectangle {
        anchors.fill: parent
        gradient: Gradient {
            GradientStop { position: 0.0; color: "#0d1319" }
            GradientStop { position: 1.0; color: "#080b0f" }
        }
    }

    // ---------------------------------------------------------------------
    // Design stage -- the whole UI is authored at 800x480 and rotated here
    // ---------------------------------------------------------------------
    Item {
        id: stage
        width: root.designWidth
        height: root.designHeight
        anchors.centerIn: parent
        rotation: root.contentRotation

    // ---------------------------------------------------------------------
    // Header
    // ---------------------------------------------------------------------
    Rectangle {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        height: 52
        color: theme.panel

        Rectangle {
            anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
            height: 1
            color: theme.line
        }

        Text {
            anchors { left: parent.left; leftMargin: 16; verticalCenter: parent.verticalCenter }
            text: "BLUETOOTH AUDIO"
            color: theme.text
            font { family: theme.family; pixelSize: 21; bold: true; letterSpacing: 2 }
        }

        Row {
            anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
            spacing: 8

            // Adapter pill
            Rectangle {
                width: adapterText.width + 34
                height: 28
                radius: 14
                color: theme.bg
                border.color: root.backendUp ? (adapter() && adapter().powered ? theme.good : theme.dim) : theme.bad
                border.width: 1

                Rectangle {
                    id: adapterDot
                    anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                    width: 8; height: 8; radius: 4
                    color: root.backendUp
                           ? (adapter() && adapter().powered ? theme.good : theme.dim)
                           : theme.bad
                }
                Text {
                    id: adapterText
                    anchors { left: adapterDot.right; leftMargin: 8; verticalCenter: parent.verticalCenter }
                    text: !root.backendUp ? "BT SERVICE OFF"
                        : (adapter() ? (adapter().powered ? "ADAPTER ON" : "ADAPTER OFF") : "NO ADAPTER")
                    color: theme.dim
                    font { family: theme.family; pixelSize: 12; bold: true }
                }
            }

            // Exit
            Rectangle {
                width: 84; height: 28; radius: 14
                color: exitHover.containsMouse ? theme.panelHi : theme.bg
                border.color: root.focused() === "close" ? theme.warn : theme.line
                border.width: root.focused() === "close" ? 2 : 1
                Text {
                    anchors.centerIn: parent
                    text: "CLOSE"
                    color: theme.text
                    font { family: theme.family; pixelSize: 12; bold: true }
                }
                MouseArea {
                    id: exitHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.focusOn("close")
                    onClicked: Qt.quit()
                }
            }
        }
    }

    // While a mapping session is armed (see `btaudio keymap`), say so on the
    // panel: whatever front-panel button is pressed next becomes that binding,
    // so it must not happen by surprise.
    Rectangle {
        id: mappingStrip
        z: 10
        visible: !root.remapOpen
                 && !!(root.state && root.state.keymap && root.state.keymap.active)
        anchors { top: header.bottom; left: parent.left; right: parent.right }
        height: 32
        color: "#2b2413"
        border.color: theme.warn
        border.width: 1

        Text {
            anchors.centerIn: parent
            text: "MAPPING \u2014 " + (root.state && root.state.keymap
                                      ? root.state.keymap.message : "")
            color: theme.warn
            font { family: theme.family; pixelSize: 13; bold: true }
        }
    }

    // ---------------------------------------------------------------------
    // Route card -- the whole point of the app
    // ---------------------------------------------------------------------
    // The remap result stays up for a moment, then the overlay hands the
    // screen back -- long enough to read which keycode landed.
    Timer {
        id: remapDoneTimer
        interval: 8000
        onTriggered: root.closeRemap()
    }

    Rectangle {
        id: routeCard
        anchors { top: header.bottom; left: parent.left; right: parent.right; margins: 10 }
        height: 116
        radius: 8
        color: theme.panel
        border.color: route() && route().enabled ? theme.accentDim : theme.line
        border.width: 1

        property var target: connectedAudioDevice()
        property bool on: !!(route() && route().enabled)

        Column {
            anchors { left: parent.left; leftMargin: 16; right: parent.right; rightMargin: 16; top: parent.top; topMargin: 12 }
            spacing: 8

            Row {
                spacing: 8

                Text {
                    text: "RADIO AUDIO TO BLUETOOTH"
                    color: theme.text
                    font { family: theme.family; pixelSize: 15; bold: true; letterSpacing: 1 }
                }

                // Live/silent indicator
                Rectangle {
                    width: 76; height: 20; radius: 10
                    anchors.verticalCenter: parent.verticalCenter
                    color: routeCard.on && route().active ? "#12351d" : theme.bg
                    border.color: routeCard.on && route().active ? theme.good : theme.line
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: routeCard.on ? (route().active ? "STREAMING" : "WAITING") : "OFF"
                        color: routeCard.on ? (route().active ? theme.good : theme.warn) : theme.dim
                        font { family: theme.family; pixelSize: 10; bold: true }
                    }
                }
            }

            Text {
                width: parent.width
                text: {
                    if (!root.backendUp)
                        return "Cannot reach the audio service.";
                    if (root.volumeLocked)
                        return "Volume: turn the knob to adjust it, then select to go back to moving around.";
                    if (!routeCard.target) {
                        var pending = root.pendingDevice();
                        if (pending)
                            return "Waiting for " + pending.name + " to finish connecting...";
                        return "Connect a headset below to send the radio's audio to it.";
                    }
                    return "Routing to " + routeCard.target.name
                         + (route().active ? "" : " (starting up)");
                }
                color: theme.dim
                font { family: theme.family; pixelSize: 12 }
                elide: Text.ElideRight
            }

            Row {
                spacing: 12

                // Big on/off switch
                Rectangle {
                    id: routeSwitch
                    width: 132; height: 38; radius: 8
                    color: routeCard.on ? theme.accentDim : theme.panelHi
                    border.color: root.focused() === "route" ? theme.warn
                                  : (routeCard.on ? theme.accent : theme.line)
                    border.width: root.focused() === "route" ? 2 : 1

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Rectangle {
                            width: 34; height: 18; radius: 9
                            anchors.verticalCenter: parent.verticalCenter
                            color: routeCard.on ? theme.accent : "#3a4653"
                            Rectangle {
                                width: 14; height: 14; radius: 7
                                anchors.verticalCenter: parent.verticalCenter
                                x: routeCard.on ? parent.width - width - 2 : 2
                                color: "#ffffff"
                                Behavior on x { NumberAnimation { duration: 120 } }
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: routeCard.on ? "ON" : "OFF"
                            color: routeCard.on ? "#ffffff" : theme.text
                            font { family: theme.family; pixelSize: 14; bold: true }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.focusOn("route")
                        onClicked: root.toggleRoute()
                    }
                }

                // Volume
                Row {
                    spacing: 8
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                        text: "VOL"
                        color: theme.dim
                        anchors.verticalCenter: parent.verticalCenter
                        font { family: theme.family; pixelSize: 12; bold: true }
                    }

                    Item {
                        id: volumeSlider
                        width: 220; height: 38
                        anchors.verticalCenter: parent.verticalCenter

                        property int value: route() ? route().volume : 70

                        Rectangle {
                            id: volTrack
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 8; radius: 4
                            color: theme.bg
                            border.color: theme.line; border.width: 1

                            Rectangle {
                                width: Math.round(parent.width * Math.max(0, Math.min(100, volumeSlider.value)) / 100)
                                height: parent.height
                                radius: 4
                                color: theme.accent
                            }
                        }

                        Rectangle {
                            width: 18; height: 18; radius: 9
                            x: Math.round((parent.width - width) * Math.max(0, Math.min(100, volumeSlider.value)) / 100)
                            anchors.verticalCenter: parent.verticalCenter
                            color: "#ffffff"
                        }

                        // The amber ring the front panel puts on the controls it
                        // can reach.  Filled in while the volume has the knob.
                        Rectangle {
                            anchors.fill: parent
                            anchors.margins: -6
                            radius: 8
                            color: root.volumeLocked ? "#2ed29922" : "transparent"
                            border.color: theme.warn
                            border.width: root.volumeLocked ? 3 : 2
                            visible: root.focused() === "volume"
                        }

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            onEntered: root.focusOn("volume")
                            // Drag to set a level, click to take or release the
                            // knob, so the mouse can do both jobs too.
                            onPositionChanged: if (pressed) setFromX(mouse.x)
                            onClicked: {
                                root.focusOn("volume");
                                root.setVolumeLock(!root.volumeLocked);
                            }

                            function setFromX(x) {
                                var pct = Math.round(100 * Math.max(0, Math.min(1, x / volumeSlider.width)));
                                pushDebounce.pct = pct;
                                pushDebounce.restart();
                            }
                        }

                        Timer {
                            id: pushDebounce
                            property int pct: 70
                            interval: 160
                            onTriggered: root.cmd("volume", { percent: pct })
                        }
                    }

                    Text {
                        text: (route() ? route().volume : 70) + "%"
                        color: theme.text
                        width: 44
                        anchors.verticalCenter: parent.verticalCenter
                        font { family: theme.family; pixelSize: 13; bold: true }
                    }
                }

                // Local speaker mute.  Silences the radio's own output while the
                // Bluetooth bridge keeps feeding the headset.
                Rectangle {
                    id: localSwitch
                    width: 126; height: 32; radius: 6
                    anchors.verticalCenter: parent.verticalCenter
                    property bool muted: !!(route() && route().local_muted)
                    color: localSwitch.muted ? "#3a2224" : theme.panelHi
                    border.color: root.focused() === "speaker" ? theme.warn
                                  : (localSwitch.muted ? theme.bad : theme.line)
                    border.width: root.focused() === "speaker" ? 2 : 1

                    Row {
                        anchors.centerIn: parent
                        spacing: 6

                        Rectangle {
                            width: 26; height: 14; radius: 7
                            anchors.verticalCenter: parent.verticalCenter
                            color: localSwitch.muted ? theme.bad : "#3a4653"
                            Rectangle {
                                width: 10; height: 10; radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                x: localSwitch.muted ? parent.width - width - 2 : 2
                                color: "#ffffff"
                                Behavior on x { NumberAnimation { duration: 120 } }
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: localSwitch.muted ? "SPKR OFF" : "SPKR ON"
                            color: theme.text
                            font { family: theme.family; pixelSize: 11; bold: true }
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: root.focusOn("speaker")
                        onClicked: {
                            root.focusOn("speaker");
                            root.cmd("local", { muted: !localSwitch.muted });
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Device list
    // ---------------------------------------------------------------------
    Text {
        id: listHeading
        anchors { top: routeCard.bottom; topMargin: 12; left: parent.left; leftMargin: 14 }
        text: "DEVICES"
        color: theme.dim
        font { family: theme.family; pixelSize: 12; bold: true; letterSpacing: 2 }
    }

    // Scan button
    Rectangle {
        id: scanButton
        anchors { top: routeCard.bottom; topMargin: 6; right: parent.right; rightMargin: 12 }
        width: 108; height: 26; radius: 13
        color: root.scanning ? theme.accentDim : (scanHover.containsMouse ? theme.panelHi : theme.panel)
        border.color: root.focused() === "scan" ? theme.warn
                      : (root.scanning ? theme.accent : theme.line)
        border.width: root.focused() === "scan" ? 2 : 1

        Text {
            anchors.centerIn: parent
            text: root.scanning ? "SCANNING..." : "SCAN"
            color: root.scanning ? "#ffffff" : theme.text
            font { family: theme.family; pixelSize: 12; bold: true }
        }
        MouseArea {
            id: scanHover
            anchors.fill: parent
            hoverEnabled: true
            onEntered: root.focusOn("scan")
            onClicked: {
                root.focusOn("scan");
                root.toggleScan();
            }
        }
    }

    // Front-panel remap entry: walks the button/knob/button sequence without
    // leaving the screen (see openRemap).
    Rectangle {
        id: remapButton
        anchors { top: routeCard.bottom; topMargin: 6; right: scanButton.left; rightMargin: 8 }
        width: 96; height: 26; radius: 13
        color: root.remapOpen ? theme.warn
             : (remapHover.containsMouse ? theme.panelHi : theme.panel)
        border.color: root.focused() === "remap" ? theme.warn : theme.line
        border.width: root.focused() === "remap" ? 2 : 1

        Text {
            anchors.centerIn: parent
            text: "REMAP"
            color: root.remapOpen ? "#0b0f14" : theme.text
            font { family: theme.family; pixelSize: 12; bold: true }
        }
        MouseArea {
            id: remapHover
            anchors.fill: parent
            hoverEnabled: true
            onEntered: root.focusOn("remap")
            onClicked: {
                root.focusOn("remap");
                if (root.remapOpen)
                    root.closeRemap();
                else
                    root.openRemap();
            }
        }
    }

    ListView {
        id: deviceList
        anchors {
            top: listHeading.bottom; topMargin: 6
            left: parent.left; leftMargin: 10
            right: parent.right; rightMargin: 10
            bottom: footer.top; bottomMargin: 6
        }
        clip: true
        spacing: 6
        model: root.devices()
        currentIndex: root.deviceFocus
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
            id: row
            width: deviceList.width
            height: 54
            radius: 8
            color: (row.isSelected || mouse.containsMouse) ? theme.panelHi : theme.panel
            border.color: row.isSelected ? theme.warn
                        : (modelData.connected ? theme.accentDim : theme.line)
            border.width: row.isSelected ? 2 : 1
            opacity: modelData.audio ? 1.0 : 0.55

            readonly property bool isSelected: root.focusIsDevice(index)
            readonly property bool isTarget: root.isTarget(modelData)

            Behavior on color { ColorAnimation { duration: 100 } }

            MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                onEntered: root.focusOn("device:" + index)
                // Clicking the row body makes it the routing target.
                onClicked: {
                    root.focusOn("device:" + index);
                    if (modelData.connected)
                        root.cmd("route", { on: true, addr: modelData.addr });
                }
            }

            Row {
                anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                spacing: 10

                // Status dot
                Rectangle {
                    width: 8; height: 8; radius: 4
                    anchors.verticalCenter: parent.verticalCenter
                    color: modelData.connected ? theme.good
                         : (modelData.paired ? theme.dim : theme.line)
                }

                Column {
                    spacing: 1
                    anchors.verticalCenter: parent.verticalCenter
                    width: 300

                    Text {
                        width: parent.width
                        text: modelData.name
                        color: theme.text
                        elide: Text.ElideRight
                        font { family: theme.family; pixelSize: 14; bold: true }
                    }

                    Row {
                        spacing: 6
                        Text {
                            text: modelData.addr
                            color: theme.dim
                            font { family: "DejaVu Sans Mono"; pixelSize: 10 }
                        }
                        Text {
                            text: modelData.audio ? "AUDIO" : "NO AUDIO"
                            color: modelData.audio ? theme.accent : theme.dim
                            font { family: theme.family; pixelSize: 10; bold: true }
                        }
                        Text {
                            visible: modelData.rssi !== null && modelData.rssi !== undefined
                            text: modelData.rssi + " dBm"
                            color: theme.dim
                            font { family: theme.family; pixelSize: 10 }
                        }
                        Text {
                            visible: modelData.connected && modelData.ready
                            text: "AUDIO READY"
                            color: theme.good
                            font { family: theme.family; pixelSize: 10; bold: true }
                        }
                        Text {
                            visible: row.isTarget
                            text: "ROUTING TARGET"
                            color: theme.accent
                            font { family: theme.family; pixelSize: 10; bold: true }
                        }
                    }
                }
            }

            Row {
                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 8

                // Forget (paired devices only)
                Rectangle {
                    visible: modelData.paired
                    width: 60; height: 30; radius: 6
                    color: forgetHover.containsMouse ? "#3a2224" : theme.bg
                    border.color: theme.line; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "FORGET"
                        color: theme.bad
                        font { family: theme.family; pixelSize: 10; bold: true }
                    }
                    MouseArea {
                        id: forgetHover
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.cmd("forget", { addr: modelData.addr })
                    }
                }

                // Primary action
                Rectangle {
                    width: 108; height: 30; radius: 6
                    color: !modelData.audio && !modelData.connected ? theme.bg
                         : (modelData.connected ? theme.panelHi : theme.accentDim)
                    border.color: modelData.connected ? theme.line : theme.accent
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: root.primaryLabel(modelData)
                        color: theme.text
                        font { family: theme.family; pixelSize: 11; bold: true }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.primaryAction(modelData)
                    }
                }
            }
        }

        // Empty / offline states
        Text {
            anchors.centerIn: parent
            width: parent.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            visible: deviceList.count === 0
            text: !root.backendUp
                  ? "The BT Audio service is not answering.\nStart it with:  /usr/share/support/btaudio start"
                  : (root.scanning
                     ? "Scanning for nearby devices..."
                     : "No devices yet.  Press SCAN to look for headphones or speakers.")
            color: theme.dim
            font { family: theme.family; pixelSize: 13 }
        }
    }

    // Slim scroll indicator for the device list.  (Only the right edge is
    // anchored: QML forbids combining anchors.top with an explicit y.)
    Rectangle {
        visible: deviceList.contentHeight > deviceList.height + 2
        anchors { right: parent.right; rightMargin: 3 }
        width: 3
        radius: 2
        color: theme.line
        height: Math.max(20, deviceList.height * (deviceList.height / deviceList.contentHeight))
        y: deviceList.y + (deviceList.height - height)
           * (deviceList.contentY / Math.max(1, deviceList.contentHeight - deviceList.height))
    }

    // ---------------------------------------------------------------------
    // Toast + footer
    // ---------------------------------------------------------------------
    Rectangle {
        id: toast
        visible: root.banner !== ""
        anchors { horizontalCenter: parent.horizontalCenter; bottom: footer.top; bottomMargin: 10 }
        width: Math.min(parent.width - 40, toastText.width + 32)
        height: 34
        radius: 17
        color: root.bannerBad ? "#3a1d1d" : theme.panelHi
        border.color: root.bannerBad ? theme.bad : theme.accentDim
        border.width: 1

        Text {
            id: toastText
            anchors.centerIn: parent
            text: root.banner
            color: theme.text
            font { family: theme.family; pixelSize: 12 }
        }
    }

    Rectangle {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: 34
        color: theme.panel

        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 1
            color: theme.line
        }

        Text {
            anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
            // Built from what is actually bound, so the hint never promises a
            // control the radio does not have.
            text: {
                var k = (root.state && root.state.keys) ? root.state.keys : {};
                var parts = [];
                if (root.volumeLocked)
                    return "VOLUME: turn the knob    \u2022    select: release";
                if (root.state && root.state.rotary && root.state.rotary.device)
                    parts.push("knob: move");
                else if (k.up !== null && k.up !== undefined)
                    parts.push("up/down: move");
                if (k.select !== null && k.select !== undefined)
                    parts.push("select: use");
                else
                    parts.push("enter: use");
                if (k.back !== null && k.back !== undefined)
                    parts.push("back: close");
                parts.push("launch x3: close");
                return parts.join("    •    ");
            }
            color: theme.dim
            font { family: theme.family; pixelSize: 11 }
        }

        Text {
            anchors { right: parent.right; rightMargin: 14; verticalCenter: parent.verticalCenter }
            visible: adapter() && adapter().address !== ""
            text: "SOURCE " + (root.state ? root.state.source : "")
            color: theme.line
            font { family: "DejaVu Sans Mono"; pixelSize: 10 }
        }
    }

    // ---------------------------------------------------------------------
    // Remap overlay -- modal, drawn over the whole design stage
    // ---------------------------------------------------------------------
    // The front panel is captured by the backend while this is up, so the list
    // underneath is deliberately unreachable: pressing a button here is how a
    // binding is made, not how the list is walked.  SKIP / RESTART / CLOSE are
    // for when a mouse is handy; the mapped back button (or the launch gesture)
    // also leaves.
    Item {
        id: remapOverlay
        visible: root.remapOpen
        anchors.fill: parent
        z: 50

        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: 0.72
        }

        // Swallow clicks aimed at the list underneath.
        MouseArea { anchors.fill: parent }

        Rectangle {
            anchors.centerIn: parent
            width: 620
            height: 404
            radius: 10
            color: theme.panel
            border.color: root.remapDone ? theme.good : theme.warn
            border.width: 2

            Column {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 18 }
                spacing: 10

                Text {
                    text: root.remapDone ? "REMAP FRONT PANEL -- DONE"
                        : (root.remapPending() !== null ? "REMAP FRONT PANEL -- CONFIRM"
                                                        : "REMAP FRONT PANEL")
                    color: root.remapPending() !== null ? theme.warn : theme.text
                    font { family: theme.family; pixelSize: 19; bold: true; letterSpacing: 2 }
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: root.remapDone ? theme.good : theme.dim
                    text: {
                        if (root.remapDone)
                            return "Saved to /etc/btaudio.conf.  The buttons work straight away.";
                        if (root.remapPending() !== null)
                            return "Press that same button again to save it, or a different one "
                                 + "to change it.  Nothing is written until you do.";
                        var name = root.remapStepName();
                        if (name === "rotary")
                            return "Turn the knob you want to scroll the list with, a few clicks, then stop.";
                        if (name === "launch")
                            return "Press the button you want to OPEN and CLOSE this screen with.";
                        if (name === "select")
                            return "Press the button you want to SELECT with.";
                        return "";
                    }
                    font { family: theme.family; pixelSize: 14 }
                }

                // The keycode that just arrived.  Big and amber on purpose: this
                // is the moment a wrong button is meant to be spotted.
                Text {
                    visible: root.remapPending() !== null && !root.remapDone
                    text: root.remapPending() !== null
                          ? ("RECEIVED   " + root.remapPending()) : ""
                    color: theme.warn
                    font { family: "DejaVu Sans Mono"; pixelSize: 26; bold: true }
                }

                // The steps, in the order the backend asked for them.
                Column {
                    spacing: 6
                    width: parent.width

                    Repeater {
                        model: root.remapSteps()

                        Rectangle {
                            width: parent.width
                            height: 46
                            radius: 6
                            property bool current: root.remapOpen && !root.remapDone
                                                   && root.remapStep === index
                            property bool settled: root.remapDone || index < root.remapStep
                            color: current ? theme.panelHi : theme.bg
                            border.color: current ? theme.warn
                                        : (settled ? theme.accentDim : theme.line)
                            border.width: current ? 2 : 1

                            Text {
                                anchors { left: parent.left; leftMargin: 12
                                          verticalCenter: parent.verticalCenter }
                                text: (index + 1) + ".   " + root.remapStepTitle(modelData)
                                color: current ? theme.text : theme.dim
                                font { family: theme.family; pixelSize: 15; bold: current }
                            }

                            Text {
                                anchors { right: parent.right; rightMargin: 14
                                          verticalCenter: parent.verticalCenter }
                                text: {
                                    if (parent.current) {
                                        if (modelData === "rotary") {
                                            // A knob produces a device, not a
                                            // keycode, so name the one it found.
                                            var k = root.knob();
                                            if (k && k.learned)
                                                return "found " + k.learned;
                                            return (k && k.learning) ? "turn it now" : "waiting...";
                                        }
                                        var got = root.remapPending();
                                        return (got !== null) ? (got + "   confirm?") : "press it now";
                                    }
                                    return root.remapStepValue(modelData);
                                }
                                color: parent.current ? theme.warn : theme.good
                                font { family: "DejaVu Sans Mono"; pixelSize: 14; bold: true }
                            }
                        }
                    }
                }

                Row {
                    spacing: 8

                    Rectangle {
                        width: 92; height: 34; radius: 6
                        color: remapSkipHover.containsMouse ? theme.panelHi : theme.bg
                        border.color: theme.line; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "SKIP"
                            color: theme.text
                            font { family: theme.family; pixelSize: 12; bold: true }
                        }
                        MouseArea {
                            id: remapSkipHover
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.skipRemapStep()
                        }
                    }

                    Rectangle {
                        width: 108; height: 34; radius: 6
                        color: remapRestartHover.containsMouse ? theme.panelHi : theme.bg
                        border.color: theme.line; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "RESTART"
                            color: theme.text
                            font { family: theme.family; pixelSize: 12; bold: true }
                        }
                        MouseArea {
                            id: remapRestartHover
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.restartRemap()
                        }
                    }

                    Rectangle {
                        width: 92; height: 34; radius: 6
                        color: remapCloseHover.containsMouse ? theme.panelHi : theme.bg
                        border.color: theme.line; border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "CLOSE"
                            color: theme.text
                            font { family: theme.family; pixelSize: 12; bold: true }
                        }
                        MouseArea {
                            id: remapCloseHover
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.closeRemap()
                        }
                    }
                }

                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: theme.dim
                    text: "A button is saved on the second press, so a wrong one costs "
                         + "nothing.  SKIP leaves a step as it was; closing this panel "
                         + "un-arms whatever was still waiting."
                    font { family: theme.family; pixelSize: 11 }
                }
            }
        }
    }
    }   // </design stage>
}
