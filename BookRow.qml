import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property var book
  required property var service
  required property QtObject bar
  property bool offline: false
  readonly property var metadata: book && book.media ? book.media.metadata : null
  readonly property var progress: book ? service.progressForItem(book.id) : null
  readonly property real progressValue: progress ? Math.max(0, Math.min(1, Number(progress.progress || 0))) : 0
  signal activated()
  signal deleteRequested()

  implicitHeight: Style.space(76)
  foreground: bar.foreground
  hasCursor: pointer.containsMouse
  current: service.currentItem && book && service.currentItem.id === book.id

  BorderSurface {
    id: cover
    anchors.left: parent.left
    anchors.leftMargin: Style.space(6)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(42)
    height: Style.space(62)
    radius: Style.spacing.labelGap
    clip: true
    color: Style.normalFillFor(root.bar.foreground, Color.accent)
    borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

    Image {
      id: coverImage
      anchors.fill: parent
      anchors.margins: Style.space(1)
      source: root.service.coverUrl(root.book, 96)
      asynchronous: true
      smooth: true
      fillMode: Image.PreserveAspectCrop
    }

    Text {
      anchors.centerIn: parent
      visible: coverImage.status !== Image.Ready
      text: "󰂺"
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.iconLarge
    }
  }

  Column {
    anchors.left: cover.right
    anchors.leftMargin: Style.space(10)
    anchors.right: statusIcon.left
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(3)

    Text {
      width: parent.width
      text: root.metadata ? root.metadata.title || "Untitled" : "Untitled"
      textFormat: Text.PlainText
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      text: root.metadata ? root.metadata.authorName || "Unknown author" : "Unknown author"
      textFormat: Text.PlainText
      color: Qt.darker(root.bar.foreground, 1.35)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Row {
      width: parent.width
      spacing: Style.space(6)

      Text {
        text: root.progress ? Math.round(root.progressValue * 100) + "%" : root.service.formatDuration(root.book && root.book.media ? root.book.media.duration : 0)
        color: Qt.darker(root.bar.foreground, 1.55)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }

      Rectangle {
        visible: root.progress !== null
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(0, parent.width - Style.space(48))
        height: Style.space(3)
        radius: height / 2
        color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.18)

        Rectangle {
          width: parent.width * root.progressValue
          height: parent.height
          radius: parent.radius
          color: root.bar.foreground
        }
      }
    }
  }

  Text {
    id: statusIcon
    anchors.right: deleteButton.visible ? deleteButton.left : parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    text: root.book && root.book._spokenShelfPartial
      ? (root.service.downloading && root.service.isActiveDownload(root.book)
          ? Math.round(root.service.downloadProgress * 100) + "%" : "Partial")
      : (root.offline || root.service.isDownloaded(root.book.id) ? "󰇚" : "󰐊")
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: root.book && root.book._spokenShelfPartial ? Style.font.caption : Style.font.icon
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activated()
  }

  Text {
    id: deleteButton
    visible: root.offline
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
    z: 2
    text: "󰆴"
    color: deletePointer.containsMouse ? "tomato" : root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.icon

    MouseArea {
      id: deletePointer
      anchors.fill: parent
      anchors.margins: -Style.space(8)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        mouse.accepted = true
        root.deleteRequested()
      }
    }
  }
}
