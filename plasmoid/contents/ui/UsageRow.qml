import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.components 3.0 as PlasmaComponents

// One usage row: "5h" label · pill bar · "62%" value.
RowLayout {
    id: row

    property string label: ""
    property int pct: 0

    property color orange: "#D97757"     // Claude orange
    property color maxedRed: "#E03131"   // maxed-out indicator
    property color track: Qt.rgba(1, 1, 1, 0.13)

    spacing: 6

    PlasmaComponents.Label {
        text: row.label
        font.pixelSize: 12
        opacity: 0.85
        Layout.preferredWidth: 18
    }

    // Pill track
    Rectangle {
        Layout.fillWidth: true
        Layout.minimumWidth: 50
        Layout.preferredHeight: 6
        radius: height / 2
        color: row.track

        // Fill
        Rectangle {
            width: parent.width * Math.max(0, Math.min(row.pct, 100)) / 100
            height: parent.height
            radius: height / 2
            color: row.pct >= 100 ? row.maxedRed : row.orange

            Behavior on width {
                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
            }
        }
    }

    PlasmaComponents.Label {
        text: row.pct + "%"
        font.pixelSize: 12
        horizontalAlignment: Text.AlignRight
        Layout.preferredWidth: 30
    }
}
