import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.components 3.0 as PlasmaComponents
import org.kde.plasma.core 2.0 as PlasmaCore

// Tooltip body: the title, then each waiting session on its own row under
// "Blocked" or "Done". Clicking a row emits picked(session).
Item {
    id: list

    property var badge
    signal picked(string session)

    readonly property int margin: PlasmaCore.Units.smallSpacing * 2

    implicitWidth: column.implicitWidth + margin * 2
    implicitHeight: column.implicitHeight + margin * 2
    // The tooltip window follows these, so it resizes as rows come and go.
    width: implicitWidth
    height: implicitHeight
    Layout.minimumWidth: implicitWidth
    Layout.minimumHeight: implicitHeight
    Layout.maximumWidth: implicitWidth
    Layout.maximumHeight: implicitHeight

    ColumnLayout {
        id: column
        anchors.fill: parent
        anchors.margins: list.margin
        spacing: PlasmaCore.Units.smallSpacing

        PlasmaComponents.Label {
            text: list.badge.title
            font.bold: true
        }

        Repeater {
            model: list.badge.groups

            delegate: ColumnLayout {
                readonly property bool blocked: modelData.label === "Blocked"
                spacing: 0
                Layout.topMargin: PlasmaCore.Units.smallSpacing

                PlasmaComponents.Label {
                    text: modelData.label
                    opacity: 0.7
                    font.pixelSize: 11
                }

                Repeater {
                    model: modelData.sessions

                    delegate: Rectangle {
                        Layout.fillWidth: true
                        Layout.minimumWidth: row.implicitWidth + 12
                        implicitHeight: row.implicitHeight + 6
                        radius: 3
                        color: hover.containsMouse ? Qt.rgba(1, 1, 1, 0.1) : "transparent"

                        RowLayout {
                            id: row
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 6
                            spacing: 6

                            Rectangle {
                                width: 8
                                height: 8
                                radius: 4
                                color: blocked ? "#F59F00" : "#8A8F98"
                                opacity: blocked ? 1 : 0.55
                            }

                            PlasmaComponents.Label {
                                text: modelData.project
                            }
                        }

                        MouseArea {
                            id: hover
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: list.picked(modelData.session)
                        }
                    }
                }
            }
        }
    }
}
