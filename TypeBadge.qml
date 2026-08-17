import QtQuick
import qs.Commons

// Round type badge shared by the notification and bookmark rows. The fill is
// set by the caller; the glyph is always drawn on the panel background.
Rectangle {
  id: root

  property string glyph: ""
  property string fontFamily: Style.font.family

  implicitWidth: Style.space(24)
  implicitHeight: Style.space(24)
  radius: width / 2

  // Center the glyph's painted ink, not its em box — icon glyphs sit
  // off-center in the monospace cell (see the kit's OpticalGlyph, extended
  // here to both axes since a badge has no shared baseline to preserve).
  TextMetrics {
    id: glyphMetrics
    font.family: root.fontFamily
    font.pixelSize: Math.round(Style.font.icon)
    text: root.glyph
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
