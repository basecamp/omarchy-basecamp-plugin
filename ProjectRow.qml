import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

CursorSurface {
  id: root

  property var project: null
  property bool showAccount: false
  property string fontFamily: Style.font.family
  property color dim: Qt.darker(foreground, 1.55)

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
    text: "Open in Basecamp"
    fontFamily: root.fontFamily
  }

  ColumnLayout {
    id: rowContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(10)
    anchors.rightMargin: Style.space(10)
    spacing: Style.space(2)

    Text {
      Layout.fillWidth: true
      text: root.project ? root.project.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      visible: text !== ""
      Layout.fillWidth: true
      text: Model.projectMeta(root.project, root.showAccount)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      maximumLineCount: 2
      wrapMode: Text.Wrap
      elide: Text.ElideRight
    }
  }
}
