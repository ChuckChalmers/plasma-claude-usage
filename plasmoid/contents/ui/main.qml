import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.plasma.plasmoid 2.0
import org.kde.plasma.core 2.0 as PlasmaCore
import Qt.labs.platform 1.1 as Platform
import "staleness.js" as Staleness
import "attention.js" as Attention

Item {
    id: root

    // Always show the bars in the panel (not a collapsed icon).
    Plasmoid.preferredRepresentation: Plasmoid.fullRepresentation

    readonly property string cacheUrl:
        Platform.StandardPaths.writableLocation(Platform.StandardPaths.HomeLocation)
        + "/.claude/usage_cache.json"

    // Last-good raw windows from the cache; null until the first successful read.
    property var fiveHour: null
    property var sevenDay: null

    // Bumped every tick so the staleness bindings re-evaluate as time passes,
    // dropping a bar to 0% once its reset time is reached — even with no new
    // cache write. Epoch seconds, to match resets_at.
    property double nowSec: 0

    readonly property int fivePct: fiveHour ? Staleness.displayedPercent(fiveHour, nowSec) : 0
    readonly property int sevenPct: sevenDay ? Staleness.displayedPercent(sevenDay, nowSec) : 0

    // Sessions waiting on you, from the attention tracker (see attention/).
    readonly property string attentionCmd: "bash \"$HOME/.claude/attention.sh\" list"
    property var badge: Attention.badgeFor(null)

    Plasmoid.toolTipMainText: badge.count ? "Claude Code: waiting on you" : "Claude Code"
    Plasmoid.toolTipSubText: badge.tooltip || "No sessions waiting"

    // The executable engine runs a command once per connect, so the timer
    // reconnects it each tick and onNewData disconnects it again.
    PlasmaCore.DataSource {
        id: attentionSource
        engine: "executable"
        onNewData: {
            disconnectSource(sourceName);
            if (data["exit code"] !== 0)
                return;
            try {
                root.badge = Attention.badgeFor(JSON.parse(data.stdout));
            } catch (e) {
                // Unparseable output: keep the last badge.
            }
        }
    }

    function refresh() {
        nowSec = Date.now() / 1000;

        var xhr = new XMLHttpRequest();
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;
            // Local file reads report status 0 on success.
            if (xhr.status === 200 || xhr.status === 0) {
                try {
                    var data = JSON.parse(xhr.responseText);
                    if (data.five_hour) root.fiveHour = data.five_hour;
                    if (data.seven_day) root.sevenDay = data.seven_day;
                } catch (e) {
                    // Parse failure (e.g. rare mid-write read): keep last-good.
                }
            }
        };
        xhr.open("GET", cacheUrl);
        xhr.send();
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            root.refresh();
            attentionSource.connectSource(root.attentionCmd);
        }
    }

    Plasmoid.fullRepresentation: Item {
        // Force a real width in the panel; otherwise the layout shrinks to the
        // text and the fill-width bars collapse to zero and disappear.
        implicitWidth: 188
        implicitHeight: 40
        Layout.minimumWidth: 188
        Layout.preferredWidth: 188

        // Space stays reserved when hidden so the bars never shift.
        AttentionBadge {
            id: attentionBadge
            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            level: root.badge.level
            count: root.badge.count
        }

        ColumnLayout {
            // Anchor sides for width/padding, but center vertically so the two
            // rows get balanced top/bottom breathing room in the panel.
            anchors.left: attentionBadge.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: 4
            anchors.rightMargin: 12
            spacing: 5

            UsageRow { Layout.fillWidth: true; label: "5h"; pct: root.fivePct }
            UsageRow { Layout.fillWidth: true; label: "7d"; pct: root.sevenPct }
        }
    }
}
