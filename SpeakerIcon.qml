import QtQuick
import qs.Commons
import qs.Ui

OpticalGlyph {
  id: root

  property real size: Style.bar.iconCanvas
  property bool connected: true

  width: size
  height: size
  implicitWidth: size
  implicitHeight: size
  // mdi-speaker / mdi-speaker-off
  text: connected ? "\u{f04c3}" : "\u{f04c4}"
  fontFamily: "JetBrainsMono Nerd Font"
  fontSize: size * (Style.bar.iconFont / Style.bar.iconCanvas)
  color: Color.foreground
}
