import QtQuick
import QtQuick.Controls as QQC
import qs.Ui
import qs.Commons

BarWidget {
  id: root

  moduleName: "io.github.jxsparrou.spokenshelf"
  readonly property var service: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  property bool popupOpen: false
  property string page: "home"

  function close() { popupOpen = false }
  function playBook(book, offline) {
    if (!service || !book) return
    if (offline || service.isDownloaded(book.id)) service.playOffline(book.id, book._spokenShelfServer || "", book._spokenShelfUserId || "")
    else service.playItem(book)
    page = "player"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰁧"
    active: root.popupOpen
    tooltipText: root.service && root.service.title ? root.service.title : (root.service && root.service.connected ? "SpokenShelf" : "Connect SpokenShelf")

    onPressed: function(mouseButton) {
      if (!root.service) return
      var opening = !root.popupOpen
      root.popupOpen = opening
      if (opening && root.service.connected) root.service.refreshVisibleProgress()
      if (opening && !root.service.connected) {
        var hasDownloads = Object.keys(root.service.offlineBooks).length > 0
        root.page = hasDownloads ? "offline" : "home"
        if (!hasDownloads) root.service.promptForCredentials()
      }
    }
  }

  Connections {
    target: root.service
    function onConnectedChanged() {
      if (!root.service) return
      if (root.service.connected) root.popupOpen = true
      else searchField.text = ""
    }
    function onSelectedAudioOutputIdChanged() { audioOutputDropdown.value = root.service.selectedAudioOutputId }
    function onCredentialPromptStarting() { root.popupOpen = false }
    function onCredentialPromptUnavailable() { root.popupOpen = true }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: root.page === "library" ? searchField : null
    contentWidth: popup.fittedContentWidth(Style.space(480))
    contentHeight: popup.fittedContentHeight(root.page === "player" ? Style.space(570) : Style.space(590), Style.space(680))

    Column {
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        height: Math.max(appTitle.implicitHeight, headerActions.implicitHeight)

        Text {
          id: appTitle
          width: parent.width - headerActions.implicitWidth
          anchors.verticalCenter: parent.verticalCenter
          text: "SpokenShelf"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Row {
          id: headerActions
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Button {
            id: nowPlayingButton
            visible: root.service && root.service.currentItem
            iconText: root.service && root.service.isPlaying ? "󰏤" : "󰐊"
            text: "Now playing"
            foreground: root.bar.foreground
            onClicked: root.page = "player"
          }

          Button {
            visible: root.service
            iconText: root.service && root.service.connected ? "󰍃" : "󰌾"
            text: root.service && root.service.connected ? "Log out" : "Connect"
            tooltipText: root.service && root.service.connected ? "Log out and switch server" : "Connect to a server"
            enabled: root.service && !root.service.loggingOut
            foreground: root.bar.foreground
            onClicked: {
              if (root.service.connected) {
                root.popupOpen = false
                root.service.logout(true)
              } else {
                root.service.promptForCredentials()
              }
            }
          }
        }
      }

      Row {
        id: tabs
        width: parent.width
        spacing: Style.space(6)
        readonly property real cellWidth: (width - spacing * 3) / 4

        Repeater {
          model: [
            { value: "home", label: "Home" },
            { value: "library", label: "Library" },
            { value: "offline", label: "Offline" },
            { value: "player", label: "Playing" }
          ]

          Button {
            required property var modelData
            width: tabs.cellWidth
            text: modelData.label
            selected: root.page === modelData.value
            enabled: modelData.value !== "player" || (root.service && root.service.currentItem)
            opacity: enabled ? 1 : 0.4
            foreground: root.bar.foreground
            onClicked: root.page = modelData.value
          }
        }
      }

      Text {
        visible: root.service && root.service.dependencyError !== ""
        width: parent.width
        text: root.service ? root.service.dependencyError : ""
        textFormat: Text.PlainText
        color: "tomato"
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Text {
        visible: root.service && root.service.dependencyWarning !== ""
        width: parent.width
        text: root.service ? root.service.dependencyWarning : ""
        textFormat: Text.PlainText
        color: "goldenrod"
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Text {
        visible: root.service && root.service.error !== ""
        width: parent.width
        text: root.service ? root.service.error : ""
        textFormat: Text.PlainText
        color: "tomato"
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.Wrap
      }

      Item {
        id: pageArea
        width: parent.width
        height: parent.height - y

        Flickable {
          id: homePage
          anchors.fill: parent
          visible: root.page === "home"
          contentWidth: width
          contentHeight: homeContent.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          Column {
            id: homeContent
            width: homePage.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: parent.width
              text: "CONTINUE LISTENING"
              foreground: root.bar.foreground
            }

            Text {
              visible: root.service && !root.service.loading && root.service.continueBooks.length === 0
              width: parent.width
              text: "No books in progress yet"
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.service ? root.service.continueBooks : []
              BookRow {
                required property var modelData
                width: homeContent.width
                book: modelData
                service: root.service
                bar: root.bar
                onActivated: root.playBook(modelData, false)
              }
            }

            PanelSeparator {
              visible: root.service && root.service.recentBooks.length > 0
              width: parent.width
              foreground: root.bar.foreground
            }

            PanelSectionHeader {
              width: parent.width
              text: "RECENTLY ADDED"
              foreground: root.bar.foreground
            }

            Repeater {
              model: root.service ? root.service.recentBooks : []
              BookRow {
                required property var modelData
                width: homeContent.width
                book: modelData
                service: root.service
                bar: root.bar
                onActivated: root.playBook(modelData, false)
              }
            }
          }
        }

        Column {
          anchors.fill: parent
          visible: root.page === "library"
          spacing: Style.space(8)

          TextField {
            id: searchField
            width: parent.width
            foreground: root.bar.foreground
            placeholderText: "Search titles, authors, series..."
            onTextChanged: searchTimer.restart()
            onAccepted: if (root.service) root.service.searchLibrary(text)
          }

          Timer {
            id: searchTimer
            interval: 300
            repeat: false
            onTriggered: if (root.service) root.service.searchLibrary(searchField.text)
          }

          Text {
            visible: root.service && root.service.searching
            text: "Searching..."
            color: Qt.darker(root.bar.foreground, 1.35)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          ListView {
            width: parent.width
            height: parent.height - y
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds
            model: root.service ? (searchField.text.trim() === "" ? root.service.libraryBooks : root.service.searchBooks) : []
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: BookRow {
              required property var modelData
              width: ListView.view.width
              book: modelData
              service: root.service
              bar: root.bar
              onActivated: root.playBook(modelData, false)
            }
          }
        }

        Column {
          anchors.fill: parent
          visible: root.page === "offline"
          spacing: Style.space(8)

          Text {
            visible: root.service && root.service.offlineBookList().length === 0
            text: "Downloaded books will appear here"
            color: Qt.darker(root.bar.foreground, 1.35)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            width: parent.width
            height: parent.height
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds
            model: root.service ? root.service.offlineBookList() : []
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

            delegate: BookRow {
              required property var modelData
              width: ListView.view.width
              book: modelData
              service: root.service
              bar: root.bar
              offline: true
              onActivated: root.playBook(modelData, true)
            }
          }
        }

        Column {
          id: playerPage
          anchors.fill: parent
          visible: root.page === "player"
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(14)

            BorderSurface {
              width: Style.space(108)
              height: Style.space(162)
              radius: Style.cornerRadius
              clip: true
              color: Style.normalFillFor(root.bar.foreground, Color.accent)
              borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

              Image {
                id: playerCover
                anchors.fill: parent
                anchors.margins: Style.space(2)
                source: root.service ? root.service.coverUrl(root.service.currentItem, 260) : ""
                asynchronous: true
                smooth: true
                fillMode: Image.PreserveAspectCrop
              }

              Text {
                anchors.centerIn: parent
                visible: playerCover.status !== Image.Ready
                text: "󰂺"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.displayLarge
              }
            }

            Column {
              width: parent.width - Style.space(122)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(5)

              Text {
                width: parent.width
                text: root.service ? root.service.title || "Nothing playing" : "Nothing playing"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: root.service ? root.service.author : ""
                textFormat: Text.PlainText
                color: Qt.darker(root.bar.foreground, 1.3)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                visible: root.service && root.service.chapterTitle !== ""
                width: parent.width
                text: root.service ? root.service.chapterTitle : ""
                textFormat: Text.PlainText
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
              }

              Text {
                text: root.service && root.service.localPlayback
                  ? "Playing from download"
                  : "Streaming from " + (root.service ? root.service.serverName : "Audiobookshelf")
                color: Qt.darker(root.bar.foreground, 1.5)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSlider {
            id: seekSlider
            width: parent.width
            bar: root.bar
            minimum: 0
            maximum: Math.max(1, root.service ? root.service.duration : 1)
            value: root.service ? root.service.position : 0
            step: 15
            onReleased: function(value) { if (root.service) root.service.seek(value) }
          }

          Row {
            width: parent.width
            Text {
              width: parent.width / 3
              text: root.service ? root.service.formatDuration(seekSlider.dragging ? seekSlider.liveValue : root.service.position) : "0:00"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Text {
              width: parent.width / 3
              horizontalAlignment: Text.AlignHCenter
              text: root.service ? Math.round(root.service.bookProgress * 100) + "% book" : ""
              color: Qt.darker(root.bar.foreground, 1.25)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
            Text {
              width: parent.width / 3
              horizontalAlignment: Text.AlignRight
              text: root.service ? "-" + root.service.formatDuration(Math.max(0, root.service.duration - (seekSlider.dragging ? seekSlider.liveValue : root.service.position))) : "-0:00"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            visible: root.service && root.service.currentChapter
            width: parent.width
            spacing: Style.space(3)

            Row {
              width: parent.width
              Text {
                width: parent.width
                text: root.service ? (root.service.chapterTitle || "Current chapter") : ""
                textFormat: Text.PlainText
                color: Qt.darker(root.bar.foreground, 1.25)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                elide: Text.ElideRight
              }
            }

            Item {
              width: parent.width
              height: chapterSlider.implicitHeight

              Item {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(48)
                height: Style.space(22)

                Text {
                  anchors.centerIn: parent
                  text: root.service ? "CH " + root.service.chapterNumber : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              PanelSlider {
                id: chapterSlider
                width: parent.width * 0.75
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: 0
                maximum: Math.max(1, root.service ? root.service.chapterDuration : 1)
                value: root.service ? root.service.chapterPosition : 0
                step: 5
                trackHeight: Math.max(3, Style.space(3))
                knobSize: Math.max(11, Style.space(11))
                onReleased: function(value) { if (root.service) root.service.seekChapter(value) }
              }

              Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(44)
                horizontalAlignment: Text.AlignRight
                text: root.service ? Math.round(root.service.chapterProgress * 100) + "%" : ""
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Row {
              width: parent.width * 0.75
              anchors.horizontalCenter: parent.horizontalCenter
              Text {
                width: parent.width / 2
                text: root.service ? root.service.formatDuration(chapterSlider.dragging ? chapterSlider.liveValue : root.service.chapterPosition) : "0:00"
                color: Qt.darker(root.bar.foreground, 1.45)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width / 2
                horizontalAlignment: Text.AlignRight
                text: root.service ? root.service.formatDuration(root.service.chapterDuration) : "0:00"
                color: Qt.darker(root.bar.foreground, 1.45)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)

            Button {
              iconText: "󰶖"
              tooltipText: "Back 30 seconds"
              foreground: root.bar.foreground
              onClicked: if (root.service) root.service.skip(-30)
            }
            Button {
              iconText: root.service && root.service.isPlaying ? "󰏤" : "󰐊"
              tooltipText: root.service && root.service.isPlaying ? "Pause" : "Play"
              foreground: root.bar.foreground
              iconSize: Style.font.iconLarge
              horizontalPadding: Style.spacing.panelGap
              onClicked: if (root.service) root.service.togglePlayback()
            }
            Button {
              iconText: "󰴆"
              tooltipText: "Forward 30 seconds"
              foreground: root.bar.foreground
              onClicked: if (root.service) root.service.skip(30)
            }
          }

          PanelSeparator { width: parent.width; foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(5)

            Text {
              width: parent.width
              text: root.service ? root.service.downloadStatus : ""
              visible: text !== ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Rectangle {
              visible: root.service && root.service.downloading
              width: parent.width
              height: Style.space(4)
              radius: height / 2
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.2)
              Rectangle {
                width: parent.width * (root.service ? root.service.downloadProgress : 0)
                height: parent.height
                radius: parent.radius
                color: root.bar.foreground
              }
            }
            Text {
              visible: root.service && root.service.downloading
              text: root.service ? root.service.downloadProgressLabel : ""
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(58)
                anchors.verticalCenter: parent.verticalCenter
                text: "󰓃 Output"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              Dropdown {
                id: audioOutputDropdown
                width: parent.width - Style.space(58) - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                showLabel: false
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                options: root.service ? root.service.audioOutputOptions : []
                value: root.service ? root.service.selectedAudioOutputId : ""
                onChanged: function(value) { if (root.service) root.service.setAudioOutput(value) }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                width: Style.space(58)
                anchors.verticalCenter: parent.verticalCenter
                text: root.service ? "󰕾 " + Math.round(root.service.playbackVolume * 100) + "%" : "󰕾"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }

              PanelSlider {
                id: volumeSlider
                width: parent.width - Style.space(58) - downloadButton.width - parent.spacing * 2
                anchors.verticalCenter: parent.verticalCenter
                bar: root.bar
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.service ? root.service.playbackVolume : 1
                onMoved: function(value) { if (root.service) root.service.setVolume(value) }
              }

              Button {
                id: downloadButton
                iconText: "󰇚"
                text: root.service && root.service.currentDownloaded ? "Downloaded" : "Download"
                enabled: root.service && !root.service.downloading && !root.service.currentDownloaded
                opacity: enabled ? 1 : 0.55
                foreground: root.bar.foreground
                onClicked: if (root.service) root.service.downloadBook()
              }
            }
          }
        }
      }
    }
  }
}
