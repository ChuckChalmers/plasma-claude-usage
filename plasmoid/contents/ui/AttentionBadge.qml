import QtQuick 2.15

// Dot showing Claude Code sessions waiting on you: amber when one is blocked on
// a prompt or question, faded gray when sessions have only finished. A count
// appears once more than one session is waiting.
Item {
    id: badge

    property string level: "none"   // "none" | "turn" | "blocked"
    property int count: 0

    readonly property bool blocked: level === "blocked"

    property color blockedAmber: "#F59F00"
    property color doneGray: "#8A8F98"

    implicitWidth: 18
    implicitHeight: 18

    Rectangle {
        anchors.centerIn: parent
        width: badge.count > 1 ? 18 : 14
        height: width
        radius: width / 2
        visible: badge.level !== "none"
        color: badge.blocked ? badge.blockedAmber : badge.doneGray
        opacity: badge.blocked ? 1 : 0.55

        Text {
            anchors.centerIn: parent
            visible: badge.count > 1
            text: badge.count
            color: badge.blocked ? "#1B1B1B" : "#FFFFFF"
            font.pixelSize: 11
            font.bold: true
        }
    }
}
