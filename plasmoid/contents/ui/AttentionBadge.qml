import QtQuick 2.15

// Dot showing Claude Code sessions waiting on you: amber when one is blocked on
// a prompt or question, blue when sessions have only finished their turn. A
// count appears once more than one session is waiting.
Item {
    id: badge

    property string level: "none"   // "none" | "turn" | "blocked"
    property int count: 0

    property color blockedAmber: "#F59F00"
    property color turnBlue: "#4C8DFF"

    implicitWidth: 16
    implicitHeight: 16

    Rectangle {
        anchors.centerIn: parent
        width: badge.count > 1 ? 16 : 10
        height: width
        radius: width / 2
        visible: badge.level !== "none"
        color: badge.level === "blocked" ? badge.blockedAmber : badge.turnBlue

        Text {
            anchors.centerIn: parent
            visible: badge.count > 1
            text: badge.count
            color: "#1B1B1B"
            font.pixelSize: 10
            font.bold: true
        }
    }
}
