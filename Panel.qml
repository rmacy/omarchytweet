import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Per-monitor presentation for the singleton composer service. Enter submits,
// Shift+Enter inserts a newline, and Escape dismisses the panel.
Panel {
  id: root
  moduleName: "bitr0t.omarchytweet"
  ipcTarget: "bitr0t.omarchytweet"

  readonly property var xtweet: bar && bar.shell
    ? bar.shell.serviceFor("bitr0t.omarchytweet") : null
  readonly property bool serviceReady: xtweet !== null
  readonly property bool posting: serviceReady && xtweet.posting
  readonly property bool paidApi: serviceReady && xtweet.paidApi
  readonly property string actionLabel: serviceReady
    ? xtweet.actionLabel : "Continue in X"
  readonly property string modeText: serviceReady
    ? xtweet.modeLabel : "Service unavailable"
  readonly property string statusText: serviceReady
    ? xtweet.statusText : "The X composer service did not start."
  readonly property bool statusError: !serviceReady || xtweet.statusError
  readonly property bool canSubmit: serviceReady && xtweet.ready
    && !xtweet.posting && composer.text.trim().length > 0

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened && serviceReady) xtweet.refreshMode()
  }

  function submit() {
    if (serviceReady) xtweet.submit()
  }

  // Prefill the shared draft and open this monitor's presentation. The
  // service rejects mutation while starting or while a post is active.
  function compose(text) {
    var result = serviceReady ? xtweet.compose(text) : "service-unavailable"
    root.open()
    return result
  }


  // IPC route separate from the Panel open/close target:
  //   omarchy-shell bitr0t.omarchytweet.compose compose "hello"
  IpcHandler {
    target: "bitr0t.omarchytweet.compose"

    function compose(text: string): string { return root.compose(text) }
  }

  Connections {
    target: root.serviceReady ? root.xtweet : null
    function onClosePanelsRequested() { root.close() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.paidApi ? "New post" : "Compose on X"
    onPressed: root.toggle()

    // Preserve the supplied X mark and tint it with the bar foreground in the
    // same way the tray treats symbolic icons.
    iconComponent: Component {
      Item {
        Image {
          id: logo
          anchors.fill: parent
          source: Qt.resolvedUrl("xtweet.png")
          sourceSize.width: 64
          sourceSize.height: 64
          fillMode: Image.PreserveAspectFit
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: logo
          source: logo
          colorization: 1.0
          colorizationColor: button.foreground
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: composer
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    Column {
      id: panelColumn
      anchors.fill: parent
      spacing: Style.spacing.controlGap

      Item {
        width: parent.width
        height: headerLabel.implicitHeight

        Text {
          id: headerLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "New post"
          color: root.fg
          font.family: root.family
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }

        Text {
          anchors.left: headerLabel.right
          anchors.leftMargin: Style.spacing.controlGap
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          elide: Text.ElideRight
          text: root.modeText
          color: root.serviceReady ? root.dim : Color.urgent
          font.family: root.family
          font.pixelSize: Style.font.caption
        }
      }

      TextArea {
        id: composer
        width: parent.width
        height: Style.space(120)
        text: root.serviceReady ? root.xtweet.draft : ""
        enabled: root.serviceReady
        readOnly: !root.serviceReady || !root.xtweet.ready || root.posting
        wrapMode: TextEdit.Wrap
        placeholderText: "What's happening?"
        color: root.fg
        selectionColor: Style.selectionFillFor(root.fg, Color.accent)
        selectedTextColor: root.fg
        placeholderTextColor: root.dim
        font.family: root.family
        font.pixelSize: Style.font.body
        leftPadding: Style.spacing.controlPaddingX + Border.left(composerBorder)
        rightPadding: Style.spacing.controlPaddingX + Border.right(composerBorder)
        topPadding: Style.spacing.inputPaddingY + Border.top(composerBorder)
        bottomPadding: Style.spacing.inputPaddingY + Border.bottom(composerBorder)
        selectByMouse: true
        Accessible.name: "Post text"

        readonly property var composerBorder: Border.controlSpec(
          activeFocus ? "focus" : (hovered ? "hover-cursor" : "normal"),
          root.fg, Color.accent)

        background: BorderSurface {
          color: Style.controlFill(composer.activeFocus, composer.hovered,
            root.fg, Color.accent)
          borderSpec: composer.composerBorder
          radius: Style.cornerRadius
        }

        onTextChanged: {
          if (root.serviceReady && text !== root.xtweet.draft) {
            root.xtweet.setDraft(text)
          }
        }

        Keys.onEscapePressed: function(event) {
          event.accepted = true
          root.close()
        }
        Keys.onReturnPressed: function(event) {
          if (event.modifiers & Qt.ShiftModifier) return
          event.accepted = true
          root.submit()
        }
        Keys.onEnterPressed: function(event) {
          if (event.modifiers & Qt.ShiftModifier) return
          event.accepted = true
          root.submit()
        }
      }

      Item {
        width: parent.width
        height: postButton.implicitHeight

        Text {
          anchors.left: parent.left
          anchors.right: postButton.left
          anchors.rightMargin: Style.spacing.controlGap
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideRight
          text: root.statusText
          color: root.statusError ? Color.urgent : root.dim
          font.family: root.family
          font.pixelSize: Style.font.caption
        }

        Button {
          id: postButton
          anchors.right: parent.right
          text: root.posting
            ? (root.paidApi ? "Posting…" : "Opening…")
            : root.actionLabel
          selected: true
          focusable: true
          foreground: root.fg
          fontFamily: root.family
          fontSize: Style.font.body
          enabled: root.canSubmit
          onClicked: root.submit()
        }
      }
    }
  }
}
