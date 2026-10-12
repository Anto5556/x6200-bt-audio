// Calibrate.qml -- pick the screen rotation for this panel.
//
// Normally there is nothing to pick: the screen turns its layout a quarter turn
// to suit the frame Qt hands it, and this panel needs the 270 one ("auto").  This
// screen is the escape hatch for a panel (or a future firmware) that disagrees:
// it opens showing exactly what the main screen currently does, and TRY NEXT
// turns it a quarter turn at a time until the arrow points to the top of the
// radio.  USE THIS saves that angle to /etc/btaudio.conf; USE AUTO goes back to
// deciding by the shape of the frame, which is what a healthy panel wants.

import QtQuick 2.12
import QtQuick.Window 2.12

Window {
    id: root

    width: Screen.width > 0 ? Screen.width : 480
    height: Screen.height > 0 ? Screen.height : 800
    visible: true
    color: "#0b0f14"
    title: "BT Audio orientation"

    readonly property string api: "http://127.0.0.1:8637"

    // Start from the angle the main screen would use right now, so the first
    // thing on the panel is the real screen's orientation rather than a guess.
    property int angle:
        (Screen.width > 0 && Screen.height > 0 && Screen.width < Screen.height) ? 270 : 0

    function adoptCurrent() {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", root.api + "/state");
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== 4 || xhr.status !== 200)
                return;
            try {
                var st = JSON.parse(xhr.responseText);
                if (st && st.rotation !== undefined && st.rotation !== null
                        && String(st.rotation) !== "auto")
                    root.angle = Number(st.rotation);
            } catch (e) {
                // Leave the choice above in place if the backend is not up yet.
            }
        };
        xhr.send();
    }

    function save(degrees) {
        var xhr = new XMLHttpRequest();
        xhr.open("POST", root.api + "/cmd");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify({ action: "rotation", degrees: degrees }));
        Qt.quit();
    }

    Component.onCompleted: adoptCurrent()

    // Same 800x480 design stage the main screen uses, so what you see here is
    // exactly how the real screen will sit.
    Item {
        id: stage
        width: 800
        height: 480
        anchors.centerIn: parent
        rotation: root.angle

        Rectangle {
            anchors.fill: parent
            color: "#0b0f14"
        }

        Column {
            anchors.centerIn: parent
            spacing: 4

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "\u25B2"
                color: "#39c6f2"
                font { family: "DejaVu Sans"; pixelSize: 150 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "TOP"
                color: "#e6edf3"
                font { family: "DejaVu Sans"; pixelSize: 44; bold: true; letterSpacing: 4 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "rotate until the arrow points to the top of the screen"
                color: "#8b98a5"
                font { family: "DejaVu Sans"; pixelSize: 16 }
            }
        }

        Text {
            anchors { top: parent.top; right: parent.right; topMargin: 18; rightMargin: 20 }
            text: root.angle + "\u00B0"
            color: "#39c6f2"
            font { family: "DejaVu Sans"; pixelSize: 30; bold: true }
        }

        Row {
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 26 }
            spacing: 18

            Rectangle {
                width: 200; height: 62; radius: 8
                color: "#1c2733"
                border.color: "#39c6f2"
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: "TRY NEXT"
                    color: "#e6edf3"
                    font { family: "DejaVu Sans"; pixelSize: 20; bold: true }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.angle = (root.angle + 90) % 360
                }
            }

            Rectangle {
                width: 200; height: 62; radius: 8
                color: "#1d6b85"
                border.color: "#39c6f2"
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: "USE THIS"
                    color: "#ffffff"
                    font { family: "DejaVu Sans"; pixelSize: 20; bold: true }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.save(root.angle)
                }
            }

            Rectangle {
                width: 168; height: 62; radius: 8
                color: "#1c2733"
                border.color: "#26333f"
                border.width: 1
                Text {
                    anchors.centerIn: parent
                    text: "USE AUTO"
                    color: "#e6edf3"
                    font { family: "DejaVu Sans"; pixelSize: 20; bold: true }
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: root.save("auto")
                }
            }
        }
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: {
            if (event.key === Qt.Key_Escape) {
                Qt.quit();
                event.accepted = true;
            } else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return) {
                root.angle = (root.angle + 90) % 360;
                event.accepted = true;
            }
        }
    }
}
