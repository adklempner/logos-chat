import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ApplicationWindow {
    id: root
    visible: true
    width: 1200
    height: 800
    color: "#0A0A0A"

    title: {
        var parts = ["RLN Gifter Demo"]
        if (monitor.marker1Active) parts.push("(1)✓")
        if (monitor.marker2Active) parts.push("(2)✓")
        if (monitor.marker3Active) parts.push("(3)✓")
        if (monitor.blockId > 0) parts.push("block " + monitor.blockId)
        return parts.join(" — ")
    }

    readonly property color bgPrimary:   "#0A0A0A"
    readonly property color bgSecondary: "#111111"
    readonly property color bgPanel:     "#161616"
    readonly property color border:      "#2a2a2a"
    readonly property color textPrimary: "#FAFAFA"
    readonly property color textSecond:  "#6B7280"
    readonly property color textTertiary:"#4B5563"
    readonly property color accent:      "#10B981"
    readonly property color accentDim:   "#065F46"
    readonly property color yellow:      "#F59E0B"
    readonly property color red:         "#EF4444"
    readonly property color blue:        "#2563EB"

    readonly property string monoFont: "JetBrains Mono, Menlo, Monaco, monospace"

    function nodeColor(jsonStr, idx) {
        try {
            var nodes = JSON.parse(jsonStr)
            var n = nodes[idx]
            if (n.lez && n.kad) return accent
            if (n.mounted) return yellow
        } catch(e) {}
        return textTertiary
    }

    function nodeRoots(idx) {
        try {
            var arr = JSON.parse(monitor.nodeRootsInfo)
            return arr[idx].roots
        } catch(e) { return 0 }
    }

    function nodeProofs(idx) {
        try {
            var arr = JSON.parse(monitor.marker3NodeCounts)
            return arr[idx].proofs
        } catch(e) { return 0 }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 10
        spacing: 8

        // ═══════════════════════════════════════════════════
        // ZONE 1: TOPOLOGY PANE
        // ═══════════════════════════════════════════════════
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 150
            color: bgSecondary
            radius: 8

            property int activeEdge: -1

            SequentialAnimation {
                id: edgePulse
                loops: 1
                PropertyAction { target: topologyRect; property: "activeEdge"; value: 0 }
                PauseAnimation { duration: 200 }
                PropertyAction { target: topologyRect; property: "activeEdge"; value: 1 }
                PauseAnimation { duration: 200 }
                PropertyAction { target: topologyRect; property: "activeEdge"; value: 2 }
                PauseAnimation { duration: 200 }
                PropertyAction { target: topologyRect; property: "activeEdge"; value: 3 }
                PauseAnimation { duration: 200 }
                PropertyAction { target: topologyRect; property: "activeEdge"; value: -1 }
            }

            id: topologyRect
            property bool _marker3Seen: false

            RowLayout {
                anchors.centerIn: parent
                spacing: 0

                // Sender icon
                Column {
                    spacing: 3
                    Rectangle {
                        width: 32; height: 32; radius: 16
                        color: monitor.senderPhase !== "---" ? root.accent : root.textTertiary
                        border.color: Qt.lighter(color, 1.3); border.width: 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        Text { anchors.centerIn: parent; font.family: root.monoFont; font.pixelSize: 12; font.bold: true; color: "#000"; text: "S" }
                    }
                    Text { font.family: root.monoFont; font.pixelSize: 8; color: root.textTertiary; text: "sender"; anchors.horizontalCenter: parent.horizontalCenter }
                }

                // Edge: sender → N0
                Rectangle {
                    width: 30; height: 3; radius: 1
                    color: topologyRect.activeEdge === 0 ? root.accent : root.border
                    Layout.alignment: Qt.AlignVCenter
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                // Mix nodes
                Repeater {
                    model: 4
                    Row {
                        spacing: 0
                        Column {
                            spacing: 2

                            Rectangle {
                                width: 48; height: 48; radius: 24
                                color: nodeColor(monitor.mixNodeStates, index)
                                border.color: Qt.lighter(nodeColor(monitor.mixNodeStates, index), 1.3); border.width: 2
                                anchors.horizontalCenter: parent.horizontalCenter

                                Text { anchors.centerIn: parent; font.family: root.monoFont; font.pixelSize: 14; font.bold: true; color: "#000"; text: "N" + index }
                            }

                            // Role badge
                            Rectangle {
                                visible: index === 0
                                width: gLbl.implicitWidth + 8; height: 14; radius: 4
                                color: monitor.gifterMounted ? root.accent : root.textTertiary
                                anchors.horizontalCenter: parent.horizontalCenter
                                Text { id: gLbl; anchors.centerIn: parent; font.family: root.monoFont; font.pixelSize: 7; font.bold: true; color: "#000"; text: "GIFTER" }
                            }
                            Text { visible: index !== 0; font.family: root.monoFont; font.pixelSize: 7; color: root.textTertiary; text: "relay"; anchors.horizontalCenter: parent.horizontalCenter }

                            // Leaf + roots info
                            Text {
                                font.family: root.monoFont; font.pixelSize: 8; color: root.textSecond
                                text: "roots:" + nodeRoots(index) + (nodeProofs(index) > 0 ? " pf:" + nodeProofs(index) : "")
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }

                        // Edge between nodes (not after last)
                        Rectangle {
                            visible: index < 3
                            width: 20; height: 3; radius: 1
                            color: topologyRect.activeEdge === (index + 1) ? root.accent : root.border
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }
                    }
                }

                // Edge: N3 → receiver
                Rectangle {
                    width: 30; height: 3; radius: 1
                    color: topologyRect.activeEdge === 3 ? root.accent : root.border
                    Layout.alignment: Qt.AlignVCenter
                    Behavior on color { ColorAnimation { duration: 150 } }
                }

                // Receiver icon
                Column {
                    spacing: 3
                    Rectangle {
                        width: 32; height: 32; radius: 16
                        color: monitor.senderPhase !== "---" ? root.blue : root.textTertiary
                        border.color: Qt.lighter(color, 1.3); border.width: 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        Text { anchors.centerIn: parent; font.family: root.monoFont; font.pixelSize: 12; font.bold: true; color: "#FFF"; text: "R" }
                    }
                    Text { font.family: root.monoFont; font.pixelSize: 8; color: root.textTertiary; text: "receiver"; anchors.horizontalCenter: parent.horizontalCenter }
                }
            }
        }

        // ═══════════════════════════════════════════════════
        // ZONE 2: MARKER TIMELINE
        // ═══════════════════════════════════════════════════
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 8

            // ── MARKER 1: Gifter Received Request ──
            Rectangle {
                id: m1Card
                Layout.fillWidth: true
                Layout.preferredHeight: m1Content.implicitHeight + 20
                color: bgPanel
                radius: 8
                border.color: monitor.marker1Active ? root.accent : root.border
                border.width: monitor.marker1Active ? 1 : 0

                property bool expanded: false

                RowLayout {
                    id: m1Content
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 12

                    // Checkbox
                    Rectangle {
                        id: m1Check
                        width: 36; height: 36; radius: 6
                        color: monitor.marker1Active ? root.accent : "transparent"
                        border.color: monitor.marker1Active ? root.accent : root.border
                        border.width: 2
                        Layout.alignment: Qt.AlignTop

                        Text { anchors.centerIn: parent; font.pixelSize: 18; color: "#FFF"; text: monitor.marker1Active ? "✓" : ""; font.bold: true }

                        SequentialAnimation on scale {
                            id: m1Bounce; loops: 1
                            NumberAnimation { to: 1.3; duration: 100 }
                            NumberAnimation { to: 1.0; duration: 200 }
                        }
                        property bool _prev: false
                        Connections {
                            target: monitor
                            function onStateChanged() {
                                if (monitor.marker1Active && !m1Check._prev) { m1Bounce.restart(); m1Check._prev = true }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        // Title
                        RowLayout {
                            spacing: 8
                            Text { font.family: root.monoFont; font.pixelSize: 14; font.bold: true; color: root.accent; text: "(1)" }
                            Text { font.family: root.monoFont; font.pixelSize: 13; font.bold: true; color: root.textPrimary; text: "GIFTER RECEIVED REQUEST" }
                            Item { Layout.fillWidth: true }
                            Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textTertiary
                                text: monitor.marker1Active ? monitor.marker1Timestamp : "" }
                        }

                        // Detail fields
                        Flow {
                            visible: monitor.marker1Active
                            Layout.fillWidth: true
                            spacing: 16

                            Row {
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "requestId:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.accent; text: monitor.marker1RequestId }
                            }
                            Row {
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "peerId:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.yellow; text: monitor.marker1PeerId || "---" }
                            }
                            Row {
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "idCommitment:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.blue; text: monitor.marker1IdCommitment || "---" }
                            }
                        }

                        // Raw log (expandable)
                        Text {
                            visible: monitor.marker1Active
                            font.family: root.monoFont; font.pixelSize: 9; color: root.textTertiary
                            text: m1Card.expanded ? monitor.marker1RawLine : "▸ raw log"
                            wrapMode: m1Card.expanded ? Text.WrapAnywhere : Text.NoWrap
                            Layout.fillWidth: true
                            elide: m1Card.expanded ? Text.ElideNone : Text.ElideRight

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: m1Card.expanded = !m1Card.expanded
                            }
                        }
                    }
                }
            }

            // ── MARKER 2: Membership Granted ──
            Rectangle {
                id: m2Card
                Layout.fillWidth: true
                Layout.preferredHeight: m2Content.implicitHeight + 20
                color: bgPanel
                radius: 8
                border.color: monitor.marker2Active ? root.accent : root.border
                border.width: monitor.marker2Active ? 1 : 0

                property bool expanded: false

                RowLayout {
                    id: m2Content
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 12

                    Rectangle {
                        id: m2Check
                        width: 36; height: 36; radius: 6
                        color: monitor.marker2Active ? root.accent : "transparent"
                        border.color: monitor.marker2Active ? root.accent : root.border
                        border.width: 2
                        Layout.alignment: Qt.AlignTop

                        Text { anchors.centerIn: parent; font.pixelSize: 18; color: "#FFF"; text: monitor.marker2Active ? "✓" : ""; font.bold: true }

                        SequentialAnimation on scale {
                            id: m2Bounce; loops: 1
                            NumberAnimation { to: 1.3; duration: 100 }
                            NumberAnimation { to: 1.0; duration: 200 }
                        }
                        property bool _prev: false
                        Connections {
                            target: monitor
                            function onStateChanged() {
                                if (monitor.marker2Active && !m2Check._prev) { m2Bounce.restart(); m2Check._prev = true }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        RowLayout {
                            spacing: 8
                            Text { font.family: root.monoFont; font.pixelSize: 14; font.bold: true; color: root.accent; text: "(2)" }
                            Text { font.family: root.monoFont; font.pixelSize: 13; font.bold: true; color: root.textPrimary; text: "MEMBERSHIP GRANTED" }
                            Item { Layout.fillWidth: true }
                            Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textTertiary
                                text: monitor.marker2Confirmed ? "confirmed in " + Math.round(monitor.marker2ElapsedSecs) + "s" : (monitor.marker2Active ? "awaiting confirmation..." : "") }
                        }

                        Flow {
                            visible: monitor.marker2Active
                            Layout.fillWidth: true
                            spacing: 16

                            Row {
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "leafIndex:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.accent; text: String(monitor.marker2LeafIndex) }
                            }
                            Row {
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "requestId:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.yellow; text: monitor.marker2RequestId || "---" }
                            }
                            Row {
                                visible: monitor.marker2Confirmed
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "on-chain:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.accent; text: "✓ confirmed" }
                            }
                        }

                        Text {
                            visible: monitor.marker2Active
                            font.family: root.monoFont; font.pixelSize: 9; color: root.textTertiary
                            text: m2Card.expanded ? monitor.marker2RawLine : "▸ raw log"
                            wrapMode: m2Card.expanded ? Text.WrapAnywhere : Text.NoWrap
                            Layout.fillWidth: true
                            elide: m2Card.expanded ? Text.ElideNone : Text.ElideRight

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: m2Card.expanded = !m2Card.expanded
                            }
                        }
                    }
                }
            }

            // ── MARKER 3: Proof Verified by Another Node ──
            Rectangle {
                id: m3Card
                Layout.fillWidth: true
                Layout.preferredHeight: m3Content.implicitHeight + 20
                color: bgPanel
                radius: 8
                border.color: monitor.marker3Active ? root.accent : root.border
                border.width: monitor.marker3Active ? 1 : 0

                property bool expanded: false

                RowLayout {
                    id: m3Content
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 12

                    Rectangle {
                        id: m3Check
                        width: 36; height: 36; radius: 6
                        color: monitor.marker3Active ? root.accent : "transparent"
                        border.color: monitor.marker3Active ? root.accent : root.border
                        border.width: 2
                        Layout.alignment: Qt.AlignTop

                        Text { anchors.centerIn: parent; font.pixelSize: 18; color: "#FFF"; text: monitor.marker3Active ? "✓" : ""; font.bold: true }

                        SequentialAnimation on scale {
                            id: m3Bounce; loops: 1
                            NumberAnimation { to: 1.3; duration: 100 }
                            NumberAnimation { to: 1.0; duration: 200 }
                        }
                        property bool _prev: false
                        Connections {
                            target: monitor
                            function onStateChanged() {
                                if (monitor.marker3Active && !m3Check._prev) {
                                    m3Bounce.restart()
                                    m3Check._prev = true
                                    edgePulse.restart()
                                }
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        RowLayout {
                            spacing: 8
                            Text { font.family: root.monoFont; font.pixelSize: 14; font.bold: true; color: root.accent; text: "(3)" }
                            Text { font.family: root.monoFont; font.pixelSize: 13; font.bold: true; color: root.textPrimary; text: "PROOF VERIFIED BY ANOTHER NODE" }
                            Item { Layout.fillWidth: true }
                            Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textTertiary
                                text: monitor.marker3Active ? monitor.marker3VerifyCount + " verifications" : "" }
                        }

                        Flow {
                            visible: monitor.marker3Active
                            Layout.fillWidth: true
                            spacing: 16

                            Row {
                                visible: monitor.marker3Epoch > 0
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "epoch:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.accent; text: String(monitor.marker3Epoch) }
                            }
                            Row {
                                visible: monitor.marker3Nullifier.length > 0
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "nullifier:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.yellow; text: monitor.marker3Nullifier }
                            }
                            Row {
                                spacing: 4
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.textSecond; text: "nodes:" }
                                Text { font.family: root.monoFont; font.pixelSize: 10; color: root.blue
                                    text: {
                                        var parts = []
                                        for (var i = 0; i < 4; i++) {
                                            var p = nodeProofs(i)
                                            if (p > 0) parts.push("N" + i + ":" + p)
                                        }
                                        return parts.length > 0 ? parts.join("  ") : "---"
                                    }
                                }
                            }
                        }

                        Text {
                            visible: monitor.marker3Active
                            font.family: root.monoFont; font.pixelSize: 9; color: root.textTertiary
                            text: m3Card.expanded ? monitor.marker3RawLine : "▸ raw log"
                            wrapMode: m3Card.expanded ? Text.WrapAnywhere : Text.NoWrap
                            Layout.fillWidth: true
                            elide: m3Card.expanded ? Text.ElideNone : Text.ElideRight

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: m3Card.expanded = !m3Card.expanded
                            }
                        }
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }

        // ═══════════════════════════════════════════════════
        // ZONE 3: LIVE CORRELATION STRIP
        // ═══════════════════════════════════════════════════
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 200
            color: bgSecondary
            radius: 8

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 0

                // Sender correlation pane
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 2

                    Text { font.family: root.monoFont; font.pixelSize: 11; font.bold: true; color: root.accent; text: "SENDER" }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: senderCorrelation
                        clip: true
                        spacing: 1

                        delegate: Rectangle {
                            width: ListView.view.width
                            height: 16
                            color: "transparent"

                            Rectangle {
                                anchors.fill: parent; radius: 2; color: root.accent; opacity: 0
                                SequentialAnimation on opacity { running: index === 0; loops: 1
                                    NumberAnimation { to: 0.2; duration: 100 }
                                    NumberAnimation { to: 0; duration: 500 }
                                }
                            }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                Text { font.family: root.monoFont; font.pixelSize: 9; color: root.textTertiary; text: timestamp }
                                Text { font.family: root.monoFont; font.pixelSize: 9; font.bold: true; color: root.accent; text: eventType }
                                Text { font.family: root.monoFont; font.pixelSize: 9; color: root.textSecond; text: detail; elide: Text.ElideRight }
                            }
                        }
                    }
                }

                // Vertical separator
                Rectangle { width: 1; Layout.fillHeight: true; color: root.border }

                // Verifier/node correlation pane
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 2

                    Text { font.family: root.monoFont; font.pixelSize: 11; font.bold: true; color: root.yellow; text: "VERIFIER NODES" }

                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        model: nodeCorrelation
                        clip: true
                        spacing: 1

                        delegate: Rectangle {
                            width: ListView.view.width
                            height: 16
                            color: "transparent"

                            Rectangle {
                                anchors.fill: parent; radius: 2; color: root.yellow; opacity: 0
                                SequentialAnimation on opacity { running: index === 0; loops: 1
                                    NumberAnimation { to: 0.2; duration: 100 }
                                    NumberAnimation { to: 0; duration: 500 }
                                }
                            }

                            Row {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                Text { font.family: root.monoFont; font.pixelSize: 9; color: root.textTertiary; text: timestamp }
                                Text { font.family: root.monoFont; font.pixelSize: 9; font.bold: true
                                    color: eventType.indexOf("VERIFY") >= 0 ? root.accent : (eventType.indexOf("AUTH") >= 0 ? root.red : root.yellow)
                                    text: eventType
                                }
                                Text { font.family: root.monoFont; font.pixelSize: 9; color: root.textSecond; text: detail; elide: Text.ElideRight }
                            }
                        }
                    }
                }
            }
        }
    }
}
