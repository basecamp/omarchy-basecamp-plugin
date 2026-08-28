import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model
import "ServiceHost.js" as ServiceHost

Panel {
  id: root
  moduleName: "37signals.basecamp"
  ipcTarget: "37signals.basecamp"
  manageIpc: false

  property int selectedIndex: 0
  property bool cursorActive: false
  property double nowMs: Date.now()

  QtObject {
    id: dummyService
    property var settings: ({})
    property bool refreshing: false
    property bool installed: true
    property bool supported: true
    property bool authenticated: true
    property bool probed: false
    property bool probeError: false
    property var accounts: []
    property var notifications: []
    property int unreadCount: 0
    property int accountCount: 0
    property string lastError: ""
    property string actionStatus: ""
    property string accountFilter: ""
    property string stateFilter: "unread"
    function refresh() {}
    function refreshIfStale() {}
    function openNotification() {}
    function markRead() {}
    function setAccountFilter() {}
    function setStateFilter() {}
    function tryStartSetup() { return false }
    function finishSetup() {}
    function checkSetupRunning() {}
  }

  // Omarchy mounts one bar per monitor. Read `_services` here so this
  // binding re-runs when the host finishes creating the singleton; the
  // lookup itself lives in ServiceHost.js.
  readonly property var hostedService: {
    var _ = bar && bar.shell ? bar.shell._services : null
    return ServiceHost.hostedService(bar)
  }
  readonly property var service: hostedService !== null ? hostedService : dummyService
  readonly property string accountFilter: service.accountFilter
  readonly property string stateFilter: service.stateFilter

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var filteredNotifications: Model.filterNotifications(service.notifications, accountFilter, stateFilter)
  readonly property var accountFilterOptions: Model.accountFilterOptions(service.accounts)

  readonly property var accountDropdownOptions: {
    var options = accountFilterOptions
    var out = []
    for (var i = 0; i < options.length; i++) {
      var count = accountUnreadCount(options[i].value)
      out.push({
        value: options[i].value,
        label: count > 0 ? options[i].label + " (" + count + ")" : options[i].label
      })
    }
    return out
  }

  readonly property bool otherAccountsUnread: {
    if (accountFilter === "") return false
    for (var i = 0; i < service.notifications.length; i++) {
      var item = service.notifications[i]
      if (item.unread === true && String(item.accountId || "") !== accountFilter) return true
    }
    return false
  }

  property int phraseIndex: 0
  readonly property var loadingPhrases: [
    "Setting up the campsite",
    "Pitching the tent",
    "Gathering kindling",
    "Sitting by the campfire",
    "Roasting marshmallows",
    "Climbing the hill chart"
  ]
  // Guard on needsSetup: the setup-state retry timer probes every few
  // seconds, and each probe would otherwise flash a loading phrase.
  readonly property bool rotatingPhrases: service.refreshing && !needsSetup

  readonly property string heroStatusText: {
    if (service.actionStatus !== "") return service.actionStatus
    if (service.lastError !== "") return service.lastError
    if (rotatingPhrases) return loadingPhrases[phraseIndex % loadingPhrases.length]
    return "Designed & built by 37signals"
  }

  function resetFilteredView() {
    selectedIndex = 0
    cursorActive = false
    pointerGate.reset()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() {
      if (panelFlick) panelFlick.contentY = 0
    })
  }

  function setAccountFilter(value) {
    service.setAccountFilter(value)
    resetFilteredView()
  }

  function setStateFilter(value) {
    service.setStateFilter(value)
    resetFilteredView()
  }

  function emptyMessage() {
    if (service.refreshing && service.lastUpdated instanceof Date && service.lastUpdated.getTime() <= 0) return "Loading…"
    if (service.notifications.length === 0 || stateFilter === "unread") return "You're all caught up."
    return "No previous notifications."
  }

  readonly property var setupPlan: Model.setupPlan(service.installed, service.supported, service.authenticated, ipcTarget)
  readonly property bool needsSetup: service.probed && setupPlan.needed
  readonly property bool missingCli: service.probed && service.installed !== true

  // Keep one setup flow active until its command reports completion. This
  // prevents a second browser login regardless of how long authentication
  // takes, while permitting an immediate retry after failure.
  onNeedsSetupChanged: if (!needsSetup) service.finishSetup()

  function launchSetup() {
    if (!bar || !service.tryStartSetup()) return
    bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(setupPlan.launchCommand))
    close()
  }

  function typeColor(type) {
    var value = String(type || "").toLowerCase()
    if (value === "mention") return urgent
    if (value === "chat" || value === "comment") return Color.accent
    if (value === "completion") return Qt.darker(foreground, 1.2)
    if (value === "document") return Color.muted
    if (value === "boostreport" || value === "hill") return dim
    return foreground
  }

  function accountUnreadCount(accountId) {
    var id = String(accountId || "")
    if (id === "") return 0
    var count = 0
    for (var i = 0; i < service.notifications.length; i++) {
      var item = service.notifications[i]
      if (item.unread === true && String(item.accountId || "") === id) count++
    }
    return count
  }

  function cycleAccountFilter(delta) {
    var options = accountFilterOptions
    if (options.length < 2) return
    var current = 0
    for (var i = 0; i < options.length; i++) {
      if (String(options[i].value) === accountFilter) {
        current = i
        break
      }
    }
    setAccountFilter(options[(current + delta + options.length) % options.length].value)
  }

  function ensureSelection() {
    if (filteredNotifications.length === 0) {
      selectedIndex = 0
      return
    }
    selectedIndex = Math.max(0, Math.min(filteredNotifications.length - 1, selectedIndex))
  }

  function select(index) {
    cursorActive = true
    selectedIndex = Math.max(0, Math.min(filteredNotifications.length - 1, index))
    scrollSelectionIntoView()
  }

  function moveSelection(delta) {
    if (filteredNotifications.length === 0) return
    if (!cursorActive) {
      select(0)
      return
    }
    select(selectedIndex + delta)
  }

  function activateSelection() {
    if (!cursorActive || filteredNotifications.length === 0) return
    service.openNotification(filteredNotifications[selectedIndex])
  }

  function scrollSelectionIntoView() {
    if (!notificationColumn || selectedIndex < 0 || selectedIndex >= notificationColumn.children.length) return
    var wrapper = notificationColumn.children[selectedIndex]
    Qt.callLater(function() {
      if (!wrapper || !panelFlick) return
      var point = wrapper.mapToItem(panelFlick.contentItem, 0, 0)
      var margin = Style.space(8)
      var top = point.y
      var bottom = top + wrapper.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    service.checkSetupRunning()
    service.refreshIfStale()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  onFilteredNotificationsChanged: ensureSelection()

  PointerMoveGate {
    id: pointerGate
    referenceItem: panelFlick
  }

  // Auto-retry while a setup state is showing: each tick is one local
  // `auth status` probe, so the panel recovers on its own once the user
  // finishes installing or signing in.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened && (root.needsSetup || service.probeError)
    onTriggered: {
      service.checkSetupRunning()
      service.refresh()
    }
  }

  Binding {
    target: root.hostedService
    property: "settings"
    value: root.settings
    when: root.hostedService !== null
  }

  Connections {
    target: root.hostedService
    function onAccountFilterChanged() { root.resetFilteredView() }
    function onStateFilterChanged() { root.resetFilteredView() }
  }

  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % root.loadingPhrases.length
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { service.refresh(); return "ok" }
    function setupFinished(): string {
      service.finishSetup()
      service.refresh()
      return "ok"
    }
    function unread(): int { return service.unreadCount }
    function status(): string {
      return JSON.stringify({
        accounts: service.accountCount,
        notifications: service.notifications.length,
        unread: service.unreadCount,
        visible: root.filteredNotifications.length,
        stateFilter: root.stateFilter,
        accountFilter: root.accountFilter,
        refreshing: service.refreshing,
        error: service.lastError
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        BasecampIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: service.unreadCount > 0 ? root.urgent : root.foreground
        }
      }
    }
    tooltipText: service.refreshing
      ? "Refreshing Basecamp notifications"
      : (service.unreadCount === 1 ? "1 unread Basecamp notification" : service.unreadCount + " unread Basecamp notifications")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) service.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(fixedContent.implicitHeight + notificationContent.implicitHeight + Style.space(12), Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: accountDropdown.popupOpen
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.cycleAccountFilter(dx)
        else if (dy !== 0) root.moveSelection(dy)
      }
      onActivateRequested: root.activateSelection()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") service.refresh()
        else if (text === "u" || text === "U") root.setStateFilter("unread")
        else if (text === "p" || text === "P") root.setStateFilter("previous")
      }

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(12)

        Column {
          id: fixedContent
          Layout.fillWidth: true
          spacing: Style.space(12)

          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, refreshButton.implicitHeight)

            BasecampIcon {
              id: heroIcon
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconSize: Style.font.display
              color: root.foreground
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: root.missingCli ? parent.right : refreshButton.left
              anchors.rightMargin: root.missingCli ? 0 : Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                text: "Basecamp"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                id: heroStatus
                visible: text !== ""
                width: parent.width
                text: root.heroStatusText.toUpperCase()
                textFormat: Text.PlainText
                color: service.lastError !== "" && service.actionStatus === "" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            BorderSurface {
              id: refreshButton
              visible: !root.missingCli
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              implicitWidth: Math.max(Style.space(22), Style.font.icon + Style.spacing.sm * 2)
              implicitHeight: implicitWidth
              radius: Style.cornerRadius
              enabled: !service.refreshing

              readonly property bool _hot: mouse.containsMouse && enabled
              color: _hot ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
              Behavior on color { ColorAnimation { duration: 60 } }

              RefreshIcon {
                id: refreshIcon
                anchors.centerIn: parent
                iconSize: Style.font.icon
                color: root.foreground
                active: service.refreshing
                transformOrigin: Item.Center

                RotationAnimation on rotation {
                  from: 0
                  to: 360
                  duration: 800
                  loops: Animation.Infinite
                  running: service.refreshing
                }
              }

              Connections {
                target: service
                function onRefreshingChanged() {
                  if (!service.refreshing) refreshIcon.rotation = 0
                }
              }

              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: refreshButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                enabled: refreshButton.enabled
                onClicked: service.refresh()
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Dropdown {
            id: accountDropdown
            visible: service.accountCount > 1 && !root.needsSetup
            width: parent.width
            showLabel: false
            options: root.accountDropdownOptions
            foreground: root.foreground
            background: Color.popups.background
            accent: Color.accent
            fontFamily: root.fontFamily
            onChanged: function(value) { root.setAccountFilter(value) }

            // The dropdown trigger keeps active focus after its popup
            // closes, and its own key handler eats Enter/Space/Down. Hand
            // focus back to the key catcher so arrows drive the list again.
            // callLater runs after the popup's internal focus juggling.
            onPopupOpenChanged: if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

            // Binding element (not an inline binding) so it survives the
            // imperative `value` write Dropdown makes on selection.
            Binding on value {
              value: root.accountFilter
            }

            Rectangle {
              visible: root.accountFilter !== "" && root.otherAccountsUnread
              x: parent.width - width / 2
              y: -height / 2
              width: Style.space(8)
              height: width
              radius: width / 2
              color: root.urgent
            }
          }

          Row {
            visible: !root.needsSetup
            spacing: Style.space(2)

            Button {
              text: "NEW FOR YOU"
              selected: root.stateFilter === "unread"
              foreground: root.foreground
              background: "transparent"
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(7)
              verticalPadding: Style.space(1)
              onClicked: root.setStateFilter("unread")
            }

            Button {
              text: "PREVIOUS NOTIFICATIONS"
              selected: root.stateFilter === "previous"
              foreground: root.foreground
              background: "transparent"
              accent: Color.accent
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              horizontalPadding: Style.space(7)
              verticalPadding: Style.space(1)
              onClicked: root.setStateFilter("previous")
            }
          }
        }

        Flickable {
          id: panelFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: notificationContent.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: notificationContent
            width: panelFlick.width
            spacing: Style.space(12)

            Column {
              visible: root.needsSetup
              width: parent.width
              spacing: Style.space(8)
              topPadding: Style.space(16)
              bottomPadding: Style.space(18)

              Text {
                visible: root.setupPlan.title !== ""
                width: parent.width
                text: root.setupPlan.title
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
              }

              Button {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.setupPlan.buttonLabel
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                enabled: !service.setupRunning && !service.setupChecking
                onClicked: root.launchSetup()
              }

              Item {
                visible: root.setupPlan.command !== ""
                width: parent.width
                implicitHeight: setupCommandRow.implicitHeight + Style.space(4)

                Row {
                  id: setupCommandRow
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(6)

                  Text {
                    text: "or run: " + root.setupPlan.command
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰆏"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: setupCommandMouse
                  anchors.fill: setupCommandRow
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(root.setupPlan.command) + " | wl-copy"])
                    setupCopiedTimer.restart()
                  }
                }

                PanelToolTip {
                  visible: setupCommandMouse.containsMouse
                  text: setupCopiedTimer.running ? "Copied" : "Copy to clipboard"
                  fontFamily: root.fontFamily
                }

                Timer {
                  id: setupCopiedTimer
                  interval: 1500
                }
              }
            }

            Text {
              visible: !root.needsSetup && root.filteredNotifications.length === 0 && service.lastError === ""
            width: parent.width
            text: root.emptyMessage()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            topPadding: Style.space(16)
            bottomPadding: Style.space(18)
          }

          Column {
            id: notificationColumn
            visible: !root.needsSetup && root.filteredNotifications.length > 0
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.filteredNotifications

              CursorSurface {
                id: notificationRow
                required property var modelData
                required property int index
                width: notificationColumn.width
                foreground: root.foreground
                hasCursor: root.cursorActive && root.selectedIndex === index
                implicitHeight: rowContent.implicitHeight + Style.space(16)

                MouseArea {
                  id: rowMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: function(mouse) {
                    if (pointerGate.moved(notificationRow, mouse)) root.select(notificationRow.index)
                  }
                  onClicked: service.openNotification(notificationRow.modelData)
                }

                PanelToolTip {
                  visible: rowMouse.containsMouse
                  text: (notificationRow.modelData.type || "Notification") + (notificationRow.modelData.unread ? " · Unread" : " · Read")
                  fontFamily: root.fontFamily
                }

                RowLayout {
                  id: rowContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(9)

                  Rectangle {
                    Layout.preferredWidth: Style.space(24)
                    Layout.preferredHeight: Style.space(24)
                    Layout.alignment: Qt.AlignTop
                    radius: width / 2
                    color: root.typeColor(notificationRow.modelData.type)

                    // Center the glyph's painted ink, not its em box — icon
                    // glyphs sit off-center in the monospace cell (see the
                    // kit's OpticalGlyph, extended here to both axes since a
                    // badge has no shared baseline to preserve).
                    TextMetrics {
                      id: glyphMetrics
                      font.family: root.fontFamily
                      font.pixelSize: Math.round(Style.font.icon)
                      text: Model.notificationTypeIcon(notificationRow.modelData.type)
                    }

                    Text {
                      id: glyphText
                      anchors.centerIn: parent
                      anchors.horizontalCenterOffset: glyphText.implicitWidth / 2 - (glyphMetrics.tightBoundingRect.x + glyphMetrics.tightBoundingRect.width / 2)
                      anchors.verticalCenterOffset: glyphText.implicitHeight / 2 - (glyphText.baselineOffset + glyphMetrics.tightBoundingRect.y + glyphMetrics.tightBoundingRect.height / 2)
                      text: glyphMetrics.text
                      color: Color.popups.background
                      font.family: root.fontFamily
                      font.pixelSize: glyphMetrics.font.pixelSize
                      renderType: Text.NativeRendering
                    }
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Text {
                      Layout.fillWidth: true
                      text: notificationRow.modelData.title
                      textFormat: Text.PlainText
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.weight: notificationRow.modelData.unread ? Font.DemiBold : Font.Normal
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: notificationRow.modelData.excerpt !== ""
                      Layout.fillWidth: true
                      text: notificationRow.modelData.excerpt
                      textFormat: Text.PlainText
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      maximumLineCount: 2
                      wrapMode: Text.Wrap
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      text: Model.notificationMeta(notificationRow.modelData, root.nowMs, root.accountFilter === "")
                      textFormat: Text.PlainText
                      color: Color.accent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Rectangle {
                    visible: notificationRow.modelData.unread
                    Layout.alignment: Qt.AlignTop
                    Layout.topMargin: Style.space(2)
                    Layout.preferredHeight: Style.space(16)
                    Layout.preferredWidth: Math.max(Style.space(16), Math.max(badgeCountMetrics.width, badgeGlyphMetrics.width) + Style.space(8))
                    radius: Style.space(8)
                    color: root.urgent

                    TextMetrics {
                      id: badgeCountMetrics
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      text: Model.notificationBadgeText(notificationRow.modelData, false)
                    }

                    TextMetrics {
                      id: badgeGlyphMetrics
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      text: Model.notificationBadgeText(notificationRow.modelData, true)
                    }

                    Text {
                      id: rowBadgeText
                      anchors.centerIn: parent
                      text: Model.notificationBadgeText(notificationRow.modelData, dismissMouse.containsMouse)
                      color: Color.background
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    MouseArea {
                      id: dismissMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: function(mouse) {
                        if (pointerGate.moved(notificationRow, mouse)) root.select(notificationRow.index)
                      }
                      onClicked: service.markRead(notificationRow.modelData)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
}
