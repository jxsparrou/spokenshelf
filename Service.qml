import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Io
import "lib/Api.js" as Api

Item {
  id: root

  property var shell: null
  property string server: ""
  property string token: ""
  property string error: ""
  property bool loading: false
  property bool connected: false
  property string authenticationMethod: ""
  property var libraries: []
  property var books: []
  property var libraryBooks: []
  property var continueBooks: []
  property var recentBooks: []
  property var searchBooks: []
  property string searchQuery: ""
  property int searchGeneration: 0
  property bool libraryLoading: false
  property var librarySearchIndex: []
  property var mediaProgress: ({})
  property bool searching: false
  property string selectedLibraryId: ""
  property var currentItem: null
  property var currentTracks: []
  property var currentChapters: []
  property int currentTrackIndex: 0
  property string sessionId: ""
  property real sessionDuration: 0
  property double playbackStartedAt: 0
  property real listenedSinceSync: 0
  property bool localPlayback: false
  property real pendingSeekPosition: -1
  property string downloadStatus: ""
  property var requestQueue: []
  property var activeRequest: null
  property bool requestOutputHandled: false
  property string tokenToStore: ""
  property var offlineBooks: ({})
  property var queuedSessions: []
  property var user: null
  property bool browsingOffline: false
  property int downloadTrackIndex: -1
  property string localSessionId: ""
  property real localSessionStartTime: 0
  property double localSessionStartedAt: 0
  property real localTimeListening: 0
  property bool syncingOfflineSessions: false
  property var offlineSyncCallbacks: []
  property bool loadingProgress: false
  property var progressLoadCallbacks: []
  property bool progressReloadPending: false
  property var progressReloadCallbacks: []
  property int playbackGeneration: 0
  property bool playbackStartPending: false
  property bool streamStartPending: false
  property double pausedAt: 0
  property var unsyncedStreamProgress: ({})
  property var dirtyStreamProgress: ({})
  property alias playbackVolume: audioOutput.volume
  property double downloadBytes: 0
  property double downloadCompletedBytes: 0
  property double downloadTotalBytes: 0
  property string downloadPath: ""
  property var downloadItem: null
  property var downloadTracks: []
  property var downloadChapters: []
  property string downloadServer: ""
  property string downloadToken: ""
  property string downloadUserId: ""
  property var downloadProgressRecord: null
  property bool loggingOut: false
  property bool promptAfterLogout: false
  property bool clearingCredentials: false
  property string localSessionServer: ""
  property string localSessionUserId: ""
  property bool zenityAvailable: false
  property bool zenityChecked: false
  property bool credentialPromptPending: false
  property bool mprisAvailable: false
  property int mprisFailureCount: 0
  property string dependencyError: ""
  property string dependencyWarning: ""
  property string selectedAudioOutputId: ""
  property var audioOutputOptions: []

  signal credentialPromptStarting()
  signal credentialPromptUnavailable()

  readonly property bool isPlaying: player.playbackState === MediaPlayer.PlayingState
  readonly property int resumeRewindSeconds: 5
  readonly property int resumeRewindPauseMs: 10000
  readonly property real trackStartOffset: currentTracks.length > currentTrackIndex ? Number(currentTracks[currentTrackIndex].startOffset || 0) : 0
  readonly property real position: trackStartOffset + player.position / 1000
  readonly property real duration: sessionDuration > 0 ? sessionDuration : player.duration / 1000
  readonly property string title: currentItem && currentItem.media && currentItem.media.metadata ? currentItem.media.metadata.title : ""
  readonly property string author: currentItem && currentItem.media && currentItem.media.metadata ? currentItem.media.metadata.authorName || "" : ""
  readonly property string progressLabel: Api.secondsLabel(position) + " / " + Api.secondsLabel(duration)
  readonly property string positionLabel: Api.secondsLabel(position)
  readonly property string durationLabel: Api.secondsLabel(duration)
  readonly property string remainingLabel: "-" + Api.secondsLabel(Math.max(0, duration - position))
  readonly property string chapterTitle: chapterAt(position)
  readonly property var currentChapter: chapterFor(position)
  readonly property real chapterStart: currentChapter ? Number(currentChapter.start || 0) : 0
  readonly property real chapterDuration: currentChapter ? Math.max(0, Number(currentChapter.end || duration) - chapterStart) : 0
  readonly property real chapterPosition: currentChapter ? Math.max(0, Math.min(chapterDuration, position - chapterStart)) : 0
  readonly property real chapterProgress: chapterDuration > 0 ? chapterPosition / chapterDuration : 0
  readonly property int chapterNumber: currentChapter ? currentChapters.indexOf(currentChapter) + 1 : 0
  readonly property real bookProgress: duration > 0 ? Math.max(0, Math.min(1, position / duration)) : 0
  readonly property string stateDirectory: Quickshell.env("HOME") + "/.local/state/omarchy-audiobookshelf"
  readonly property string serverName: server.replace(/^https?:\/\//, "").split("/")[0]
  readonly property bool downloading: downloadProcess.running || downloadTrackIndex >= 0
  readonly property bool currentDownloaded: currentItem && (localPlayback || isDownloaded(currentItem.id))
  readonly property real downloadProgress: downloadTotalBytes > 0 ? Math.min(downloadBytes / downloadTotalBytes, 1) : 0
  readonly property string downloadProgressLabel: Math.round(downloadProgress * 100) + "% - " + formatBytes(downloadBytes) + " / " + formatBytes(downloadTotalBytes)

  function apiUrl(path) { return server + path }

  function selectServer(serverUrl) {
    var normalized = Api.normalizeServer(serverUrl)
    if (server !== "" && normalized !== server) mediaProgress = ({})
    server = normalized
    return server
  }

  function coverUrl(item, width) {
    if (!item || !item.id) return ""
    var itemServer = item._spokenShelfServer || server
    if (itemServer === "") return ""
    return itemServer + "/api/items/" + encodeURIComponent(item.id) + "/cover?width=" + Number(width || 160) + "&format=webp&ts=" + Number(item.updatedAt || 0)
  }

  function progressForItem(itemId) {
    return mediaProgress[itemId] || null
  }

  function isDownloaded(itemId) {
    return offlineEntry(itemId, server, user ? user.id : "") !== null
  }

  function offlineKey(itemId, itemServer, itemUserId) {
    return String(itemServer || server) + "|" + String(itemUserId || (user ? user.id : "")) + "|" + itemId
  }

  function offlineEntry(itemId, itemServer, itemUserId) {
    var entryServer = itemServer || server
    var entryUserId = String(itemUserId || (connected && user ? user.id : ""))
    var scoped = offlineBooks[offlineKey(itemId, entryServer, entryUserId)]
    if (scoped) return scoped
    var legacy = offlineBooks[entryServer + "|" + itemId] || (!connected && !itemServer ? offlineBooks[itemId] : null)
    if (legacy && (entryUserId === "" || String(legacy.userId || "") === entryUserId)) return legacy
    return null
  }

  function offlineBookList() {
    var items = []
    for (var id in offlineBooks) {
      var entry = offlineBooks[id]
      if ((!connected || !entry.server || entry.server === server)
          && (!connected || (entry.userId && user && String(entry.userId) === String(user.id)))) {
        var item = Object.assign({}, entry.item)
        item._spokenShelfServer = entry.server || ""
        item._spokenShelfUserId = entry.userId || ""
        items.push(item)
      }
    }
    return items
  }

  function downloadDirectory(itemId, itemServer, itemUserId) {
    var value = String(itemServer || server) + "|" + String(itemUserId || (user ? user.id : ""))
    var hash = 2166136261
    for (var i = 0; i < value.length; i++) hash = Math.imul(hash ^ value.charCodeAt(i), 16777619)
    return stateDirectory + "/downloads/" + (hash >>> 0).toString(16) + "/" + safeItemId(itemId)
  }

  function migrateOfflineBooks(entries) {
    var migrated = ({})
    var changed = false
    for (var key in entries) {
      var entry = entries[key]
      var scopedKey = entry && entry.server && entry.item && entry.item.id
        ? entry.server + "|" + String(entry.userId || "") + "|" + entry.item.id : key
      if (scopedKey !== key) {
        migrated[scopedKey] = entry
        changed = true
      } else {
        migrated[key] = entry
      }
    }
    if (changed) offlineIndex.setText(JSON.stringify(migrated, null, 2) + "\n")
    return migrated
  }

  function safeItemId(itemId) {
    var value = String(itemId || "")
    return /^[A-Za-z0-9._-]+$/.test(value) ? value : ""
  }

  function trustedMediaUrl(contentUrl, expectedServer) {
    var value = String(contentUrl || "")
    var origin = expectedServer || server
    if (value.indexOf("http") !== 0) return origin + value
    return value === origin || value.indexOf(origin + "/") === 0 ? value : ""
  }

  function chapterFor(seconds) {
    for (var i = 0; i < currentChapters.length; i++) {
      var chapter = currentChapters[i]
      if (seconds >= Number(chapter.start || 0) && seconds < Number(chapter.end || duration)) return chapter
    }
    return null
  }

  function chapterAt(seconds) {
    var chapter = chapterFor(seconds)
    return chapter ? chapter.title || "" : ""
  }

  function chaptersFromTracks(tracks) {
    var chapters = []
    for (var i = 0; i < tracks.length; i++) {
      var track = tracks[i]
      var trackChapters = track.metadata && track.metadata.chapters ? track.metadata.chapters : (track.chapters || [])
      var offset = Number(track.startOffset || 0)
      for (var j = 0; j < trackChapters.length; j++) {
        var chapter = Object.assign({}, trackChapters[j])
        chapter.start = Number(chapter.start || 0) + offset
        chapter.end = Number(chapter.end || 0) + offset
        chapters.push(chapter)
      }
    }
    return chapters
  }

  function formatBytes(bytes) {
    var value = Number(bytes || 0)
    if (value < 1024) return Math.round(value) + " B"
    if (value < 1024 * 1024) return (value / 1024).toFixed(1) + " KB"
    if (value < 1024 * 1024 * 1024) return (value / (1024 * 1024)).toFixed(1) + " MB"
    return (value / (1024 * 1024 * 1024)).toFixed(1) + " GB"
  }

  function formatDuration(seconds) {
    return Api.secondsLabel(Number(seconds || 0))
  }

  function setVolume(value) {
    audioOutput.volume = Math.max(0, Math.min(1, Number(value || 0)))
  }

  function refreshAudioOutputs() {
    var defaultDescription = String(mediaDevices.defaultAudioOutput.description || "")
    var options = [{
      value: "",
      label: defaultDescription === "" ? "System default" : "System default (" + defaultDescription + ")"
    }]
    var selectedFound = selectedAudioOutputId === ""
    for (var i = 0; i < mediaDevices.audioOutputs.length; i++) {
      var device = mediaDevices.audioOutputs[i]
      var deviceId = String(device.id)
      options.push({ value: deviceId, label: String(device.description || "Audio output " + (i + 1)) })
      if (deviceId === selectedAudioOutputId) selectedFound = true
    }
    audioOutputOptions = options
    if (!selectedFound) selectedAudioOutputId = ""
    applyAudioOutput()
  }

  function setAudioOutput(deviceId) {
    selectedAudioOutputId = String(deviceId || "")
    applyAudioOutput()
  }

  function applyAudioOutput() {
    if (selectedAudioOutputId === "") {
      audioOutput.device = mediaDevices.defaultAudioOutput
      return
    }
    for (var i = 0; i < mediaDevices.audioOutputs.length; i++) {
      if (String(mediaDevices.audioOutputs[i].id) === selectedAudioOutputId) {
        audioOutput.device = mediaDevices.audioOutputs[i]
        return
      }
    }
    selectedAudioOutputId = ""
    audioOutput.device = mediaDevices.defaultAudioOutput
  }

  function request(method, path, body, callback) {
    requestQueue.push({ method: method, path: path, body: body, callback: callback, server: server, token: token })
    runNextRequest()
  }

  function runNextRequest() {
    if (apiProcess.running || requestQueue.length === 0) return
    activeRequest = requestQueue.shift()
    requestOutputHandled = false
    apiProcess.payload = activeRequest.token + "\n" + (activeRequest.body !== null && activeRequest.body !== undefined ? JSON.stringify(activeRequest.body) : "") + "\n"
    apiProcess.command = [
      "sh", "-c",
      "set -eu; tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; chmod 700 \"$tmp\"; IFS= read -r token; IFS= read -r body; printf '%s\\n' 'Accept: application/json' > \"$tmp/headers\"; if [ -n \"$token\" ]; then printf 'Authorization: Bearer %s\\n' \"$token\" >> \"$tmp/headers\"; fi; if [ -n \"$body\" ]; then printf '%s' \"$body\" > \"$tmp/body\"; chmod 600 \"$tmp/body\"; curl --silent --show-error --connect-timeout 3 --max-time 10 --request \"$1\" --url \"$2\" --header @\"$tmp/headers\" --header 'Content-Type: application/json' --data-binary @\"$tmp/body\" --write-out '\\n%{http_code}'; else curl --silent --show-error --connect-timeout 3 --max-time 10 --request \"$1\" --url \"$2\" --header @\"$tmp/headers\" --write-out '\\n%{http_code}'; fi",
      "spokenshelf-api", activeRequest.method, activeRequest.server + activeRequest.path
    ]
    apiProcess.running = true
  }

  function finishRequest(rawOutput) {
    if (loggingOut) {
      activeRequest = null
      requestOutputHandled = true
      return
    }
    if (requestOutputHandled || !activeRequest) return
    requestOutputHandled = true
    var raw = String(rawOutput || "")
    var marker = raw.lastIndexOf("\n")
    var status = marker >= 0 ? Number(raw.slice(marker + 1).trim()) : 0
    var body = marker >= 0 ? raw.slice(0, marker) : raw
    var ok = status >= 200 && status < 300
    var data = null
    if (body.trim() !== "") {
      try { data = JSON.parse(body) } catch (_) { data = body.trim() }
    }
    var callback = activeRequest.callback
    activeRequest = null
    if (callback) callback(ok, ok ? (data || {}) : apiErrorMessage(status, data))
    runNextRequest()
  }

  function apiErrorMessage(status, data) {
    if (data && typeof data === "object") return String(data.error || data.message || ("Server returned HTTP " + status))
    if (data) return String(data)
    return status ? "Server returned HTTP " + status : "Could not reach the Audiobookshelf server"
  }

  function connect(serverUrl) {
    selectServer(serverUrl)
    error = ""
    if (server === "") { error = "Enter an Audiobookshelf server URL"; return }
    tokenLookup.command = ["secret-tool", "lookup"].concat(Api.keyringAttributes(server))
    tokenLookup.running = true
  }

  function authenticateWithToken(serverUrl, apiToken, method) {
    selectServer(serverUrl)
    token = String(apiToken || "").trim()
    connected = false
    if (server === "" || token === "") { error = "Server URL and API token are required"; return }
    tokenToStore = token
    authenticationMethod = method || "api-token"
    authorize()
  }

  function authenticateWithPassword(serverUrl, username, password) {
    selectServer(serverUrl)
    token = ""
    connected = false
    error = ""
    if (server === "" || String(username || "").trim() === "" || password === "") {
      error = "Server URL, username, and password are required"
      return
    }
    if (loginProcess.running) return
    loading = true
    loginProcess.payload = JSON.stringify({ username: String(username).trim(), password: password })
    loginProcess.command = [
      "sh", "-c",
      "set -eu; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT; chmod 600 \"$tmp\"; IFS= read -r body; printf '%s' \"$body\" > \"$tmp\"; curl --silent --show-error --request POST --header 'Accept: application/json' --header 'Content-Type: application/json' --data-binary @\"$tmp\" --write-out '\\n%{http_code}' --url \"$1\"",
      "spokenshelf-login", server + "/login"
    ]
    loginProcess.running = true
  }

  function finishPasswordLogin(rawOutput) {
    if (loggingOut) return
    loading = false
    var raw = String(rawOutput || "")
    var marker = raw.lastIndexOf("\n")
    var status = marker >= 0 ? Number(raw.slice(marker + 1).trim()) : 0
    var body = marker >= 0 ? raw.slice(0, marker) : raw
    var data = null
    if (body.trim() !== "") {
      try { data = JSON.parse(body) } catch (_) { data = body.trim() }
    }
    if (status < 200 || status >= 300) {
      error = apiErrorMessage(status, data)
      return
    }
    var accessToken = data && data.user ? (data.user.token || data.user.accessToken || "") : ""
    if (accessToken === "") { error = "The server did not return an access token"; return }
    authenticateWithToken(server, accessToken, "password")
  }

  function promptForCredentials() {
    if (credentialPrompt.running) return
    if (!zenityChecked) {
      credentialPromptPending = true
      return
    }
    if (!zenityAvailable) {
      credentialPromptPending = false
      dependencyError = "Cannot open the connection form: install zenity with `omarchy pkg add zenity`."
      credentialPromptUnavailable()
      return
    }
    credentialPromptPending = false
    dependencyError = ""
    credentialPromptStarting()
    credentialPrompt.command = [
      "zenity", "--forms", "--title=SpokenShelf", "--text=Connect to your Audiobookshelf server",
      "--add-entry=Server URL", "--add-entry=Username (optional)", "--add-password=Password (optional)",
      "--add-password=API token (alternative)", "--separator=\t"
    ]
    credentialPrompt.running = true
  }

  function handleCredentialOutput(output) {
    var values = String(output || "").replace(/\r?\n$/, "").split("\t")
    if (values.length !== 4 || !values[0]) {
      error = "Enter a server URL and either login credentials or an API token"
      return
    }
    if (values[3]) authenticateWithToken(values[0], values[3], "api-token")
    else if (values[1] && values[2]) authenticateWithPassword(values[0], values[1], values[2])
    else error = "Enter a username and password, or an API token"
  }

  function authorize() {
    loading = true
    request("GET", "/api/me", null, function(ok, data) {
      loading = false
      if (!ok) {
        connected = false
        tokenToStore = ""
        error = data
        if (zenityAvailable) {
          connectionErrorDialog.command = ["zenity", "--error", "--title=SpokenShelf", "--text=" + data]
          connectionErrorDialog.running = true
        }
        return
      }
      connected = true
      user = data.user || data
      error = ""
      serverFile.setText(server + "\n")
      if (tokenToStore !== "") {
        tokenStore.payload = tokenToStore
        tokenStore.command = ["sh", "-c", "IFS= read -r token; printf %s \"$token\" | secret-tool store --label=\"SpokenShelf ($1)\" service omarchy-audiobookshelf server \"$1\"", "spokenshelf-store", server]
        tokenStore.running = true
      }
      loadLibraries()
      syncOfflineSessions()
    })
  }

  function logout(promptForNewServer) {
    if (loggingOut) return
    loggingOut = true
    promptAfterLogout = Boolean(promptForNewServer)
    requestQueue = []
    activeRequest = null
    requestOutputHandled = true
    syncingOfflineSessions = false
    apiProcess.running = false
    tokenLookup.running = false
    loginProcess.running = false

    if (currentItem && localPlayback) syncProgress(true)
    else if (currentItem && duration > 0 && token !== "" && server !== "") startLogoutSync()
    player.stop()
    maybeFinishLogout()
  }

  function startLogoutSync() {
    var now = Date.now()
    var currentPosition = position
    var progress = Api.progressFor(currentPosition, duration)
    var body = { currentTime: currentPosition, duration: duration, timeListened: listenedSinceSync }
    var path = sessionId !== ""
      ? "/api/session/" + encodeURIComponent(sessionId) + "/close"
      : "/api/me/progress/" + encodeURIComponent(currentItem.id)
    var method = sessionId !== "" ? "POST" : "PATCH"
    if (sessionId === "") body.progress = progress

    var nextProgress = Object.assign({}, mediaProgress)
    nextProgress[currentItem.id] = Object.assign({}, nextProgress[currentItem.id] || {}, {
      libraryItemId: currentItem.id, duration: duration, currentTime: currentPosition,
      progress: progress, isFinished: progress >= 0.995, lastUpdate: now
    })
    mediaProgress = nextProgress
    listenedSinceSync = 0
    logoutSyncProcess.payload = token + "\n" + JSON.stringify(body) + "\n"
    logoutSyncProcess.command = [
      "sh", "-c",
      "set -eu; tmp=$(mktemp -d); trap 'rm -rf \"$tmp\"' EXIT; chmod 700 \"$tmp\"; IFS= read -r token; IFS= read -r body; printf 'Authorization: Bearer %s\\n' \"$token\" > \"$tmp/headers\"; printf '%s' \"$body\" > \"$tmp/body\"; chmod 600 \"$tmp/body\"; curl --silent --show-error --connect-timeout 3 --max-time 5 --request \"$1\" --url \"$2\" --header @\"$tmp/headers\" --header 'Content-Type: application/json' --data-binary @\"$tmp/body\" >/dev/null",
      "spokenshelf-logout-sync", method, apiUrl(path)
    ]
    logoutSyncProcess.running = true
  }

  function maybeFinishLogout() {
    if (!tokenStore.running && !logoutSyncProcess.running) finishLogout()
  }

  function finishLogout() {
    if (clearingCredentials) return
    clearingCredentials = true
    var previousServer = server
    player.stop()
    player.source = ""
    pendingSeekPosition = -1
    token = ""
    tokenToStore = ""
    connected = false
    authenticationMethod = ""
    loading = false
    error = ""
    user = null
    libraries = []
    books = []
    libraryBooks = []
    continueBooks = []
    recentBooks = []
    searchBooks = []
    searchQuery = ""
    searchGeneration += 1
    searching = false
    libraryLoading = false
    librarySearchIndex = []
    playbackGeneration += 1
    playbackStartPending = false
    streamStartPending = false
    pausedAt = 0
    unsyncedStreamProgress = ({})
    dirtyStreamProgress = ({})
    offlineSyncCallbacks = []
    loadingProgress = false
    progressLoadCallbacks = []
    progressReloadPending = false
    progressReloadCallbacks = []
    mediaProgress = ({})
    selectedLibraryId = ""
    currentItem = null
    currentTracks = []
    currentChapters = []
    currentTrackIndex = 0
    sessionId = ""
    sessionDuration = 0
    listenedSinceSync = 0
    localSessionId = ""
    localSessionStartTime = 0
    localSessionStartedAt = 0
    localTimeListening = 0
    localSessionServer = ""
    localSessionUserId = ""
    browsingOffline = false
    requestQueue = []
    activeRequest = null
    requestOutputHandled = true
    apiProcess.running = false
    tokenLookup.running = false
    loginProcess.running = false
    serverFile.setText("")

    if (previousServer === "") {
      completeLogout()
      return
    }
    tokenClear.command = ["secret-tool", "clear"].concat(Api.keyringAttributes(previousServer))
    tokenClear.running = true
  }

  function completeLogout() {
    if (apiProcess.running || loginProcess.running || tokenLookup.running || tokenStore.running) {
      logoutCompletionTimer.restart()
      return
    }
    clearingCredentials = false
    loggingOut = false
    if (promptAfterLogout) {
      promptAfterLogout = false
      promptForCredentials()
    }
  }

  function loadLibraries() {
    request("GET", "/api/libraries", null, function(ok, data) {
      if (!ok) { error = data; return }
      libraries = data.libraries || []
      for (var i = 0; i < libraries.length; i++) {
        if (libraries[i].mediaType === "book") { loadLibrary(libraries[i].id); return }
      }
      if (libraries.length > 0) error = "No audiobook library is available"
    })
  }

  function loadLibrary(id) {
    browsingOffline = false
    selectedLibraryId = id
    searchGeneration += 1
    searchBooks = []
    libraryLoading = true
    librarySearchIndex = []
    loading = true
    request("GET", "/api/libraries/" + encodeURIComponent(id) + "/items?mediaType=book&sort=media.metadata.title&limit=0", null, function(ok, data) {
      if (id !== selectedLibraryId) return
      loading = false
      libraryLoading = false
      if (!ok) { searching = false; error = data; return }
      libraryBooks = data.results || []
      rebuildLibrarySearchIndex()
      books = libraryBooks
      if (searchQuery !== "") searchLibrary(searchQuery)
    })
    loadHome(id)
    loadProgress()
  }

  function loadHome(id) {
    request("GET", "/api/libraries/" + encodeURIComponent(id) + "/personalized?limit=8", null, function(ok, data) {
      if (!ok) { error = data; return }
      var shelves = Array.isArray(data) ? data : []
      var inProgress = []
      var recent = []
      for (var i = 0; i < shelves.length; i++) {
        if (shelves[i].id === "continue-listening") inProgress = shelves[i].entities || []
        else if (shelves[i].id === "recently-added") recent = shelves[i].entities || []
      }
      continueBooks = inProgress
      recentBooks = recent
    })
  }

  function loadProgress(callback, forceReload) {
    if (loadingProgress && forceReload) {
      progressReloadPending = true
      if (callback) progressReloadCallbacks = progressReloadCallbacks.concat([callback])
      return
    }
    if (callback) progressLoadCallbacks = progressLoadCallbacks.concat([callback])
    if (loadingProgress) return
    loadingProgress = true
    var requestServer = server
    var requestUserId = user ? String(user.id || "") : ""
    request("GET", "/api/me/progress", null, function(ok, data) {
      loadingProgress = false
      var sameAccount = server === requestServer && user && String(user.id || "") === requestUserId
      if (ok && sameAccount) {
        var next = ({})
        var records = data.mediaProgress || []
        for (var i = 0; i < records.length; i++) next[records[i].libraryItemId] = records[i]
        next = reconcileDownloadedProgress(next, requestServer, requestUserId)
        next = reconcileDirtyStreamProgress(next, requestServer, requestUserId)
        mediaProgress = next
      }
      var callbacks = progressLoadCallbacks.slice()
      progressLoadCallbacks = []
      for (var j = 0; j < callbacks.length; j++) callbacks[j](ok && sameAccount)
      if (progressReloadPending) {
        var reloadCallbacks = progressReloadCallbacks.slice()
        progressReloadPending = false
        progressReloadCallbacks = []
        loadProgress(function(reloadOk) {
          for (var k = 0; k < reloadCallbacks.length; k++) reloadCallbacks[k](reloadOk)
        }, false)
      }
    })
  }

  function reconcileDownloadedProgress(records, progressServer, progressUserId) {
    var downloads = Object.assign({}, offlineBooks)
    var changed = false
    for (var key in downloads) {
      var entry = downloads[key]
      if (!entry || entry.server !== progressServer || String(entry.userId || "") !== progressUserId || !entry.item) continue
      var local = entry.progress || null
      for (var i = 0; i < queuedSessions.length; i++) {
        var queued = queuedSessions[i]
        if (queued.serverUrl === progressServer && String(queued.userId || "") === progressUserId && queued.libraryItemId === entry.item.id
            && (!local || Number(queued.updatedAt || 0) > Number(local.lastUpdate || local.updatedAt || 0))) {
          local = {
            libraryItemId: queued.libraryItemId, duration: queued.duration, currentTime: queued.currentTime,
            progress: Api.progressFor(queued.currentTime, queued.duration), isFinished: Number(queued.currentTime || 0) >= Number(queued.duration || 0) * 0.995,
            lastUpdate: queued.updatedAt
          }
        }
      }
      var remote = records[entry.item.id] || null
      if (local && (!remote || Number(local.lastUpdate || local.updatedAt || 0) > Number(remote.lastUpdate || remote.updatedAt || 0))) {
        records[entry.item.id] = local
      } else if (remote) {
        downloads[key] = Object.assign({}, entry, { progress: Object.assign({}, remote) })
        changed = true
      }
    }
    if (downloadItem && downloadServer === progressServer && String(downloadUserId || "") === progressUserId && records[downloadItem.id]) {
      downloadProgressRecord = Object.assign({}, records[downloadItem.id])
    }
    if (changed) {
      offlineBooks = downloads
      offlineIndex.setText(JSON.stringify(downloads, null, 2) + "\n")
    }
    return records
  }

  function reconcileDirtyStreamProgress(records, progressServer, progressUserId) {
    var prefix = streamProgressKey("", progressServer, progressUserId)
    for (var key in dirtyStreamProgress) {
      if (key.indexOf(prefix) === 0) {
        var dirty = dirtyStreamProgress[key]
        records[dirty.libraryItemId] = dirty
      }
    }
    return records
  }

  function refreshProgress(itemServer, itemUserId, callback) {
    var targetServer = String(itemServer || server)
    var targetUserId = String(itemUserId || "")
    if (!connected || targetServer !== server || targetUserId === "" || !user || targetUserId !== String(user.id || "")) {
      if (callback) callback(false)
      return
    }
    syncOfflineSessions(function(ok) {
      if (!ok || targetServer !== server || !user || targetUserId !== String(user.id || "")) {
        if (callback) callback(false)
        return
      }
      loadProgress(callback, true)
    })
  }

  function refreshVisibleProgress() {
    if (isPlaying) return
    refreshProgress(server, user ? user.id : "", function(ok) {
      if (ok && selectedLibraryId !== "") loadHome(selectedLibraryId)
    })
  }

  function searchLibrary(query) {
    var term = String(query || "").trim()
    searchQuery = term
    searchGeneration += 1
    var generation = searchGeneration
    if (term === "") {
      searching = false
      searchBooks = []
      return
    }
    searching = true
    if (selectedLibraryId === "") { searching = false; return }
    if (libraryLoading) return
    var libraryId = selectedLibraryId
    var localMatches = localSearchMatches(term)
    searchBooks = localMatches
    request("GET", "/api/libraries/" + encodeURIComponent(libraryId) + "/search?q=" + encodeURIComponent(term) + "&limit=50", null, function(ok, data) {
      if (generation !== searchGeneration || libraryId !== selectedLibraryId) return
      searching = false
      if (!ok) { error = data; return }
      var results = data.book || []
      var items = []
      var seen = ({})
      for (var i = 0; i < results.length; i++) {
        if (results[i].libraryItem && !seen[results[i].libraryItem.id]) {
          seen[results[i].libraryItem.id] = true
          items.push(results[i].libraryItem)
        }
      }
      var currentLocalMatches = localSearchMatches(term)
      for (var j = 0; j < currentLocalMatches.length; j++) {
        if (!seen[currentLocalMatches[j].id]) {
          seen[currentLocalMatches[j].id] = true
          items.push(currentLocalMatches[j])
        }
      }
      searchBooks = items
    })
  }

  function rebuildLibrarySearchIndex() {
    var index = []
    for (var i = 0; i < libraryBooks.length; i++) {
      var item = libraryBooks[i]
      var metadata = item && item.media ? item.media.metadata || ({}) : ({})
      var fields = [
        metadata.title, metadata.subtitle, metadata.authorName, metadata.authorNameLF,
        metadata.seriesName, metadata.narratorName, metadata.isbn, metadata.asin
      ]
      for (var j = 0; j < fields.length; j++) fields[j] = String(fields[j] || "")
      index.push({ item: item, text: fields.join("\n").toLowerCase() })
    }
    librarySearchIndex = index
  }

  function localSearchMatches(term) {
    var needle = String(term || "").toLowerCase()
    var matches = []
    for (var i = 0; i < librarySearchIndex.length; i++) {
      if (librarySearchIndex[i].text.indexOf(needle) !== -1) matches.push(librarySearchIndex[i].item)
    }
    return matches
  }

  function playItem(item) {
    if (streamStartPending) return
    playbackGeneration += 1
    playbackStartPending = false
    pausedAt = 0
    streamStartPending = true
    if (currentItem) syncProgress(true)
    player.pause()
    loading = true
    request("POST", "/api/items/" + encodeURIComponent(item.id) + "/play", {
      deviceInfo: { deviceId: "spokenshelf", clientName: "SpokenShelf", clientVersion: "1.0.0" },
      supportedMimeTypes: ["audio/mpeg", "audio/mp4", "audio/aac", "audio/ogg", "audio/flac"],
      forceDirectPlay: true,
      forceTranscode: false,
      mediaPlayer: "QtMultimedia"
    }, function(ok, data) {
      streamStartPending = false
      loading = false
      if (!ok) { sessionId = ""; error = data; return }
      currentItem = data.libraryItem || item
      currentTracks = data.audioTracks || data.mediaTracks || []
      currentChapters = data.chapters || []
      sessionId = data.id || ""
      sessionDuration = Number(data.duration || item.media.duration || 0)
      playbackStartedAt = Number(data.startedAt || Date.now())
      localPlayback = false
      if (currentTracks.length === 0) { error = "The server did not return playable audio tracks"; return }
      var progressKey = streamProgressKey(currentItem.id, server, user ? user.id : "")
      var unsynced = unsyncedStreamProgress[progressKey] || null
      var dirty = dirtyStreamProgress[progressKey] || null
      if (unsynced) {
        listenedSinceSync = Number(unsynced.timeListened || 0)
        var remaining = Object.assign({}, unsyncedStreamProgress)
        delete remaining[progressKey]
        unsyncedStreamProgress = remaining
      } else {
        listenedSinceSync = 0
      }
      startAt(unsynced && unsynced.currentTime !== null ? unsynced.currentTime
              : (dirty ? dirty.currentTime : (data.currentTime || 0)))
    })
  }

  function startAt(seconds) {
    var target = Math.max(0, Number(seconds || 0))
    for (var i = 0; i < currentTracks.length; i++) {
      var track = currentTracks[i]
      var start = Number(track.startOffset || 0)
      var end = start + Number(track.duration || 0)
      if (target >= start && (target < end || i === currentTracks.length - 1)) {
        startTrack(i, target)
        return
      }
    }
    startTrack(0, 0)
  }

  function startTrack(index, seekSeconds, shouldPlay) {
    if (index < 0 || index >= currentTracks.length) return
    currentTrackIndex = index
    var track = currentTracks[index]
    var source = localPlayback && track.localPath ? "file://" + track.localPath : trustedMediaUrl(track.contentUrl)
    if (!localPlayback) {
      if (source === "") { error = "The server returned an untrusted audio URL"; return }
      source += (source.indexOf("?") === -1 ? "?" : "&") + "token=" + encodeURIComponent(token)
    }
    player.source = source
    pendingSeekPosition = seekSeconds > 0 ? Math.max(0, seekSeconds - Number(track.startOffset || 0)) * 1000 : -1
    if (shouldPlay === undefined || shouldPlay) player.play()
  }

  function togglePlayback() {
    if (streamStartPending) return
    if (isPlaying) {
      player.pause()
      pausedAt = Date.now()
      syncProgress(false)
    } else if (playbackStartPending) {
      playbackGeneration += 1
      playbackStartPending = false
      loading = false
    } else {
      var item = currentItem
      if (!item) return
      playbackGeneration += 1
      var generation = playbackGeneration
      playbackStartPending = true
      var rewindOnResume = pausedAt > 0 && Date.now() - pausedAt >= resumeRewindPauseMs
      var itemServer = localPlayback ? localSessionServer : server
      var itemUserId = localPlayback ? localSessionUserId : (user ? user.id : "")
      refreshProgress(itemServer, itemUserId, function(ok) {
        if (generation !== playbackGeneration || currentItem !== item || isPlaying) return
        playbackStartPending = false
        var target = resumePosition(item.id, ok)
        if (rewindOnResume) target = Math.max(0, target - resumeRewindSeconds)
        pausedAt = 0
        if ((rewindOnResume && Math.abs(target - position) > 0.001) || Math.abs(target - position) > 1) seek(target, true)
        player.play()
      })
    }
  }

  function resumePosition(itemId, useSavedProgress) {
    if (!useSavedProgress) return position
    var saved = progressForItem(itemId)
    if (!saved) return position
    var target = saved.isFinished ? 0 : Number(saved.currentTime || 0)
    return isFinite(target) ? Math.max(0, Math.min(duration, target)) : position
  }
  function seek(seconds, preservePendingPlayback) {
    if (!preservePendingPlayback && !isPlaying) pausedAt = 0
    if (playbackStartPending && !preservePendingPlayback) {
      playbackGeneration += 1
      playbackStartPending = false
      loading = false
    }
    var target = Math.max(0, Math.min(duration, seconds))
    for (var i = 0; i < currentTracks.length; i++) {
      var track = currentTracks[i]
      var start = Number(track.startOffset || 0)
      var end = start + Number(track.duration || 0)
      if (target >= start && (target < end || i === currentTracks.length - 1)) {
        if (i === currentTrackIndex) player.position = (target - start) * 1000
        else startTrack(i, target, isPlaying || preservePendingPlayback)
        return
      }
    }
  }
  function skip(seconds) { seek(position + seconds) }
  function seekChapter(seconds) { seek(chapterStart + Math.max(0, Math.min(chapterDuration, seconds))) }

  function syncProgress(finalSync, callback) {
    if (!currentItem || duration <= 0) { if (callback) callback(false); return }
    var now = Date.now()
    var progress = Api.progressFor(position, duration)
    var payload = { duration: duration, currentTime: position, progress: progress, isFinished: progress >= 0.995,
                    startedAt: playbackStartedAt || now, finishedAt: progress >= 0.995 ? now : null }
    var nextProgress = Object.assign({}, mediaProgress)
    nextProgress[currentItem.id] = Object.assign({}, nextProgress[currentItem.id] || {}, payload, { libraryItemId: currentItem.id, lastUpdate: now })
    mediaProgress = nextProgress
    if (downloadItem && downloadItem.id === currentItem.id && downloadServer === server
        && String(downloadUserId || "") === String(user ? user.id || "" : "")) {
      downloadProgressRecord = Object.assign({}, nextProgress[currentItem.id])
    }
    if (localPlayback) {
      queueOfflineSession(payload, now)
      if (connected && !loggingOut) syncOfflineSessions(callback)
      else if (callback) callback(false)
      return
    }
    if (sessionId !== "") {
      var syncedItem = currentItem
      var syncedSessionId = sessionId
      var syncedListening = listenedSinceSync
      var syncedServer = server
      var syncedUserId = user ? user.id : ""
      var syncedPosition = position
      request("POST", "/api/session/" + encodeURIComponent(sessionId) + (finalSync ? "/close" : "/sync"),
              { currentTime: position, duration: duration, timeListened: syncedListening }, function(ok) {
                var progressKey = streamProgressKey(syncedItem.id, syncedServer, syncedUserId)
                if (ok) {
                  var clean = Object.assign({}, dirtyStreamProgress)
                  delete clean[progressKey]
                  dirtyStreamProgress = clean
                } else {
                  var dirty = Object.assign({}, dirtyStreamProgress)
                  dirty[progressKey] = Object.assign({}, nextProgress[syncedItem.id])
                  dirtyStreamProgress = dirty
                }
                if (!ok && !finalSync && currentItem === syncedItem && sessionId === syncedSessionId && !streamStartPending) {
                  listenedSinceSync += syncedListening
                } else if (!ok) {
                  stashUnsyncedStreamProgress(syncedItem.id, syncedServer, syncedUserId,
                                              finalSync ? syncedPosition : null, syncedListening)
                }
                if (callback) callback(ok)
              })
      listenedSinceSync = 0
    } else {
      request("PATCH", "/api/me/progress/" + encodeURIComponent(currentItem.id),
              { duration: duration, currentTime: position, progress: progress }, function(ok) { if (callback) callback(ok) })
    }
  }

  function streamProgressKey(itemId, itemServer, itemUserId) {
    return String(itemServer || "") + "|" + String(itemUserId || "") + "|" + String(itemId || "")
  }

  function stashUnsyncedStreamProgress(itemId, itemServer, itemUserId, currentTime, timeListened) {
    var key = streamProgressKey(itemId, itemServer, itemUserId)
    var existing = unsyncedStreamProgress[key] || ({ currentTime: null, timeListened: 0 })
    var failed = Object.assign({}, unsyncedStreamProgress)
    failed[key] = {
      currentTime: currentTime !== null ? currentTime : existing.currentTime,
      timeListened: Number(existing.timeListened || 0) + Number(timeListened || 0)
    }
    unsyncedStreamProgress = failed
  }

  function downloadBook() {
    if (!currentItem || currentTracks.length === 0 || currentDownloaded) return
    var itemId = safeItemId(currentItem.id)
    if (itemId === "") { error = "The server returned an unsafe item ID"; return }
    downloadItem = currentItem
    downloadTracks = currentTracks.slice()
    downloadChapters = currentChapters.slice()
    downloadServer = server
    downloadToken = token
    downloadUserId = user ? user.id : ""
    downloadProgressRecord = progressForItem(itemId) ? Object.assign({}, progressForItem(itemId)) : null
    downloadStatus = "Downloading " + title
    downloadBytes = 0
    downloadCompletedBytes = 0
    downloadTotalBytes = 0
    for (var i = 0; i < downloadTracks.length; i++) {
      var track = downloadTracks[i]
      downloadTotalBytes += Number(track.metadata && track.metadata.size ? track.metadata.size : track.bitRate * track.duration / 8 || 0)
    }
    downloadTrackIndex = 0
    downloadTrack()
  }

  function downloadTrack() {
    if (!downloadItem) return
    if (downloadTrackIndex >= downloadTracks.length) {
      var next = Object.assign({}, offlineBooks)
      next[offlineKey(downloadItem.id, downloadServer, downloadUserId)] = {
        server: downloadServer, userId: downloadUserId, item: downloadItem,
        tracks: downloadTracks, chapters: downloadChapters,
        progress: downloadProgressRecord
      }
      offlineBooks = next
      offlineIndex.setText(JSON.stringify(offlineBooks, null, 2) + "\n")
      downloadStatus = "Downloaded " + downloadItem.media.metadata.title
      downloadBytes = downloadTotalBytes
      downloadPath = ""
      downloadTrackIndex = -1
      downloadItem = null
      downloadProgressRecord = null
      downloadTracks = []
      downloadChapters = []
      downloadServer = ""
      downloadToken = ""
      downloadUserId = ""
      return
    }
    var track = downloadTracks[downloadTrackIndex]
    var url = trustedMediaUrl(track.contentUrl, downloadServer)
    var itemId = safeItemId(downloadItem.id)
    if (url === "" || itemId === "") {
      error = "Download rejected an unsafe server response"
      downloadTrackIndex = -1
      downloadItem = null
      downloadProgressRecord = null
      downloadTracks = []
      downloadChapters = []
      downloadServer = ""
      downloadToken = ""
      downloadUserId = ""
      return
    }
    var destination = downloadDirectory(itemId, downloadServer, downloadUserId) + "/" + downloadTrackIndex + ".audio"
    downloadPath = destination
    downloadProcess.payload = downloadToken + "\n"
    downloadProcess.command = ["sh", "-c", "set -eu; umask 077; IFS= read -r token; mkdir -p \"$(dirname \"$1\")\"; tmp=$(mktemp); trap 'rm -f \"$tmp\"' EXIT; chmod 600 \"$tmp\"; printf 'Authorization: Bearer %s\\n' \"$token\" > \"$tmp\"; curl --fail --silent --show-error --continue-at - --output \"$1\" --header @\"$tmp\" --url \"$2\"", "spokenshelf-download", destination, url]
    downloadProcess.running = true
  }

  function playOffline(itemId, itemServer, itemUserId) {
    if (streamStartPending) return
    var saved = offlineEntry(itemId, itemServer, itemUserId)
    if (!saved) return
    streamStartPending = true
    pausedAt = 0
    if (currentItem) syncProgress(true)
    player.pause()
    loading = false
    playbackGeneration += 1
    var generation = playbackGeneration
    playbackStartPending = true
    var savedServer = saved.server || itemServer || server
    var savedUserId = saved.userId || ""
    refreshProgress(savedServer, savedUserId, function(ok) {
      if (generation !== playbackGeneration) return
      playbackStartPending = false
      streamStartPending = false
      startOfflinePlayback(saved, savedServer, savedUserId)
    })
  }

  function startOfflinePlayback(saved, savedServer, savedUserId) {
    if (saved.server) selectServer(saved.server)
    currentItem = saved.item
    currentTracks = saved.tracks
    currentChapters = saved.chapters && saved.chapters.length > 0 ? saved.chapters : chaptersFromTracks(saved.tracks)
    localPlayback = true
    sessionId = ""
    sessionDuration = Number(saved.item.media.duration || 0)
    playbackStartedAt = Date.now()
    localSessionId = newUuid()
    localSessionServer = savedServer
    localSessionUserId = savedUserId
    var savedProgress = progressForOfflineEntry(saved, savedServer, savedUserId)
    var resumeTime = savedProgress && !savedProgress.isFinished ? Number(savedProgress.currentTime || 0) : 0
    localSessionStartTime = resumeTime
    localSessionStartedAt = playbackStartedAt
    localTimeListening = 0
    startAt(resumeTime)
  }

  function progressForOfflineEntry(saved, savedServer, savedUserId) {
    var latest = saved.progress || null
    for (var i = 0; i < queuedSessions.length; i++) {
      var queued = queuedSessions[i]
      if (queued.serverUrl === savedServer && String(queued.userId || "") === savedUserId && queued.libraryItemId === saved.item.id
          && (!latest || Number(queued.updatedAt || 0) > Number(latest.lastUpdate || latest.updatedAt || 0))) {
        latest = {
          libraryItemId: queued.libraryItemId, duration: queued.duration, currentTime: queued.currentTime,
          progress: Api.progressFor(queued.currentTime, queued.duration), isFinished: Number(queued.currentTime || 0) >= Number(queued.duration || 0) * 0.995,
          lastUpdate: queued.updatedAt
        }
      }
    }
    if (connected && server === savedServer && user && String(user.id || "") === savedUserId) {
      var serverProgress = progressForItem(saved.item.id)
      if (serverProgress && (!latest || Number(serverProgress.lastUpdate || 0) >= Number(latest.lastUpdate || latest.updatedAt || 0))) latest = serverProgress
    }
    return latest
  }

  function showOfflineBooks() {
    browsingOffline = true
    books = offlineBookList()
  }

  function newUuid() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
      var r = Math.floor(Math.random() * 16)
      return (c === "x" ? r : (r & 0x3) | 0x8).toString(16)
    })
  }

  function queueOfflineSession(progress, timestamp) {
    var session = {
      id: localSessionId || newUuid(), userId: localSessionUserId, libraryId: currentItem.libraryId,
      libraryItemId: currentItem.id, episodeId: null, mediaType: "book", playMethod: 3,
      bookId: currentItem.media ? currentItem.media.id : null,
      displayTitle: title, displayAuthor: author, duration: duration, currentTime: position,
      timeListening: localTimeListening, startTime: localSessionStartTime,
      startedAt: localSessionStartedAt || timestamp, updatedAt: timestamp,
      serverUrl: localSessionServer,
      mediaPlayer: "QtMultimedia",
      deviceInfo: { deviceId: "spokenshelf", clientName: "SpokenShelf", clientVersion: "1.0.0" },
      mediaMetadata: currentItem.media ? currentItem.media.metadata : null
    }
    localSessionId = session.id
    var next = []
    var replaced = false
    for (var i = 0; i < queuedSessions.length; i++) {
      if (queuedSessions[i].id === session.id) {
        next.push(session)
        replaced = true
      } else {
        next.push(queuedSessions[i])
      }
    }
    if (!replaced) next.push(session)
    queuedSessions = next
    offlineSessionsFile.setText(JSON.stringify(queuedSessions, null, 2) + "\n")
    var key = offlineKey(currentItem.id, localSessionServer, localSessionUserId)
    if (offlineBooks[key]) {
      var downloads = Object.assign({}, offlineBooks)
      downloads[key] = Object.assign({}, downloads[key], {
        progress: Object.assign({}, progress, { libraryItemId: currentItem.id, lastUpdate: timestamp })
      })
      offlineBooks = downloads
      offlineIndex.setText(JSON.stringify(offlineBooks, null, 2) + "\n")
    }
    listenedSinceSync = 0
  }

  function syncOfflineSessions(callback, sessionIds) {
    if (callback) offlineSyncCallbacks = offlineSyncCallbacks.concat([callback])
    if (syncingOfflineSessions) return
    if (queuedSessions.length === 0) { finishOfflineSessionSync(true); return }
    syncingOfflineSessions = true
    var syncServer = server
    var syncUserId = user ? String(user.id || "") : ""
    var restricted = sessionIds && sessionIds.length > 0
    var sent = []
    for (var index = 0; index < queuedSessions.length; index++) {
      var queued = queuedSessions[index]
      if (restricted && sessionIds.indexOf(queued.id) === -1) continue
      if (queued.serverUrl === syncServer && syncUserId !== "" && String(queued.userId || "") === syncUserId) {
        sent.push(Object.assign({}, queued, {
          deviceInfo: { deviceId: "spokenshelf", clientName: "SpokenShelf", clientVersion: "1.0.0" }
        }))
      }
    }
    if (sent.length === 0) {
      syncingOfflineSessions = false
      finishOfflineSessionSync(true)
      return
    }
    request("POST", "/api/session/local-all", {
      deviceInfo: { deviceId: "spokenshelf", clientName: "SpokenShelf", clientVersion: "1.0.0" },
      sessions: sent
    }, function(ok, data) {
      syncingOfflineSessions = false
      if (!ok) { finishOfflineSessionSync(false); return }
      var results = data.sessions || data.results || []
      var remaining = []
      var allSynced = true
      var newerSnapshotPending = false
      var retryIds = []
      var activeSessionSynced = false
      var activeSentSession = null
      for (var i = 0; i < queuedSessions.length; i++) {
        var current = queuedSessions[i]
        var sentSession = null
        var result = null
        if (current.serverUrl !== syncServer || String(current.userId || "") !== syncUserId) { remaining.push(current); continue }
        if (restricted && sessionIds.indexOf(current.id) === -1) { remaining.push(current); continue }
        for (var j = 0; j < sent.length; j++) if (sent[j].id === current.id) { sentSession = sent[j]; break }
        for (var k = 0; k < results.length; k++) if (results[k].id === current.id) { result = results[k]; break }
        if (sentSession && result && result.success && current.updatedAt > sentSession.updatedAt) {
          remaining.push(current)
          allSynced = false
          newerSnapshotPending = true
          retryIds.push(current.id)
        } else if (!sentSession || !result || !result.success) {
          remaining.push(current)
          allSynced = false
        } else if (current.id === localSessionId) {
          activeSessionSynced = true
          activeSentSession = sentSession
        }
      }
      queuedSessions = remaining
      offlineSessionsFile.setText(JSON.stringify(queuedSessions, null, 2) + "\n")
      if (activeSessionSynced && localPlayback && localSessionServer === syncServer && localSessionUserId === syncUserId) {
        var listeningAfterSnapshot = Math.max(0, localTimeListening - Number(activeSentSession.timeListening || 0))
        localSessionId = newUuid()
        localSessionStartTime = Number(activeSentSession.currentTime || position)
        localSessionStartedAt = Date.now() - listeningAfterSnapshot * 1000
        localTimeListening = listeningAfterSnapshot
      }
      if (newerSnapshotPending) {
        syncOfflineSessions(null, retryIds)
        return
      }
      finishOfflineSessionSync(allSynced)
    })
  }

  function finishOfflineSessionSync(ok) {
    var callbacks = offlineSyncCallbacks.slice()
    offlineSyncCallbacks = []
    for (var i = 0; i < callbacks.length; i++) callbacks[i](ok)
  }

  MediaPlayer {
    id: player
    audioOutput: AudioOutput { id: audioOutput; volume: 1 }
    onMediaStatusChanged: {
      if ((mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) && root.pendingSeekPosition >= 0) {
        position = root.pendingSeekPosition
        root.pendingSeekPosition = -1
      } else if (mediaStatus === MediaPlayer.EndOfMedia) {
        if (root.currentTrackIndex + 1 < root.currentTracks.length) root.startTrack(root.currentTrackIndex + 1, 0)
        else root.syncProgress(true)
      }
    }
    onErrorOccurred: function(error, errorString) { root.error = "Playback failed: " + errorString }
  }

  MediaDevices {
    id: mediaDevices
    onAudioOutputsChanged: root.refreshAudioOutputs()
  }

  Timer {
    interval: 1000
    running: root.isPlaying
    repeat: true
    onTriggered: {
      root.listenedSinceSync += 1
      if (root.localPlayback) root.localTimeListening += 1
    }
  }
  Timer { interval: 30000; running: root.isPlaying; repeat: true; onTriggered: root.syncProgress(false) }

  Process {
    id: apiProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishRequest(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: loginProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finishPasswordLogin(text)
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: tokenLookup
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (root.loggingOut) return
        root.token = String(text || "").trim()
        if (root.token === "") root.error = "Not connected"
        else {
          root.authenticationMethod = "keyring"
          root.authorize()
        }
      }
    }
    onExited: function(code) {
      if (root.loggingOut) return
      if (code !== 0) root.error = "Not connected"
    }
  }

  Process {
    id: credentialPrompt
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "") !== "") root.handleCredentialOutput(text)
    }
  }

  Process { id: connectionErrorDialog }

  Process {
    id: tokenStore
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
    }
    onExited: {
      root.tokenToStore = ""
      if (root.loggingOut) root.maybeFinishLogout()
    }
  }

  Process {
    id: logoutSyncProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: root.maybeFinishLogout()
  }

  Process {
    id: tokenClear
    onExited: function(code) {
      if (code === 0 || code === 1) root.completeLogout()
      else {
        root.clearingCredentials = false
        root.loggingOut = false
        root.promptAfterLogout = false
        root.error = "Could not remove the saved credential"
      }
    }
  }

  Timer { id: logoutCompletionTimer; interval: 50; repeat: false; onTriggered: root.completeLogout() }

  IpcHandler {
    target: "spokenshelf"

    function status(): string {
      return JSON.stringify({
        server: root.server,
        connected: root.connected,
        authenticationMethod: root.authenticationMethod,
        loading: root.loading,
        error: root.error,
        libraries: root.libraries.length,
        books: root.books.length,
        continueBooks: root.continueBooks.length,
        recentBooks: root.recentBooks.length,
        progressRecords: Object.keys(root.mediaProgress).length,
        playing: root.isPlaying,
        title: root.title,
        author: root.author,
        cover: root.currentItem ? root.coverUrl(root.currentItem, 260) : "",
        itemId: root.currentItem ? root.currentItem.id : "",
        savedPosition: root.currentItem && root.progressForItem(root.currentItem.id) ? root.progressForItem(root.currentItem.id).currentTime : 0,
        position: root.position,
        duration: root.duration,
        chapter: root.chapterTitle,
        chapterPosition: root.chapterPosition,
        chapterDuration: root.chapterDuration,
        localPlayback: root.localPlayback,
        queuedSessions: root.queuedSessions.length,
        downloading: root.downloading,
        volume: root.playbackVolume,
        zenityAvailable: root.zenityAvailable,
        mprisAvailable: root.mprisAvailable,
        dependencyError: root.dependencyError,
        dependencyWarning: root.dependencyWarning,
        audioOutputs: mediaDevices.audioOutputs.length,
        selectedAudioOutputId: root.selectedAudioOutputId,
        selectedAudioOutput: audioOutput.device.description
      })
    }

    function playPause(): string {
      if (!root.currentItem) return "unhandled"
      root.togglePlayback()
      return "ok"
    }

    function play(): string {
      if (!root.currentItem) return "unhandled"
      if (!root.isPlaying && !root.playbackStartPending) root.togglePlayback()
      return "ok"
    }

    function pause(): string {
      if (!root.currentItem) return "unhandled"
      if (root.isPlaying || root.playbackStartPending) root.togglePlayback()
      return "ok"
    }

    function skip(seconds: real): string {
      if (!root.currentItem) return "unhandled"
      root.skip(seconds)
      return "ok"
    }

    function seek(seconds: real): string {
      if (!root.currentItem) return "unhandled"
      root.seek(seconds)
      return "ok"
    }

    function volume(value: real): string {
      root.setVolume(value)
      return "ok"
    }

    function connect(): string {
      root.promptForCredentials()
      return "ok"
    }
  }
  Process {
    id: downloadProcess
    property string payload: ""
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
    stderr: StdioCollector { id: downloadError; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        root.downloadStatus = "Download failed: " + String(downloadError.text || "unknown error").trim()
        root.downloadTrackIndex = -1
        root.downloadItem = null
        root.downloadProgressRecord = null
        root.downloadTracks = []
        root.downloadChapters = []
        root.downloadServer = ""
        root.downloadToken = ""
        root.downloadUserId = ""
        return
      }
      var tracks = root.downloadTracks.slice()
      var track = Object.assign({}, tracks[root.downloadTrackIndex])
      track.localPath = root.downloadDirectory(root.downloadItem.id, root.downloadServer, root.downloadUserId) + "/" + root.downloadTrackIndex + ".audio"
      tracks[root.downloadTrackIndex] = track
      root.downloadTracks = tracks
      root.downloadCompletedBytes += Number(track.metadata && track.metadata.size ? track.metadata.size : track.bitRate * track.duration / 8 || 0)
      root.downloadBytes = root.downloadCompletedBytes
      root.downloadTrackIndex += 1
      root.downloadStatus = "Downloaded track " + root.downloadTrackIndex + " of " + root.downloadTracks.length
      root.downloadTrack()
    }
  }

  Timer {
    interval: 500
    running: root.downloading
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!downloadSizeProcess.running && root.downloadPath !== "") {
        downloadSizeProcess.command = ["stat", "--format=%s", root.downloadPath]
        downloadSizeProcess.running = true
      }
    }
  }

  Process {
    id: downloadSizeProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var size = Number(text.trim())
        if (!isNaN(size)) root.downloadBytes = root.downloadCompletedBytes + size
      }
    }
  }

  FileView {
    id: offlineIndex
    path: root.stateDirectory + "/downloads.json"
    printErrors: false
    onLoaded: {
      try { root.offlineBooks = root.migrateOfflineBooks(JSON.parse(text())) } catch (_) { root.offlineBooks = ({}) }
    }
    onLoadFailed: root.offlineBooks = ({})
  }

  FileView {
    id: offlineSessionsFile
    path: root.stateDirectory + "/offline-sessions.json"
    printErrors: false
    onLoaded: {
      try { root.queuedSessions = JSON.parse(text()) } catch (_) { root.queuedSessions = [] }
    }
    onLoadFailed: root.queuedSessions = []
  }

  FileView {
    id: serverFile
    path: root.stateDirectory + "/server-url"
    printErrors: false
    onLoaded: {
      var savedServer = Api.normalizeServer(text())
      if (savedServer !== "") root.connect(savedServer)
    }
  }

  Component.onCompleted: {
    stateDirectoryInit.running = true
    zenityCheck.running = true
    mprisCheck.running = true
    refreshAudioOutputs()
    serverFile.reload()
  }
  Component.onDestruction: syncProgress(true)

  Process {
    id: stateDirectoryInit
    command: ["sh", "-c", "umask 077; mkdir -p \"$1/downloads\"; chmod 700 \"$1\" \"$1/downloads\"; touch \"$1/downloads.json\" \"$1/offline-sessions.json\" \"$1/server-url\"; chmod 600 \"$1/downloads.json\" \"$1/offline-sessions.json\" \"$1/server-url\"", "spokenshelf-state", root.stateDirectory]
  }

  Process {
    id: zenityCheck
    command: ["sh", "-c", "command -v zenity >/dev/null 2>&1"]
    onExited: function(code) {
      root.zenityChecked = true
      root.zenityAvailable = code === 0
      root.dependencyError = root.zenityAvailable
        ? ""
        : "Cannot open the connection form: install zenity with `omarchy pkg add zenity`."
      if (root.credentialPromptPending) root.promptForCredentials()
    }
  }

  Process {
    id: mprisCheck
    command: ["sh", "-c", "command -v python >/dev/null 2>&1 && python -c 'import dbus_next' >/dev/null 2>&1"]
    onExited: function(code) {
      root.mprisAvailable = code === 0
      root.dependencyWarning = root.mprisAvailable
        ? ""
        : "Media-key support is unavailable. Install python-dbus-next to enable MPRIS controls."
      root.mprisFailureCount = 0
      if (root.mprisAvailable) mprisBridge.running = true
    }
  }

  Process {
    id: mprisBridge
    command: ["python", Qt.resolvedUrl("mpris.py").toString().replace(/^file:\/\//, "")]
    onExited: function(code) {
      if (!root.mprisAvailable) return
      root.mprisFailureCount += 1
      if (root.mprisFailureCount >= 3) {
        root.mprisAvailable = false
        root.dependencyWarning = "Media-key support is unavailable because the MPRIS bridge could not start."
      } else {
        mprisRestart.restart()
      }
    }
  }

  Timer { id: mprisRestart; interval: 5000; repeat: false; onTriggered: if (root.mprisAvailable && !mprisBridge.running) mprisBridge.running = true }
}
