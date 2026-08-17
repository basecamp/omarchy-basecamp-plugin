import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

CursorSurface {
  id: root

  property var bookmark: null
  property bool showAccount: false
  property double nowMs: 0
  property string fontFamily: Style.font.family
  property color dim: Qt.darker(foreground, 1.55)
  property color badge: foreground

  signal activated()
  signal pointerMoved(var mouse)

  implicitHeight: rowContent.implicitHeight + Style.space(16)

  MouseArea {
    id: rowMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onPositionChanged: function(mouse) { root.pointerMoved(mouse) }
    onClicked: root.activated()
  }

  PanelToolTip {
    visible: rowMouse.containsMouse
    text: root.bookmark && root.bookmark.type !== "" ? root.bookmark.type : "Bookmark"
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

    TypeBadge {
      Layout.preferredWidth: Style.space(24)
      Layout.preferredHeight: Style.space(24)
      Layout.alignment: Qt.AlignTop
      color: root.badge
      fontFamily: root.fontFamily
      glyph: Model.bookmarkTypeIcon(root.bookmark ? root.bookmark.type : "")
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(2)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(5)

        // The project name takes the slack so the pair stays left-packed, and
        // the title is capped so a long one cannot crowd it out entirely.
        Text {
          Layout.maximumWidth: rowContent.width * 0.65
          text: root.bookmark ? root.bookmark.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }

        Text {
          visible: text !== ""
          Layout.fillWidth: true
          text: root.bookmark && root.bookmark.project !== "" ? "— " + root.bookmark.project : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }
      }

      Text {
        visible: text !== ""
        Layout.fillWidth: true
        text: Model.bookmarkMeta(root.bookmark, root.nowMs, root.showAccount)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
