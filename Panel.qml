import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// GitHub repository browser for the Omarchy bar.
//
// Left click opens a panel listing every repository the signed-in `gh` account
// can see — personal plus organizations — with one tab per owner. Repositories
// already checked out under the Projects folder offer "open in agent" and
// "open in editor"; the rest offer a clone button that puts them there.
Panel {
  id: root
  moduleName: "shdw.github"
  ipcTarget: "shdw.github"
  manageIpc: false

  // ---- Theme handles. Guarded because the bare widget is instantiated
  //      before the bar injects itself.
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family

  // ---- State
  property var repos: []
  property var orgs: []
  property string viewer: ""
  property string agent: ""
  property string editor: ""
  property string projectsDir: ""
  property string loadError: ""
  property string warning: ""
  property string actionError: ""
  property string cloneError: ""
  property bool loading: false
  property string query: ""
  property string tab: "all"
  property string cloningNwo: ""

  // Nerd Font glyphs as codepoints so editors cannot mangle the private-use
  // area.
  readonly property string gitGlyph: String.fromCodePoint(0xE702)
  readonly property string githubGlyph: String.fromCodePoint(0xF09B)
  readonly property string downloadGlyph: String.fromCodePoint(0xF019)
  readonly property string aiGlyph: String.fromCodePoint(0xF06A9)
  readonly property string editorText: ">_"
  readonly property string folderGlyph: String.fromCodePoint(0xF07C)
  readonly property string refreshGlyph: String.fromCodePoint(0xF021)
  readonly property string lockGlyph: String.fromCodePoint(0xF023)
  readonly property string checkGlyph: String.fromCodePoint(0xF00C)
  readonly property string spinnerGlyph: String.fromCodePoint(0xF0996)
  readonly property string branchGlyph: String.fromCodePoint(0xF126)
  readonly property string issueGlyph: String.fromCodePoint(0xF41B)
  readonly property string prGlyph: String.fromCodePoint(0xF407)
  readonly property string clockGlyph: String.fromCodePoint(0xF017)
  readonly property string ciSuccessGlyph: String.fromCodePoint(0xF058)
  readonly property string ciFailureGlyph: String.fromCodePoint(0xF057)
  readonly property string ciPendingGlyph: String.fromCodePoint(0xF251)
  readonly property string ciNoneGlyph: String.fromCodePoint(0xF444)

  // Semantic colors for checks. The theme accent is deliberately neutral, so
  // pass/fail/pending use muted fixed hues that sit next to any Omarchy theme.
  readonly property color successColor: "#8fbc8f"
  readonly property color pendingColor: "#d4a86a"

  // Relative timestamps need a clock dependency, or the binding never updates
  // while the panel stays open.
  property double now: Date.now()

  readonly property string scriptDir: Qt.resolvedUrl(".").toString().replace("file://", "") + "/bin"
  readonly property string projectsSetting: String(root.setting("projectsDir", "~/Projects"))
  readonly property string resolvedProjectsDir: root.projectsDir !== ""
    ? root.projectsDir
    : root.projectsSetting.replace(/^~/, Quickshell.env("HOME"))
  readonly property bool includeForks: root.setting("includeForks", true) !== false
  readonly property int refreshMinutes: Math.max(1, Number(root.setting("refreshMinutes", 5)) || 5)

  // ---- Derived lists -------------------------------------------------------

  readonly property var filteredRepos: {
    var needle = root.query.trim().toLowerCase()
    var out = []
    for (var i = 0; i < root.repos.length; i++) {
      var repo = root.repos[i]
      if (!root.includeForks && repo.fork) continue
      if (root.tab === "@me") {
        if (String(repo.owner).toLowerCase() !== root.viewer.toLowerCase()) continue
      } else if (root.tab !== "all" && String(repo.owner) !== root.tab) {
        continue
      }
      if (needle !== "") {
        var haystack = (repo.name + " " + repo.nameWithOwner + " " + (repo.description || "")).toLowerCase()
        if (haystack.indexOf(needle) === -1) continue
      }
      out.push(repo)
    }
    return out
  }

  readonly property var tabs: {
    var counts = ({})
    var total = 0
    for (var i = 0; i < root.repos.length; i++) {
      var repo = root.repos[i]
      if (!root.includeForks && repo.fork) continue
      total++
      var key = String(repo.owner)
      counts[key] = (counts[key] || 0) + 1
    }
    var out = [{ id: "all", label: "All", count: total }]
    if (root.viewer !== "")
      out.push({ id: "@me", label: "Personal", count: counts[root.viewer] || 0 })
    for (var j = 0; j < root.orgs.length; j++) {
      var org = root.orgs[j]
      out.push({ id: org, label: org, count: counts[org] || 0 })
    }
    return out
  }

  readonly property int localCount: {
    var count = 0
    for (var i = 0; i < root.repos.length; i++)
      if (root.repos[i].localPath) count++
    return count
  }

  // The list is rendered in two groups: checkouts that already exist on this
  // machine first, then the repositories that are still only on GitHub. Both
  // keep the GitHub ordering (most recently updated first).
  readonly property var localRepos: root.filteredRepos.filter(function(repo) {
    return !!repo.localPath
  })
  readonly property var remoteRepos: root.filteredRepos.filter(function(repo) {
    return !repo.localPath
  })

  readonly property string message: root.cloneError !== ""
    ? root.cloneError
    : (root.actionError !== "" ? root.actionError : root.loadError)

  // ---- Formatting ----------------------------------------------------------

  function relativeTime(iso, nowMs) {
    if (!iso) return ""
    var then = Date.parse(iso)
    if (isNaN(then)) return ""
    var seconds = Math.max(0, (nowMs - then) / 1000)
    if (seconds < 60) return "now"
    var minutes = Math.floor(seconds / 60)
    if (minutes < 60) return minutes + "m ago"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h ago"
    var days = Math.floor(hours / 24)
    if (days < 30) return days + "d ago"
    var months = Math.floor(days / 30)
    if (months < 12) return months + "mo ago"
    return Math.floor(months / 12) + "y ago"
  }

  function ciLabel(state) {
    if (state === "SUCCESS") return "passing"
    if (state === "FAILURE") return "failing"
    if (state === "ERROR") return "error"
    if (state === "PENDING" || state === "EXPECTED") return "pending"
    return "no checks"
  }

  function ciGlyph(state) {
    if (state === "SUCCESS") return root.ciSuccessGlyph
    if (state === "FAILURE" || state === "ERROR") return root.ciFailureGlyph
    if (state === "PENDING" || state === "EXPECTED") return root.ciPendingGlyph
    return root.ciNoneGlyph
  }

  function ciColor(state) {
    if (state === "SUCCESS") return root.successColor
    if (state === "FAILURE" || state === "ERROR") return Color.urgent
    if (state === "PENDING" || state === "EXPECTED") return root.pendingColor
    return Qt.darker(root.fg, 2.0)
  }

  // ---- Data ----------------------------------------------------------------

  function refresh() {
    if (listProc.running) return
    root.loading = true
    listProc.command = ["bash", root.scriptDir + "/gh-repos", root.projectsSetting]
    listProc.running = true
  }

  function applyResult(raw) {
    var data
    try {
      data = JSON.parse(String(raw || "{}"))
    } catch (e) {
      root.loading = false
      root.loadError = "Could not read the repository list"
      return
    }

    root.loading = false
    root.loadError = String(data.error || "")
    root.warning = String(data.warning || "")
    root.repos = Array.isArray(data.repos) ? data.repos : []
    root.orgs = Array.isArray(data.orgs) ? data.orgs : []
    root.viewer = String(data.viewer || "")
    root.agent = String(data.agent || "")
    root.editor = String(data.editor || "")
    root.projectsDir = String(data.projectsDir || "")

    // A tab whose org disappeared (left the org, renamed it) falls back home.
    if (root.tab !== "all" && root.tab !== "@me" && root.orgs.indexOf(root.tab) === -1)
      root.tab = "all"
  }

  // ---- Actions -------------------------------------------------------------

  function shortPath(path) {
    var base = root.resolvedProjectsDir
    if (base && String(path).indexOf(base + "/") === 0) return String(path).slice(base.length + 1)
    return String(path)
  }

  function targetPath(repo) {
    return root.resolvedProjectsDir.replace(/\/+$/, "") + "/" + repo.name
  }

  function cloneRepo(repo) {
    if (repo.localPath || root.cloningNwo !== "") return
    root.cloneError = ""
    root.actionError = ""
    root.cloningNwo = repo.nameWithOwner
    cloneProc.command = ["gh", "repo", "clone", repo.nameWithOwner, root.targetPath(repo)]
    cloneProc.running = true
  }

  function openAgent(repo) {
    if (!repo.localPath) return
    if (root.agent === "") {
      root.actionError = "No default AI agent set. Run: omarchy default agent <name>"
      return
    }
    root.actionError = ""
    root.cloneError = ""
    Util.execDetached("cd " + Util.shellQuote(repo.localPath) + " && exec omarchy-agent")
    root.close()
  }

  function openEditor(repo) {
    if (!repo.localPath) return
    root.actionError = ""
    Util.execArgv(["omarchy-launch-editor", repo.localPath])
    root.close()
  }

  function reveal(repo) {
    if (!repo.localPath) return
    Util.execArgv(["nautilus", repo.localPath])
  }

  function revealProjects() {
    Util.execArgv(["nautilus", root.resolvedProjectsDir])
  }

  function resetScroll() {
    Qt.callLater(function() {
      if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
    })
  }

  // ---- Lifecycle -----------------------------------------------------------

  // The base Panel handler is off (manageIpc: false) so this one can expose the
  // same open/close/toggle surface plus refresh and clone for scripts.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }

    function clone(nameWithOwner: string): string {
      for (var i = 0; i < root.repos.length; i++) {
        if (root.repos[i].nameWithOwner === nameWithOwner) {
          root.cloneRepo(root.repos[i])
          return "cloning"
        }
      }
      return "unknown"
    }
  }

  Component.onCompleted: root.refresh()
  onOpenedChanged: if (root.opened) {
    root.refresh()
    root.resetScroll()
  }
  onProjectsSettingChanged: if (root.opened) root.refresh()
  onTabChanged: root.resetScroll()
  onQueryChanged: root.resetScroll()

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Keeps "3m ago" honest while the panel stays open.
  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: root.now = Date.now()
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyResult(text)
    }
    onExited: function(exitCode) {
      // The collector normally beats this; if it did not, do not leave the
      // panel stuck on "loading".
      Qt.callLater(function() {
        if (!root.loading) return
        root.loading = false
        if (root.loadError === "" && exitCode !== 0)
          root.loadError = "Could not read the repository list"
      })
    }
  }

  Process {
    id: cloneProc
    stdout: StdioCollector { id: cloneOut; waitForEnd: true }
    stderr: StdioCollector { id: cloneErr; waitForEnd: true }
    onExited: function(exitCode) {
      var target = root.cloningNwo
      root.cloningNwo = ""
      if (exitCode === 0) {
        root.cloneError = ""
        root.refresh()
        return
      }
      var detail = String(cloneErr.text || cloneOut.text || "").trim()
      root.cloneError = detail !== "" ? detail : ("Could not clone " + target)
    }
  }

  // ---- Bar button ----------------------------------------------------------

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.gitGlyph
    dimmed: root.repos.length === 0 && !root.loading
    tooltipText: root.repos.length === 0
      ? (root.loadError !== "" ? root.loadError : "GitHub repositories")
      : root.localCount + " of " + root.repos.length + " repositories cloned"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else if (b === Qt.RightButton) root.revealProjects()
      else root.toggle()
    }
  }

  // ---- Panel ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(620))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(660))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: searchField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: root.refresh()

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: contentColumn.implicitHeight > height
          ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: contentColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "GitHub"
            meta: root.repos.length === 0
              ? (root.loading ? "Reading from gh…" : "No repositories")
              : root.repos.length + (root.repos.length === 1 ? " repository" : " repositories")
                + "  ·  " + root.localCount + " local"
            detail: root.viewer
            foreground: root.fg
            fontFamily: root.ff
            iconOpacity: root.repos.length > 0 ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                text: root.githubGlyph
                color: root.fg
                font.family: root.ff
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              PanelActionButton {
                iconText: root.refreshGlyph
                tooltipText: "Refresh repositories"
                foreground: root.fg
                fontFamily: root.ff
                onClicked: root.refresh()
              }
            }
          }

          Text {
            width: parent.width
            visible: root.message !== ""
            text: root.message
            textFormat: Text.PlainText
            color: Color.urgent
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          Text {
            width: parent.width
            visible: root.warning !== ""
            text: root.warning
            textFormat: Text.PlainText
            color: Qt.darker(root.fg, 1.6)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            wrapMode: Text.Wrap
          }

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Filter by name, owner or description"
            foreground: root.fg
            font.family: root.ff
            onTextChanged: root.query = text
            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: keyCatcher.forceActiveFocus()
            Keys.onDownPressed: keyCatcher.forceActiveFocus()
          }

          Flow {
            width: parent.width
            spacing: Style.spacing.xs

            Repeater {
              model: root.tabs

              Button {
                required property var modelData
                text: modelData.label + "  " + modelData.count
                fontSize: Style.font.caption
                horizontalPadding: Style.spacing.md
                verticalPadding: Style.spacing.xs
                foreground: root.fg
                fontFamily: root.ff
                selected: root.tab === modelData.id
                onClicked: root.tab = modelData.id
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          Text {
            width: parent.width
            visible: !root.loading && root.filteredRepos.length === 0
            text: root.repos.length === 0
              ? "No repositories found"
              : "No repository matches this filter"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.ff
            font.pixelSize: Style.font.body
          }

          // ---- Already cloned on this machine ------------------------------
          PanelSectionHeader {
            width: parent.width
            visible: root.localRepos.length > 0
            text: "Already cloned  ·  " + root.localRepos.length
            foreground: root.fg
            fontFamily: root.ff
          }

          Repeater {
            model: root.localRepos
            delegate: repoRowDelegate
          }

          // A soft rule only when both groups are on screen, so the split reads
          // as two sections without cutting the panel in half.
          PanelSeparator {
            visible: root.localRepos.length > 0 && root.remoteRepos.length > 0
            foreground: root.fg
            strength: 0.08
          }

          // ---- Still only on GitHub ----------------------------------------
          PanelSectionHeader {
            width: parent.width
            visible: root.remoteRepos.length > 0
            text: "Not cloned  ·  " + root.remoteRepos.length
            foreground: root.fg
            fontFamily: root.ff
          }

          Repeater {
            model: root.remoteRepos
            delegate: repoRowDelegate
          }

          Component {
            id: repoRowDelegate

            Item {
              id: repoRow
              required property var modelData
              width: contentColumn.width
              height: repoBody.implicitHeight + Style.space(22)

              RowLayout {
                id: repoBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: Style.space(11)
                spacing: Style.space(9)

                Text {
                  text: repoRow.modelData.localPath ? root.checkGlyph : root.branchGlyph
                  color: repoRow.modelData.localPath ? root.fg : Qt.darker(root.fg, 1.7)
                  font.family: root.ff
                  font.pixelSize: Style.font.body
                  Layout.alignment: Qt.AlignTop
                  Layout.topMargin: Style.space(2)
                }

                Column {
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignTop
                  spacing: Style.space(5)

                  // Name on its own line, with the private marker beside it.
                  Row {
                    width: parent.width
                    spacing: Style.space(5)

                    Text {
                      text: repoRow.modelData.name
                      textFormat: Text.PlainText
                      color: root.fg
                      font.family: root.ff
                      font.pixelSize: Style.font.subtitle
                      font.bold: !!repoRow.modelData.localPath
                      elide: Text.ElideRight
                      width: Math.min(implicitWidth, Math.max(0, parent.width - (privateGlyph.visible
                        ? privateGlyph.implicitWidth + Style.space(5) : 0)))
                    }

                    Text {
                      id: privateGlyph
                      visible: !!repoRow.modelData.private
                      text: root.lockGlyph
                      color: Qt.darker(root.fg, 1.7)
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  // Description gets a line of its own instead of sharing the
                  // row with the owner and the counts.
                  Text {
                    width: parent.width
                    visible: repoRow.modelData.description !== ""
                    text: repoRow.modelData.description
                    textFormat: Text.PlainText
                    color: Qt.darker(root.fg, 1.45)
                    font.family: root.ff
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: root.cloningNwo === repoRow.modelData.nameWithOwner
                    text: "Cloning into " + root.targetPath(repoRow.modelData) + "…"
                    textFormat: Text.PlainText
                    color: root.pendingColor
                    font.family: root.ff
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }

                  // Metadata sits on its own line, one chip per fact, wrapping
                  // when the panel is narrow.
                  Flow {
                    width: parent.width
                    spacing: Style.space(12)

                    Text {
                      text: repoRow.modelData.owner
                      textFormat: Text.PlainText
                      color: Qt.darker(root.fg, 1.6)
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      text: root.clockGlyph + "  " + root.relativeTime(repoRow.modelData.lastCommit, root.now)
                      color: Qt.darker(root.fg, 1.6)
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      visible: Number(repoRow.modelData.issues) > 0
                      text: root.issueGlyph + "  " + String(repoRow.modelData.issues)
                      color: Qt.darker(root.fg, 1.35)
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      visible: Number(repoRow.modelData.prs) > 0
                      text: root.prGlyph + "  " + String(repoRow.modelData.prs)
                      color: Qt.darker(root.fg, 1.35)
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                    }

                    Row {
                      spacing: Style.space(3)

                      Text {
                        text: root.ciGlyph(repoRow.modelData.ci)
                        color: root.ciColor(repoRow.modelData.ci)
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        text: root.ciLabel(repoRow.modelData.ci)
                        color: root.ciColor(repoRow.modelData.ci)
                        font.family: root.ff
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Text {
                      visible: !!repoRow.modelData.localPath
                      text: root.folderGlyph + "  " + root.shortPath(repoRow.modelData.localPath)
                      textFormat: Text.PlainText
                      color: Qt.darker(root.fg, 1.75)
                      font.family: root.ff
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                      width: Math.min(implicitWidth, parent.width)
                    }
                  }
                }

                // Actions sit against the name line so the taller row does not
                // push them around.
                Row {
                  Layout.alignment: Qt.AlignTop
                  spacing: Style.space(3)

                  PanelActionButton {
                    visible: !!repoRow.modelData.localPath
                    iconText: root.aiGlyph
                    tooltipText: root.agent !== ""
                      ? "Open in " + root.agent + " (" + root.shortPath(repoRow.modelData.localPath) + ")"
                      : "No default AI agent set"
                    foreground: root.fg
                    fontFamily: root.ff
                    onClicked: root.openAgent(repoRow.modelData)
                  }

                  PanelActionButton {
                    visible: !!repoRow.modelData.localPath
                    iconText: root.editorText
                    tooltipText: "Open in " + (root.editor !== "" ? root.editor : "editor")
                    foreground: root.fg
                    fontFamily: root.ff
                    onClicked: root.openEditor(repoRow.modelData)
                  }

                  PanelActionButton {
                    visible: !!repoRow.modelData.localPath
                    iconText: root.folderGlyph
                    tooltipText: "Show in Files"
                    foreground: root.fg
                    fontFamily: root.ff
                    onClicked: root.reveal(repoRow.modelData)
                  }

                  // Not cloned: clone into the Projects folder.
                  PanelActionButton {
                    visible: !repoRow.modelData.localPath
                    enabled: root.cloningNwo === ""
                    iconText: root.cloningNwo === repoRow.modelData.nameWithOwner
                      ? root.spinnerGlyph : root.downloadGlyph
                    tooltipText: root.cloningNwo === repoRow.modelData.nameWithOwner
                      ? "Cloning…"
                      : "Clone into " + root.targetPath(repoRow.modelData)
                    foreground: root.fg
                    fontFamily: root.ff
                    onClicked: root.cloneRepo(repoRow.modelData)
                  }
                }
              }

              PanelSeparator {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                foreground: root.fg
                strength: 0.05
              }
            }
          }

          Text {
            width: parent.width
            visible: root.filteredRepos.length > 0
            text: root.filteredRepos.length + " shown  ·  right-click the bar icon to open "
              + root.resolvedProjectsDir
            textFormat: Text.PlainText
            color: Qt.darker(root.fg, 1.8)
            font.family: root.ff
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }
}
