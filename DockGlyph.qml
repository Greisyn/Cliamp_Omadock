import QtQuick
import qs.Commons

// Theme-following line icons for the dock, drawn like oShelf's Glyph:
// 1.5px round-cap strokes on a 22x22 grid, inked only with theme colors.
// Never hardcode a color here — pass Color.foreground / Color.accent.
Canvas {
  id: root
  property string kind: "play"
  property color ink: Color.foreground
  width: 22; height: 22
  onKindChanged: requestPaint()
  onInkChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onPaint: {
    var c = getContext("2d");
    c.reset(); c.strokeStyle = ink; c.fillStyle = ink;
    c.lineWidth = 1.5; c.lineJoin = "round"; c.lineCap = "round";
    c.scale(width / 22, height / 22);
    c.beginPath();
    if (kind === "play") {
      c.moveTo(8, 5); c.lineTo(17, 11); c.lineTo(8, 17); c.closePath();
    } else if (kind === "pause") {
      c.lineWidth = 2.2;
      c.moveTo(8, 5); c.lineTo(8, 17); c.moveTo(14, 5); c.lineTo(14, 17);
    } else if (kind === "prev") {
      c.moveTo(6, 5); c.lineTo(6, 17);
      c.moveTo(18, 5); c.lineTo(10, 11); c.lineTo(18, 17);
    } else if (kind === "next") {
      c.moveTo(16, 5); c.lineTo(16, 17);
      c.moveTo(4, 5); c.lineTo(12, 11); c.lineTo(4, 17);
    } else if (kind === "stop") {
      c.rect(7, 7, 8, 8);
    } else if (kind === "shuffle") {
      c.moveTo(2, 7); c.lineTo(6, 7);
      c.bezierCurveTo(12, 7, 10, 15, 16, 15); c.lineTo(20, 15);
      c.moveTo(17, 12); c.lineTo(20, 15); c.lineTo(17, 18);
      c.moveTo(2, 17); c.lineTo(6, 17);
      c.bezierCurveTo(8, 17, 9, 15, 11, 13);
      c.moveTo(11, 11);
      c.bezierCurveTo(13, 9, 14, 7, 16, 7); c.lineTo(20, 7);
      c.moveTo(17, 4); c.lineTo(20, 7); c.lineTo(17, 10);
    } else if (kind === "repeat") {
      c.moveTo(4, 8); c.lineTo(16, 8); c.lineTo(13, 5);
      c.moveTo(16, 8); c.lineTo(13, 11);
      c.moveTo(18, 14); c.lineTo(6, 14); c.lineTo(9, 11);
      c.moveTo(6, 14); c.lineTo(9, 17);
    } else if (kind === "repeatOne") {
      c.moveTo(4, 8); c.lineTo(16, 8); c.lineTo(13, 5);
      c.moveTo(16, 8); c.lineTo(13, 11);
      c.moveTo(18, 14); c.lineTo(6, 14); c.lineTo(9, 11);
      c.moveTo(6, 14); c.lineTo(9, 17);
      c.moveTo(12.5, 11); c.arc(11, 11, 1.4, 0, Math.PI * 2); c.fill();
    } else if (kind === "mono") {
      c.moveTo(18, 11); c.arc(11, 11, 7, 0, Math.PI * 2);
      c.moveTo(12.6, 11); c.arc(11, 11, 1.6, 0, Math.PI * 2); c.fill();
    } else if (kind === "close") {
      c.moveTo(6, 6); c.lineTo(16, 16); c.moveTo(16, 6); c.lineTo(6, 16);
    } else if (kind === "refresh") {
      c.arc(11, 11, 7, 0.9, 0.9 + Math.PI * 1.5);
      c.moveTo(16.5, 6.6); c.lineTo(16.8, 10.6);
      c.moveTo(16.5, 6.6); c.lineTo(13, 7.4);
    } else if (kind === "pin") {
      c.moveTo(7, 3); c.lineTo(15, 3); c.lineTo(14, 10);
      c.lineTo(17, 14); c.lineTo(5, 14); c.lineTo(8, 10); c.closePath();
      c.moveTo(11, 14); c.lineTo(11, 20);
    } else if (kind === "note") {
      c.moveTo(13, 4); c.lineTo(13, 14);
      c.moveTo(13, 4); c.bezierCurveTo(16, 5, 18, 7, 18, 10);
      c.moveTo(11, 14); c.arc(8.6, 14, 2.4, 0, Math.PI * 2);
    }
    c.stroke();
  }
}
