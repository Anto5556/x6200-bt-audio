// KeyMap.qml -- map the radio's front panel onto the BT Audio screen.
//
// Two phases, both driven from the panel itself:
//
//   1. Buttons.  The screen asks for one button per navigation role (UP, DOWN,
//      SELECT, BACK) and the backend records the keycode it sees, writing each
//      one into /etc/btaudio.conf as it goes -- so a run cut short keeps what it
//      already captured.  The launch button is never captured: it stays the way
//      in and out of the screen.
//
//   2. Knob.  The screen then asks for the knob to scroll the list with: turn it
//      a few clicks and the backend reports which of the radio's encoders moved
//      (rotary@0..3, each a separate input device).  FLIP swaps the direction if
//      clockwise scrolls the wrong way.
//
// All of it works without a mouse.  SKIP / RESTART / CLEAR / FLIP / CLOSE are
// there for when one is handy, and three quick presses of the launch button
// close the screen at any point.
//
// Start it with:  /usr/share/support/btaudio keymap

import QtQuick 2.12
import QtQuick.Window 2.12

Window {
    id: root

    // Same trick as the main screen: the launcher hands over the panel's own
    // 480x800 frame and the 800x480 design is turned into it (see BtAudio.qml).
    readonly property int designWidth: 800
    readonly property int designHeight: 480
    readonly property int autoRotation:
        (Screen.width > 0 && Screen.height > 0 && Screen.width < Screen.height) ? 270 : 0
    readonly property var storedRotation:
        (state && state.rotation !== undefined && state.rotation !== null
         && String(state.rotation) !== "auto") ? Number(state.rotation) : null
    readonly property int contentRotation:
        storedRotation !== null ? storedRotation : autoRotation

    width: Screen.width > 0 ? Screen.width : 480
    height: Screen.height > 0 ? Screen.height : 800
    visible: true
    color: theme.bg
    title: "BT Audio button map"

    readonly property string api: "http://127.0.0.1:8637"
    property var state: null
    property bool backendUp: false

    // Phase 2 starts once the four button roles are answered.
    property bool knobPhase: false
    property bool knobSettled: false

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
        readonly property color bad: "#f85149"
        readonly property string family: "DejaVu Sans"
    }

    function km() { return (root.state && root.state.keymap) ? root.state.keymap : null; }
    function knob() { return (root.state && root.state.rotary) ? root.state.rotary : null; }
    function roles() {
        var k = km();
        return (k && k.roles) ? k.roles : ["up", "down", "select", "back"];
    }
    function stepRole() {
        var k = km();
        if (!k || !k.active)
            return null;
        var list = roles();
        return (k.step < list.length) ? list[k.step] : null;
    }
    function boundCode(role) {
        var k = km();
        var b = k ? k.bound : null;
        if (b && b[role] !== undefined && b[role] !== null)
            return String(b[role]);
        return "--";
    }
    function justCaptured(role) {
        var k = km();
        var c = k ? k.codes : null;
        if (c && c[role] !== undefined && c[role] !== null)
            return String(c[role]);
        return null;
    }
    function buttonsDone() {
        var k = km();
        return !!(k && !k.active && k.step >= roles().length);
    }

    // ---------------------------------------------------------------- backend
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
                    root.advancePhases();
                } catch (e) {
                    root.backendUp = false;
                }
            } else {
                root.backendUp = false;
            }
        };
        xhr.send();
    }

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

    // Buttons answered -> ask for the knob.  Knob turned -> save it, no button
    // press needed.  Then the screen has nothing left to do and closes itself.
    function advancePhases() {
        if (!root.backendUp)
            return;
        if (root.buttonsDone() && !root.knobPhase) {
            root.knobPhase = true;
            root.post({ action: "rotary", cmd: "learn" });
            return;
        }
        if (root.knobPhase && !root.knobSettled) {
            var r = root.knob();
            if (r && r.learned) {
                root.knobSettled = true;
                root.post({ action: "rotary", cmd: "apply" });
            }
            return;
        }
        // Start once: restarting it every poll would mean it never fires.
        if (root.knobPhase && root.knobSettled && !doneTimer.running)
            doneTimer.start();
    }

    function settleKnob(cmd) {
        root.knobSettled = true;
        root.post(cmd);
    }

    Component.onCompleted: {
        console.log("bt audio: front-panel mapping, logical screen " + Screen.width
                    + "x" + Screen.height + ", content rotation " + root.contentRotation);
        fetchState();
        post({ action: "keymap", cmd: "start" });
    }

    Timer {
        interval: 400
        running: true
        repeat: true
        onTriggered: root.fetchState()
    }

    // Both phases done: show the result for a moment, then hand the panel back.
    Timer {
        id: doneTimer
        interval: 8000
        onTriggered: Qt.quit()
    }

    // Any keyboard key this screen does not use closes it, so a half-finished
    // run can never trap the panel.
    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: {
            if (event.key === Qt.Key_Escape || event.key === Qt.Key_Backspace
                    || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                Qt.quit();
                event.accepted = true;
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: theme.bg
    }

    // ---------------------------------------------------------------------
    // Design stage (800x480, turned into the panel's frame)
    // ---------------------------------------------------------------------
    Item {
        id: stage
        width: root.designWidth
        height: root.designHeight
        anchors.centerIn: parent
        rotation: root.contentRotation

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
                text: root.knobPhase ? "SCROLL KNOB" : "FRONT-PANEL BUTTONS"
                color: theme.text
                font { family: theme.family; pixelSize: 21; bold: true; letterSpacing: 2 }
            }

            Rectangle {
                width: 84; height: 28; radius: 14
                anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                color: closeHover.containsMouse ? theme.panelHi : theme.bg
                border.color: theme.line; border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: "CLOSE"
                    color: theme.text
                    font { family: theme.family; pixelSize: 12; bold: true }
                }
                MouseArea {
                    id: closeHover
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: Qt.quit()
                }
            }
        }

        // What to do right now
        Rectangle {
            id: ask
            anchors { top: header.bottom; left: parent.left; right: parent.right; margins: 10 }
            height: 92
            radius: 8
            color: theme.panel
            border.color: root.knobSettled ? theme.good : theme.accentDim
            border.width: 1

            Text {
                anchors { left: parent.left; leftMargin: 18; right: parent.right; rightMargin: 18
                          verticalCenter: parent.verticalCenter }
                wrapMode: Text.WordWrap
                color: root.knobSettled ? theme.good : theme.text
                text: {
                    if (!root.backendUp)
                        return "The audio service is not answering -- start it with:\n"
                               + "/usr/share/support/btaudio daemon start";
                    var k = root.km();
                    var r = root.knob();
                    if (!k)
                        return "Starting the mapper...";
                    if (!root.knobPhase)
                        return k.message + (k.active ? "" : "   (next: the scroll knob)");
                    if (root.knobSettled)
                        return r && r.device ? ("Saved -- scrolling with " + r.device)
                                             : "No scroll knob set.";
                    if (r && r.learned)
                        return "Knob found: " + r.learned + "   (saving...)";
                    return "Turn the knob you want to scroll the list with,\na few clicks, then stop.";
                }
                font { family: theme.family;
                       pixelSize: (root.knobPhase && !root.knobSettled) ? 20 : 21; bold: true }
            }
        }

        // ---- phase 1: the four roles -------------------------------------
        Column {
            id: rows
            visible: !root.knobPhase
            anchors { top: ask.bottom; topMargin: 12; left: parent.left; leftMargin: 14 }
            spacing: 6
            width: 420

            Repeater {
                model: root.roles()

                Rectangle {
                    width: rows.width
                    height: 46
                    radius: 6
                    property bool current: root.stepRole() === modelData
                    property bool captured: root.justCaptured(modelData) !== null
                    color: current ? theme.panelHi : theme.panel
                    border.color: current ? theme.accent
                                : (captured ? theme.accentDim : theme.line)
                    border.width: 1

                    Text {
                        anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                        text: modelData.toUpperCase()
                        color: theme.text
                        font { family: theme.family; pixelSize: 17; bold: true; letterSpacing: 1 }
                    }

                    Text {
                        anchors { right: code.left; rightMargin: 14; verticalCenter: parent.verticalCenter }
                        visible: parent.current
                        text: "\u25C0 press a button now"
                        color: theme.accent
                        font { family: theme.family; pixelSize: 12 }
                    }

                    Text {
                        id: code
                        anchors { right: parent.right; rightMargin: 16; verticalCenter: parent.verticalCenter }
                        text: root.boundCode(modelData)
                        color: root.boundCode(modelData) === "--" ? theme.dim : theme.good
                        font { family: "DejaVu Sans Mono"; pixelSize: 16; bold: true }
                    }
                }
            }
        }

        // ---- phase 2: the knob ------------------------------------------
        Rectangle {
            id: knobCard
            visible: root.knobPhase
            anchors { top: ask.bottom; topMargin: 12; left: parent.left; leftMargin: 14 }
            width: 420
            height: 118
            radius: 8
            color: theme.panel
            border.color: theme.line
            border.width: 1

            Text {
                id: knobTitle
                anchors { left: parent.left; leftMargin: 14; top: parent.top; topMargin: 12 }
                text: "SCROLL KNOB"
                color: theme.dim
                font { family: theme.family; pixelSize: 12; bold: true; letterSpacing: 2 }
            }

            Text {
                anchors { left: parent.left; leftMargin: 14; right: parent.right; rightMargin: 14
                          top: knobTitle.bottom; topMargin: 6 }
                wrapMode: Text.WordWrap
                color: theme.text
                text: {
                    var r = root.knob();
                    if (root.knobSettled)
                        return r && r.device ? (r.device + "   axis " + (r.axis === null ? "-" : r.axis))
                                             : "none -- the buttons still work";
                    if (r && r.learned)
                        return r.learned;
                    if (r && r.device)
                        return "currently " + r.device + "\nturn the knob to change it";
                    return "waiting for a knob to move...";
                }
                font { family: "DejaVu Sans Mono"; pixelSize: 13 }
            }

            Text {
                anchors { left: parent.left; leftMargin: 14; bottom: parent.bottom; bottomMargin: 10 }
                text: "clockwise scrolls down; use FLIP if it feels backwards"
                color: theme.dim
                font { family: theme.family; pixelSize: 11 }
            }
        }

        // Notes and mouse controls
        Column {
            anchors { top: ask.bottom; topMargin: 14; left: rows.right; leftMargin: 18
                      right: parent.right; rightMargin: 14 }
            spacing: 8

            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: {
                    if (root.knobPhase)
                        return "The knob is read passively, so the radio keeps its "
                             + "knobs whenever this screen is not up.\n\n"
                             + "Launch button three times quickly closes this screen.";
                    return "Press the button you want for the role shown in blue.\n\n"
                         + "The launch button is kept for opening and closing this "
                         + "screen: press it three times quickly to leave.";
                }
                color: theme.dim
                font { family: theme.family; pixelSize: 12 }
            }

            Row {
                spacing: 8

                // Phase 1 controls
                Rectangle {
                    visible: !root.knobPhase
                    width: 92; height: 34; radius: 6
                    color: theme.panelHi
                    border.color: theme.line; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "SKIP"
                        color: theme.text
                        font { family: theme.family; pixelSize: 12; bold: true }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.post({ action: "keymap", cmd: "skip" }) }
                }

                Rectangle {
                    visible: !root.knobPhase
                    width: 108; height: 34; radius: 6
                    color: theme.panelHi
                    border.color: theme.line; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "RESTART"
                        color: theme.text
                        font { family: theme.family; pixelSize: 12; bold: true }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            root.knobPhase = false;
                            root.knobSettled = false;
                            root.post({ action: "keymap", cmd: "restart" });
                        }
                    }
                }

                Rectangle {
                    visible: !root.knobPhase
                    width: 92; height: 34; radius: 6
                    color: theme.panelHi
                    border.color: theme.bad; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "CLEAR"
                        color: theme.bad
                        font { family: theme.family; pixelSize: 12; bold: true }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.post({ action: "keymap", cmd: "clear" })
                    }
                }

                // Phase 2 controls
                Rectangle {
                    visible: root.knobPhase && !root.knobSettled
                    width: 104; height: 34; radius: 6
                    color: theme.panelHi
                    border.color: theme.line; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "NO KNOB"
                        color: theme.text
                        font { family: theme.family; pixelSize: 12; bold: true }
                    }
                    MouseArea { anchors.fill: parent; onClicked: root.settleKnob("clear") }
                }

                Rectangle {
                    visible: root.knobSettled
                    width: 108; height: 34; radius: 6
                    color: theme.panelHi
                    border.color: theme.line; border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "FLIP"
                        color: theme.text
                        font { family: theme.family; pixelSize: 12; bold: true }
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            var r = root.knob();
                            root.post({ action: "rotary", cmd: "invert",
                                        invert: !(r && r.invert) });
                            // Give yourself time to change your mind again.
                            doneTimer.restart();
                        }
                    }
                }
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
                text: "SAVED AS YOU GO  •  /etc/btaudio.conf"
                color: theme.dim
                font { family: theme.family; pixelSize: 11 }
            }
        }
    }
}
