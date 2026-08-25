import QtQuick
import Quickshell
import Quickshell.Io

// One service is mounted for the shell session while Panel.qml is instantiated
// once per monitor. All backend traffic and mutable composer state live here.
QtObject {
  id: root

  property var shell: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string backendPath: home + "/.config/omarchy/plugins/ryan.xtweet/backend.py"

  property string mode: "intent"
  property string modeLabel: "Browser composer"
  property bool paid: false
  readonly property bool paidApi: mode === "api" && paid
  readonly property string actionLabel: paidApi ? "Post" : "Continue in X"

  property string draft: ""
  property int draftRevision: 0
  property string lastPersistedDraft: ""
  property int draftStorageRevision: 0

  property bool posting: false
  property bool finalizingDraft: false
  property string jobId: ""
  property string jobState: ""
  property string submittedText: ""
  property int submittedRevision: -1
  property int submittedStorageRevision: -1
  property string statusText: "Starting…"
  property string reconcileJobId: ""
  property bool statusError: false

  property bool modeChecked: false
  property bool draftChecked: false
  property bool activeChecked: false
  property bool startupHadError: false
  readonly property bool ready: modeChecked && draftChecked && activeChecked
  readonly property bool busy: posting

  property var operationQueue: []
  property var activeOperation: null
  property bool processStarted: false
  property bool processExited: false
  property bool outputFinished: false
  property int processExitCode: -1
  property string operationOutput: ""

  signal closePanelsRequested()

  function safeMessage(value, fallback) {
    var text = String(value || "").replace(/\s+/g, " ").trim()
    // Backend diagnostics must never turn an intent URL (and its draft) into UI.
    return text && !/https?:\/\//i.test(text) ? text : fallback
  }

  function isTerminal(state) {
    return state === "posted" || state === "handoff"
      || state === "rejected" || state === "unknown"
  }

  function hasOperation(kind) {
    if (activeOperation && activeOperation.kind === kind) return true
    for (var i = 0; i < operationQueue.length; i++) {
      if (operationQueue[i].kind === kind) return true
    }
    return false
  }

  function queueOperation(operation, priority) {
    var next = operationQueue.slice()
    var replacementIndex = -1

    // Draft writes are snapshots. A newer ordinary snapshot supersedes an
    // older queued one at the same queue position, so a pending enqueue never
    // jumps ahead of the persistence that guarded it. The posted-state clear
    // is never superseded because its success gates terminal acknowledgement.
    if (operation.kind === "draft-set" || operation.kind === "draft-clear") {
      var filtered = []
      for (var i = 0; i < next.length; i++) {
        var queued = next[i]
        var isDraftWrite = queued.kind === "draft-set" || queued.kind === "draft-clear"
        if (isDraftWrite && !queued.ackAfter) {
          if (replacementIndex < 0) replacementIndex = filtered.length
        } else {
          filtered.push(queued)
        }
      }
      next = filtered
    }

    if (priority) next.unshift(operation)
    else if (replacementIndex >= 0) next.splice(replacementIndex, 0, operation)
    else next.push(operation)
    operationQueue = next
    startNextOperation()
  }

  function startNextOperation() {
    if (activeOperation || operationProcess.running || operationQueue.length === 0) return

    var next = operationQueue.slice()
    var operation = next.shift()
    operationQueue = next
    activeOperation = operation
    processStarted = false
    processExited = false
    outputFinished = false
    processExitCode = -1
    operationOutput = ""

    operationProcess.command = [backendPath].concat(operation.args || [])
    operationProcess.stdinEnabled = !!operation.stdin
    operationProcess.running = true
    processStartTimeout.restart()
  }

  function confirmStartFailure() {
    if (!activeOperation || processStarted || processExited || operationProcess.running) return
    finishStartFailure()
  }

  function finishStartFailure() {
    if (!activeOperation) return
    processStartTimeout.stop()
    var operation = activeOperation
    var abandoned = operationQueue.slice()
    activeOperation = null
    operationQueue = []

    completeStartupCheck(operation)
    failOperation(operation, "X composer backend could not start.")
    for (var i = 0; i < abandoned.length; i++) {
      completeStartupCheck(abandoned[i])
    }

    // Losing only a status observer must not release the global Posting state:
    // the detached worker may still complete, and polling can recover once
    // the backend is available again.
    if (operation.kind === "status" && jobId) {
      posting = true
      if (jobState !== "queued") jobState = "running"
    } else {
      posting = false
      if (jobId && !isTerminal(jobState)) jobState = "unknown"
      else if (!jobId && jobState === "queued") jobState = ""
    }
  }

  function maybeFinishOperation() {
    if (!activeOperation || !processExited || !outputFinished) return

    processStartTimeout.stop()
    var operation = activeOperation
    var exitCode = processExitCode
    var output = operationOutput
    activeOperation = null

    var response = null
    try {
      response = JSON.parse(String(output || "").trim())
    } catch (error) {
      response = null
    }

    completeStartupCheck(operation)
    if (!response || typeof response !== "object") {
      failOperation(operation, "The X composer backend returned an invalid response.")
    } else {
      handleOperation(operation, response, exitCode)
    }
    Qt.callLater(startNextOperation)
  }

  function completeStartupCheck(operation) {
    if (operation.startup === "mode") modeChecked = true
    else if (operation.startup === "draft") draftChecked = true
    else if (operation.startup === "active") activeChecked = true

    if (ready && !startupHadError && !posting && jobState === ""
        && statusText === "Starting…") {
      statusText = ""
    }
  }

  function failOperation(operation, fallback) {
    if (operation.startup) startupHadError = true

    if (operation.kind === "enqueue") {
      posting = false
      jobState = ""
      jobId = ""
    } else if (operation.kind === "status") {
      posting = true
      if (jobState !== "queued") jobState = "running"
      statusText = fallback + " Retrying…"
      statusError = true
      return
    }
    if (operation.ackAfter) {
      // CAS refused the posted-draft clear because durable text changed.
      // Keep the editor locked until that newer draft is loaded.
      finalizingDraft = true
      posting = true
      statusText = "Posted; restoring the newer saved draft…"
      statusError = false
      queueOperation({
        kind: "draft-get",
        args: ["draft", "get"],
        revision: draftRevision,
        reconcileAfter: operation.ackAfter
      }, true)
      return
    }
    if (operation.reconcileAfter) {
      finalizingDraft = true
      posting = true
      reconcileJobId = operation.reconcileAfter
      statusText = "Posted; saved-draft reload failed. Retrying…"
      statusError = true
      draftReconcileRetry.restart()
      return
    }
    if (operation.kind !== "ack") {
      statusText = fallback
      statusError = true
    }
  }

  function handleOperation(operation, response, exitCode) {
    if (operation.kind === "enqueue" && response.ok !== true
        && response.kind === "busy" && response.jobId) {
      jobId = String(response.jobId)
      submittedRevision = -1
      submittedStorageRevision = -1
      jobState = "queued"
      posting = true
      statusText = safeMessage(response.message, "A post is already in progress.")
      statusError = false
      queueStatus()
      return
    }
    if (operation.kind === "enqueue" && response.ok !== true
        && response.kind === "mode-changed") {
      applyMode(response)
    }
    if (response.ok !== true || (exitCode !== 0 && response.ok !== true)) {
      failOperation(operation,
        safeMessage(response.message, failureMessage(operation.kind)))
      return
    }

    switch (operation.kind) {
    case "mode":
      applyMode(response)
      break
    case "draft-get":
      applyLoadedDraft(operation, response)
      if (operation.reconcileAfter) {
        finalizingDraft = false
        posting = false
        reconcileJobId = ""
        draftReconcileRetry.stop()
        closePanelsRequested()
        queueAck(operation.reconcileAfter)
      }
      break
    case "draft-set":
      lastPersistedDraft = operation.text
      if (typeof response.revision === "number") {
        draftStorageRevision = response.revision
      }
      break
    case "draft-clear":
      lastPersistedDraft = operation.text
      if (typeof response.revision === "number") {
        draftStorageRevision = response.revision
      }
      if (operation.clearPostedDraft) {
        if (draft === operation.expectedText
            && draftRevision === operation.localRevision) {
          draft = ""
          draftRevision += 1
        }
        finalizingDraft = false
        posting = false
        closePanelsRequested()
      }
      if (operation.ackAfter) queueAck(operation.ackAfter)
      break
    case "active":
      handleActive(response)
      break
    case "enqueue":
      handleEnqueued(operation, response)
      break
    case "status":
      handleStatus(response)
      break
    case "ack":
      if (jobId === operation.jobId && isTerminal(jobState)) jobId = ""
      break
    }
  }

  function failureMessage(kind) {
    switch (kind) {
    case "mode": return "Could not read the posting mode."
    case "draft-get": return "Could not load the saved draft."
    case "draft-set":
    case "draft-clear": return "Could not save the draft."
    case "active": return "Could not check for an active post."
    case "enqueue": return "Could not start posting."
    case "status": return "Could not check the post status."
    default: return "The X composer backend operation failed."
    }
  }

  function applyMode(response) {
    var nextMode = String(response.mode || "intent")
    var nextPaid = response.paid === true
    // Fail closed: API presentation requires both backend assertions.
    mode = nextMode === "api" && nextPaid ? "api" : "intent"
    paid = mode === "api"
    modeLabel = safeMessage(response.label,
      paidApi ? "Paid X API" : "Browser composer")
  }

  function updateModeName(value, label) {
    if (String(value || "") === "api") {
      mode = "api"
      paid = true
    } else {
      mode = "intent"
      paid = false
    }
    if (label) modeLabel = safeMessage(label,
      paidApi ? "Paid X API" : "Browser composer")
  }

  function applyLoadedDraft(operation, response) {
    var loaded = String(response.text || "")
    lastPersistedDraft = loaded
    if (typeof response.revision === "number") {
      draftStorageRevision = response.revision
    }
    if (draftRevision !== operation.revision) return
    draft = loaded
  }

  function handleActive(response) {
    var active = response.active
    if (active === null) {
      if (!posting && jobState === "") {
        if (!startupHadError) statusText = ""
        statusError = startupHadError
      }
      return
    }
    if (active && typeof active === "object") handleStatus(active)
    else if (response.jobId) handleStatus(response)
  }

  function handleEnqueued(operation, response) {
    updateModeName(response.mode, response.label)
    jobId = String(response.jobId || "")
    submittedText = operation.text
    if (typeof response.draftRevision === "number") {
      submittedStorageRevision = response.draftRevision
    }
    jobState = "queued"
    posting = true
    statusText = paidApi ? "Posting…" : "Opening composer…"
    statusError = false
    queueStatus()
  }

  function handleStatus(response) {
    var state = String(response.state || "")
    var responseJobId = String(response.jobId || jobId)
    if (!responseJobId || !state) {
      posting = true
      if (jobState !== "queued") jobState = "running"
      statusText = "Post status was incomplete. Retrying…"
      statusError = true
      return
    }

    updateModeName(response.mode, response.label)
    var newJob = responseJobId !== jobId
    jobId = responseJobId
    jobState = state
    if (newJob) {
      submittedText = ""
      submittedRevision = -1
      submittedStorageRevision = -1
    }
    if (typeof response.submittedText === "string") {
      submittedText = response.submittedText
      if (newJob || submittedRevision < 0) {
        submittedRevision = draft === submittedText ? draftRevision : -1
      }
    }
    if (typeof response.draftRevision === "number") {
      submittedStorageRevision = response.draftRevision
    }

    if (state === "queued" || state === "running") {
      posting = true
      statusText = safeMessage(response.message,
        paidApi ? "Posting…" : "Opening composer…")
      statusError = false
      return
    }

    if (state === "posted") {
      statusText = "Posted"
      statusError = false
      var sameLocalDraft = submittedRevision >= 0
        && draftRevision === submittedRevision
      var sameStoredDraft = submittedStorageRevision >= 0
        && draftStorageRevision === submittedStorageRevision
      if (submittedText !== "" && draft === submittedText
          && sameLocalDraft && sameStoredDraft) {
        finalizingDraft = true
        posting = true
        draftSaveDebounce.stop()
        queueOperation({
          kind: "draft-clear",
          args: ["draft", "clear", String(submittedStorageRevision)],
          text: "",
          expectedText: submittedText,
          localRevision: submittedRevision,
          clearPostedDraft: true,
          ackAfter: jobId
        }, true)
      } else {
        posting = false
        closePanelsRequested()
        queueAck(jobId)
      }
    } else if (state === "handoff") {
      posting = false
      finalizingDraft = false
      statusText = "Composer opened"
      statusError = false
      closePanelsRequested()
      queueAck(jobId)
    } else if (state === "rejected") {
      posting = false
      finalizingDraft = false
      statusText = safeMessage(response.message, "Post rejected.")
      statusError = true
      queueAck(jobId)
    } else if (state === "unknown") {
      posting = false
      finalizingDraft = false
      statusText = safeMessage(response.message, "Posting outcome unknown.")
      statusError = true
      queueAck(jobId)
    } else {
      posting = false
      finalizingDraft = false
      jobState = "unknown"
      statusText = "The backend returned an unknown post state."
      statusError = true
    }
  }

  function setDraft(text) {
    var next = String(text || "")
    if (draft === next) return
    draft = next
    draftRevision += 1
    draftSaveDebounce.restart()

    if (!posting && (jobState === "posted" || jobState === "handoff")) {
      jobState = ""
      statusText = ""
      statusError = false
    }
  }

  function compose(text) {
    if (posting) return "busy"
    if (!ready) return "not-ready"
    setDraft(text)
    return "ok"
  }

  function submit() {
    if (!ready || posting) return false
    var snapshot = String(draft || "")
    if (snapshot.trim().length === 0) return false

    posting = true
    jobId = ""
    jobState = "queued"
    submittedText = snapshot
    submittedRevision = draftRevision
    submittedStorageRevision = draftStorageRevision
    statusText = "Preparing…"
    statusError = false

    draftSaveDebounce.stop()
    refreshMode()
    queueDraftPersistence(snapshot)
    queueOperation({
      kind: "enqueue",
      args: ["enqueue"],
      stdin: JSON.stringify({ text: snapshot, expectedMode: mode }) + "\n",
      text: snapshot
    })
    return true
  }

  function refreshMode() {
    if (hasOperation("mode")) return
    queueOperation({ kind: "mode", args: ["mode"] })
  }

  function queueDraftPersistence(snapshot) {
    var text = String(snapshot || "")
    if (text === lastPersistedDraft) return
    queueOperation(text === ""
      ? { kind: "draft-clear", args: ["draft", "clear"], text: "" }
      : {
          kind: "draft-set",
          args: ["draft", "set"],
          stdin: JSON.stringify({ text: text }) + "\n",
          text: text
        })
  }

  function queueStatus() {
    if (!jobId || hasOperation("status")) return
    queueOperation({ kind: "status", args: ["status", jobId], jobId: jobId })
  }

  function queueAck(id) {
    var terminalJob = String(id || "")
    if (!terminalJob) return
    for (var i = 0; i < operationQueue.length; i++) {
      if (operationQueue[i].kind === "ack"
          && operationQueue[i].jobId === terminalJob) return
    }
    if (activeOperation && activeOperation.kind === "ack"
        && activeOperation.jobId === terminalJob) return
    queueOperation({ kind: "ack", args: ["ack", terminalJob], jobId: terminalJob }, true)
  }

  property Timer draftReconcileRetry: Timer {
    interval: 1000
    onTriggered: {
      if (!reconcileJobId || hasOperation("draft-get")) return
      queueOperation({
        kind: "draft-get",
        args: ["draft", "get"],
        revision: draftRevision,
        reconcileAfter: reconcileJobId
      }, true)
    }
  }

  property Timer draftSaveDebounce: Timer {
    interval: 350
    onTriggered: root.queueDraftPersistence(root.draft)
  }

  property Timer statusPoll: Timer {
    interval: 750
    repeat: true
    running: root.posting && root.jobId !== ""
    onTriggered: root.queueStatus()
  }

  property Timer processStartTimeout: Timer {
    interval: 5000
    onTriggered: root.confirmStartFailure()
  }

  property Process operationProcess: Process {
    command: []

    stdout: StdioCollector {
      id: operationStdout
      waitForEnd: true
      onStreamFinished: {
        if (!root.activeOperation) return
        root.operationOutput = String(operationStdout.text || "")
        root.outputFinished = true
        root.maybeFinishOperation()
      }
    }

    // Consume diagnostics without forwarding them to the shell log. Some
    // backend operations carry draft text, which must never become a log URL.
    stderr: StdioCollector { waitForEnd: true }

    onStarted: {
      if (!root.activeOperation) {
        operationProcess.signal(15)
        return
      }
      root.processStarted = true
      root.processStartTimeout.stop()
      if (root.activeOperation.stdin) {
        operationProcess.write(root.activeOperation.stdin)
        operationProcess.stdinEnabled = false
      }
    }

    onExited: function(exitCode) {
      if (!root.activeOperation) return
      root.processExited = true
      root.processExitCode = exitCode
      root.maybeFinishOperation()
    }

    onRunningChanged: {
      if (!running && root.activeOperation && !root.processStarted
          && !root.processExited) {
        Qt.callLater(root.confirmStartFailure)
      } else if (!running && !root.activeOperation) {
        Qt.callLater(root.startNextOperation)
      }
    }
  }

  Component.onCompleted: {
    queueOperation({ kind: "mode", args: ["mode"], startup: "mode" })
    queueOperation({
      kind: "draft-get",
      args: ["draft", "get"],
      revision: draftRevision,
      startup: "draft"
    })
    queueOperation({ kind: "active", args: ["active"], startup: "active" })
  }
}
