import SwiftUI
import Carbon
import ApplicationServices

// MARK: - App Delegate for early initialization

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prompt for screen recording permission if not already granted
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }

        // Start API server immediately on app launch
        startBackgroundServices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowTracker.shared.stop()
        APIServer.shared.stop()
    }

    private func startBackgroundServices() {
        // Start window tracker
        WindowTracker.shared.start()

        // Configure API server
        APIServer.shared.windowDataProvider = {
            WindowTracker.shared.ghosttyWindows
        }
        APIServer.shared.focusWindowHandler = { axIndex, pid in
            WindowTracker.shared.focusWindow(axIndex: axIndex, pid: pid)
        }

        APIServer.shared.launchRandomHandler = {
            guard let themeManager = WindowTracker.shared.themeManager,
                  let theme = themeManager.pickRandomTheme() else {
                return nil
            }
            let windowName = theme
            themeManager.launchGhostty(withTheme: theme, name: windowName)
            return (theme: theme, windowName: windowName)
        }

        APIServer.shared.workstreamsProvider = {
            guard let themeManager = WindowTracker.shared.themeManager else {
                return []
            }
            return themeManager.workstreams.map { ws in
                WorkstreamResponse(
                    id: ws.id.uuidString,
                    name: ws.name,
                    theme: ws.theme,
                    directory: ws.directory,
                    hasCommand: ws.command != nil && !(ws.command?.isEmpty ?? true)
                )
            }
        }

        APIServer.shared.launchWorkstreamHandler = { idString in
            guard let themeManager = WindowTracker.shared.themeManager,
                  let uuid = UUID(uuidString: idString),
                  let workstream = themeManager.workstreams.first(where: { $0.id == uuid }) else {
                return nil
            }
            themeManager.launchWorkstream(workstream)
            return (name: workstream.name, theme: workstream.theme)
        }

        APIServer.shared.openQuickLaunchHandler = {
            DispatchQueue.main.async {
                QuickLaunchPanel.shared.show(themeManager: WindowTracker.shared.themeManager)
            }
        }

        // Start API server
        APIServer.shared.start()
        print("Background services started")
    }
}

@main
struct GhosttyThemePickerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var themeManager = ThemeManager()
    @State private var showingWorkstreams = false
    @State private var hasLaunchedAutoStart = false
    @StateObject private var hotkeyManager = HotkeyManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(themeManager: themeManager, showingWorkstreams: $showingWorkstreams)
                .onAppear {
                    debugLog("MenuContent onAppear called")
                    hotkeyManager.themeManager = themeManager
                    hotkeyManager.registerHotkey()

                    // Connect WindowTracker to themeManager for workstream lookups
                    WindowTracker.shared.themeManager = themeManager

                    // Launch auto-start workstreams on first appearance
                    if !hasLaunchedAutoStart {
                        hasLaunchedAutoStart = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            themeManager.launchAutoStartWorkstreams()
                        }
                    }
                }
        } label: {
            Label("Ghostty Theme Picker", systemImage: "terminal")
        }

        Window("Settings", id: "workstreams") {
            SettingsView(themeManager: themeManager, hotkeyManager: hotkeyManager)
        }
        .windowResizability(.contentSize)

        Window("Quick Launch", id: "quicklaunch") {
            QuickLaunchView(themeManager: themeManager)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - Hotkey Config

struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32  // Carbon modifier flags
    var enabled: Bool

    static let defaultQuickLaunch = HotkeyConfig(keyCode: 5, modifiers: UInt32(controlKey | optionKey), enabled: true)
    static let defaultWindowSwitcher = HotkeyConfig(keyCode: 35, modifiers: UInt32(controlKey | optionKey), enabled: true)

    var displayString: String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }
}

func keyCodeToString(_ keyCode: UInt32) -> String {
    let map: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: ".", 47: "M", 48: "⇥", 49: "Space",
        50: "`", 51: "⌫", 53: "⎋",
        // F-keys
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15",
        118: "F4", 120: "F2", 122: "F1",
        // Arrow keys
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
    return map[keyCode] ?? "Key\(keyCode)"
}

func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var mods: UInt32 = 0
    if flags.contains(.control) { mods |= UInt32(controlKey) }
    if flags.contains(.option) { mods |= UInt32(optionKey) }
    if flags.contains(.shift) { mods |= UInt32(shiftKey) }
    if flags.contains(.command) { mods |= UInt32(cmdKey) }
    return mods
}

// MARK: - Hotkey Manager (Carbon-based)

class HotkeyManager: ObservableObject {
    var themeManager: ThemeManager?
    private var hotkeyRefG: EventHotKeyRef?
    private var hotkeyRefP: EventHotKeyRef?
    private var eventHandlerInstalled = false
    static var instance: HotkeyManager?

    @Published var quickLaunchConfig: HotkeyConfig = .defaultQuickLaunch
    @Published var windowSwitcherConfig: HotkeyConfig = .defaultWindowSwitcher

    private static let quickLaunchKey = "HotkeyQuickLaunch"
    private static let windowSwitcherKey = "HotkeyWindowSwitcher"

    func loadFromDefaults() {
        if let data = UserDefaults.standard.data(forKey: Self.quickLaunchKey),
           let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            quickLaunchConfig = config
        }
        if let data = UserDefaults.standard.data(forKey: Self.windowSwitcherKey),
           let config = try? JSONDecoder().decode(HotkeyConfig.self, from: data) {
            windowSwitcherConfig = config
        }
    }

    func saveToDefaults() {
        if let data = try? JSONEncoder().encode(quickLaunchConfig) {
            UserDefaults.standard.set(data, forKey: Self.quickLaunchKey)
        }
        if let data = try? JSONEncoder().encode(windowSwitcherConfig) {
            UserDefaults.standard.set(data, forKey: Self.windowSwitcherKey)
        }
    }

    func registerHotkey() {
        HotkeyManager.instance = self
        loadFromDefaults()

        if !eventHandlerInstalled {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

            InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)

                if hotKeyID.id == 1 {
                    HotkeyManager.instance?.handleHotkeyG()
                } else if hotKeyID.id == 2 {
                    HotkeyManager.instance?.handleHotkeyP()
                }
                return noErr
            }, 1, &eventType, nil, nil)

            eventHandlerInstalled = true
        }

        registerConfiguredHotkeys()
    }

    func reregisterHotkeys() {
        unregisterAll()
        registerConfiguredHotkeys()
        saveToDefaults()
    }

    private func registerConfiguredHotkeys() {
        if quickLaunchConfig.enabled {
            var hotKeyIDG = EventHotKeyID()
            hotKeyIDG.signature = OSType(0x4754504B) // "GTPK"
            hotKeyIDG.id = 1
            let status = RegisterEventHotKey(quickLaunchConfig.keyCode, quickLaunchConfig.modifiers, hotKeyIDG, GetApplicationEventTarget(), 0, &hotkeyRefG)
            if status == noErr {
                print("Global hotkey registered: \(quickLaunchConfig.displayString) (Quick Launch)")
            }
        }

        if windowSwitcherConfig.enabled {
            var hotKeyIDP = EventHotKeyID()
            hotKeyIDP.signature = OSType(0x4754504B) // "GTPK"
            hotKeyIDP.id = 2
            let status = RegisterEventHotKey(windowSwitcherConfig.keyCode, windowSwitcherConfig.modifiers, hotKeyIDP, GetApplicationEventTarget(), 0, &hotkeyRefP)
            if status == noErr {
                print("Global hotkey registered: \(windowSwitcherConfig.displayString) (Window Switcher)")
            }
        }
    }

    private func unregisterAll() {
        if let ref = hotkeyRefG {
            UnregisterEventHotKey(ref)
            hotkeyRefG = nil
        }
        if let ref = hotkeyRefP {
            UnregisterEventHotKey(ref)
            hotkeyRefP = nil
        }
    }

    private func handleHotkeyG() {
        DispatchQueue.main.async {
            QuickLaunchPanel.shared.show(themeManager: self.themeManager)
        }
    }

    private func handleHotkeyP() {
        DispatchQueue.main.async {
            WindowSwitcherPanel.shared.show()
        }
    }

    deinit {
        unregisterAll()
    }
}

// MARK: - Window Switcher Panel

class KeyHandlingPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let handler = keyHandler, handler(event) {
            // Event was handled, don't pass it on
            return
        }
        super.sendEvent(event)
    }
}

class WindowSwitcherPanel {
    static let shared = WindowSwitcherPanel()
    private var panel: KeyHandlingPanel?

    func show() {
        if let existing = panel {
            existing.close()
        }

        let panel = KeyHandlingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.windowBackgroundColor

        let view = WindowSwitcherView(themeManager: HotkeyManager.instance?.themeManager, panel: panel) {
            panel.close()
        }

        panel.contentView = NSHostingView(rootView: view)
        panel.center()

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - Window Switcher View

/// Represents Claude's state in a terminal window
enum ClaudeState: Int, Comparable {
    case notRunning = 0   // No Claude in this window
    case working = 1      // Claude is processing (spinner in title)
    case running = 2      // Claude detected via process tree (can't determine exact state)
    case waiting = 3      // Claude waiting for input (✳ in title) - at prompt
    case asking = 4       // Claude asked a question and waiting for answer (highest priority)

    static func < (lhs: ClaudeState, rhs: ClaudeState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var icon: String {
        switch self {
        case .asking: return "questionmark.circle"
        case .waiting: return "hourglass"
        case .running: return "terminal"
        case .working: return "gearshape"
        case .notRunning: return "terminal"
        }
    }

    var label: String {
        switch self {
        case .asking: return "Question"
        case .waiting: return "Ready"
        case .running: return "Claude"
        case .working: return "Working"
        case .notRunning: return ""
        }
    }
}

/// Data captured from a Ghostty window for creating a workstream
struct CapturedWindow {
    let directory: String
    let title: String
    let theme: String?  // nil only if window was opened outside our app
    let pid: pid_t

    /// Suggested workstream name derived from directory
    var suggestedName: String {
        let url = URL(fileURLWithPath: directory)
        let lastComponent = url.lastPathComponent
        if lastComponent.isEmpty || lastComponent == "/" {
            return "Home"
        }
        return lastComponent
    }
}

/// Helper to capture the frontmost Ghostty window
class WindowCapture {
    /// Capture the frontmost Ghostty window's info
    static func captureFrontmostGhosttyWindow(themeManager: ThemeManager) -> CapturedWindow? {
        // Get frontmost Ghostty window using CGWindowList
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // Find frontmost Ghostty window (lowest layer number = frontmost)
        var ghosttyWindows: [(info: [String: Any], layer: Int)] = []
        for window in windowList {
            guard let ownerName = window["kCGWindowOwnerName"] as? String,
                  ownerName.lowercased() == "ghostty",
                  let layer = window["kCGWindowLayer"] as? Int else {
                continue
            }
            ghosttyWindows.append((info: window, layer: layer))
        }

        // Sort by layer (lower = more front)
        ghosttyWindows.sort { $0.layer < $1.layer }

        guard let frontmost = ghosttyWindows.first else {
            return nil
        }

        let windowInfo = frontmost.info
        guard let ownerPID = windowInfo["kCGWindowOwnerPID"] as? Int else {
            return nil
        }

        let pid = pid_t(ownerPID)
        let title = windowInfo["kCGWindowName"] as? String ?? "Ghostty"

        // Get shell cwd
        guard let directory = getShellCwd(ghosttyPid: pid) else {
            return nil
        }

        // Look up theme from our caches
        let theme = themeManager.themeForPID(pid)

        return CapturedWindow(
            directory: directory,
            title: title,
            theme: theme,
            pid: pid
        )
    }

    /// Get the current working directory of the shell inside a Ghostty window
    private static func getShellCwd(ghosttyPid: pid_t) -> String? {
        // First, get process tree to find the shell
        let psTask = Process()
        psTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        psTask.arguments = ["-eo", "pid,ppid,comm"]
        let psPipe = Pipe()
        psTask.standardOutput = psPipe
        psTask.standardError = FileHandle.nullDevice

        do {
            try psTask.run()
        } catch {
            return nil
        }

        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        psTask.waitUntilExit()

        guard let psOutput = String(data: psData, encoding: .utf8) else { return nil }

        // Parse process tree
        var processTree: [pid_t: (ppid: pid_t, comm: String)] = [:]
        for line in psOutput.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            let comm = String(parts[2])
            processTree[pid] = (ppid: ppid, comm: comm)
        }

        // Find login -> shell chain
        guard let loginPid = processTree.first(where: {
            $0.value.ppid == ghosttyPid && $0.value.comm.contains("login")
        })?.key else {
            return nil
        }

        guard let shellEntry = processTree.first(where: {
            $0.value.ppid == loginPid
        }) else {
            return nil
        }

        let shellPid = shellEntry.key

        // Get cwd using lsof
        let lsofTask = Process()
        lsofTask.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsofTask.arguments = ["-a", "-p", "\(shellPid)", "-d", "cwd", "-F", "n"]
        let lsofPipe = Pipe()
        lsofTask.standardOutput = lsofPipe
        lsofTask.standardError = FileHandle.nullDevice

        do {
            try lsofTask.run()
        } catch {
            return nil
        }

        let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
        lsofTask.waitUntilExit()

        guard let lsofOutput = String(data: lsofData, encoding: .utf8) else { return nil }

        for line in lsofOutput.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }

        return nil
    }
}

struct GhosttyWindow: Identifiable {
    let id: Int
    let name: String              // Window title (e.g., "✳ Claude Code" or "~/Projects")
    let axIndex: Int              // Index for AppleScript (1-based, per-process)
    let pid: pid_t                // Process ID this window belongs to
    var workstreamName: String?   // Matched workstream name (via PID cache or directory)
    var shellCwd: String?         // Current working directory of shell
    var hasClaudeProcess: Bool = false  // Whether a Claude process is running in this window
    var hookState: String?        // State from Claude Code hook ("asking" or "waiting")

    /// Determine Claude's state based on window title, hook state, and process detection
    var claudeState: ClaudeState {
        // Check title for exact state indicators
        if let firstChar = name.first {
            // ✳ (U+2733) = waiting for input - refine with hook state if available
            if firstChar == "✳" {
                // Use hook state to distinguish "asking" vs "waiting"
                if hookState == "asking" {
                    return .asking
                }
                return .waiting
            }
            // Braille spinner characters = working
            let spinnerChars: Set<Character> = ["⠁", "⠂", "⠄", "⠈", "⠐", "⠠", "⡀", "⢀"]
            if spinnerChars.contains(firstChar) {
                return .working
            }
        }
        // Fall back to process detection
        return hasClaudeProcess ? .running : .notRunning
    }

    /// Display name: prefer workstream name, fall back to shortened path or title
    var displayName: String {
        if let ws = workstreamName {
            return ws
        }
        // If title looks like a path, shorten it
        if name.hasPrefix("/") || name.hasPrefix("~") {
            return (name as NSString).lastPathComponent
        }
        return name
    }
}

class WindowSwitcherViewModel: ObservableObject {
    @Published var windows: [GhosttyWindow] = []
    @Published var searchText: String = ""
    @Published var selectedIndex: Int = 0
    @Published var hasScreenRecordingPermission: Bool = false

    weak var themeManager: ThemeManager?

    /// Windows filtered by search and sorted by Claude state (waiting first)
    var filteredWindows: [GhosttyWindow] {
        var result = windows
        if !searchText.isEmpty {
            result = result.filter { window in
                window.name.localizedCaseInsensitiveContains(searchText) ||
                (window.workstreamName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        // Sort by Claude state (waiting > running > working > notRunning)
        return result.sorted { $0.claudeState > $1.claudeState }
    }

    /// Group windows by Claude state for sectioned display
    var groupedWindows: [(state: ClaudeState, windows: [GhosttyWindow])] {
        let sorted = filteredWindows
        var groups: [(ClaudeState, [GhosttyWindow])] = []

        let asking = sorted.filter { $0.claudeState == .asking }
        let waiting = sorted.filter { $0.claudeState == .waiting }
        let running = sorted.filter { $0.claudeState == .running }
        let working = sorted.filter { $0.claudeState == .working }
        let other = sorted.filter { $0.claudeState == .notRunning }

        if !asking.isEmpty { groups.append((.asking, asking)) }
        if !waiting.isEmpty { groups.append((.waiting, waiting)) }
        if !running.isEmpty { groups.append((.running, running)) }
        if !working.isEmpty { groups.append((.working, working)) }
        if !other.isEmpty { groups.append((.notRunning, other)) }

        return groups
    }

    // MARK: - Cached Process Data (for efficient lookups)

    var cachedProcessTree: [pid_t: (ppid: pid_t, comm: String)] = [:]  // Internal for debug
    private var cachedClaudePids: Set<pid_t> = []
    private var cachedShellCwds: [pid_t: String] = [:]
    var debugLog: ((String) -> Void)?  // Debug logging callback

    // MARK: - Workstream Name Cache (persists across Window Switcher opens)
    // Maps PID to workstream name. Value of nil means "checked, no match".
    // This cache is NOT cleared on each open - it persists to make repeat opens instant.
    private var workstreamCache: [pid_t: String?] = [:]

    /// Apply cached workstream names to windows (for immediate display)
    func applyCachedWorkstreamNames(to windows: inout [GhosttyWindow]) {
        for i in windows.indices {
            let pid = windows[i].pid
            // Check app-launched windows first (always authoritative)
            if let name = themeManager?.launchedWindows[pid] {
                windows[i].workstreamName = name
            }
            // Then check our runtime cache
            else if let cached = workstreamCache[pid], let name = cached {
                windows[i].workstreamName = name
            }
        }
    }

    /// Check if a window needs workstream enrichment
    func needsWorkstreamEnrichment(pid: pid_t) -> Bool {
        // Already in app-launched cache
        if themeManager?.launchedWindows[pid] != nil {
            return false
        }
        // Already in our workstream cache (even if nil = no match)
        if workstreamCache.keys.contains(pid) {
            return false
        }
        return true
    }

    /// Cache a workstream lookup result
    func cacheWorkstreamName(_ name: String?, forPid pid: pid_t) {
        workstreamCache[pid] = name
    }

    /// Clean up cache entries for PIDs that no longer exist
    func cleanupWorkstreamCache(activePids: Set<pid_t>) {
        workstreamCache = workstreamCache.filter { activePids.contains($0.key) }
    }

    /// Load all process data in one shot for efficient lookups
    func loadProcessCache() {
        cachedProcessTree.removeAll()
        cachedClaudePids.removeAll()
        cachedShellCwds.removeAll()

        // Single ps call to get all process info
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,ppid,comm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return
        }

        // Read data before waiting (to avoid deadlock with large output)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return }

        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            guard parts.count >= 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { continue }
            let comm = String(parts[2])
            cachedProcessTree[pid] = (ppid: ppid, comm: comm)

            if comm.lowercased() == "claude" {
                cachedClaudePids.insert(pid)
            }
        }
    }

    // MARK: - Hook State Reading

    private var hookStateCache: [String: (state: String, timestamp: TimeInterval)] = [:]

    func loadHookStates() {
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-states")

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let state = json["state"] as? String,
                  let cwd = json["cwd"] as? String,
                  let timestamp = json["timestamp"] as? TimeInterval else {
                continue
            }

            if let existing = hookStateCache[cwd] {
                if timestamp > existing.timestamp {
                    hookStateCache[cwd] = (state: state, timestamp: timestamp)
                }
            } else {
                hookStateCache[cwd] = (state: state, timestamp: timestamp)
            }
        }
    }

    func getHookState(forCwd cwd: String) -> String? {
        if let cached = hookStateCache[cwd] {
            return cached.state
        }
        for (cachedCwd, cached) in hookStateCache {
            if cwd.hasPrefix(cachedCwd + "/") || cachedCwd.hasPrefix(cwd + "/") {
                return cached.state
            }
        }
        return nil
    }

    // MARK: - Shell CWD Detection

    /// Get the current working directory of the shell running inside a Ghostty window
    func getShellCwd(ghosttyPid: pid_t) -> String? {
        // Find login -> shell chain using cached data
        guard let loginPid = cachedProcessTree.first(where: {
            $0.value.ppid == ghosttyPid && $0.value.comm.contains("login")
        })?.key else {
            debugLog?("getShellCwd(\(ghosttyPid)): no login found")
            return nil
        }

        guard let shellEntry = cachedProcessTree.first(where: {
            $0.value.ppid == loginPid
        }) else {
            debugLog?("getShellCwd(\(ghosttyPid)): no shell found under login \(loginPid)")
            return nil
        }
        let shellPid = shellEntry.key
        debugLog?("getShellCwd(\(ghosttyPid)): found shell \(shellPid) (\(shellEntry.value.comm))")

        // Check cache first
        if let cached = cachedShellCwds[shellPid] {
            return cached
        }

        // Get cwd using lsof (only for shells we need)
        let cwd = getCwd(of: shellPid)
        debugLog?("getShellCwd(\(ghosttyPid)): lsof returned \(cwd ?? "nil")")
        if let cwd = cwd {
            cachedShellCwds[shellPid] = cwd
        }
        return cwd
    }

    private func getCwd(of pid: pid_t) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-F", "n"]
        let pipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = pipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            debugLog?("getCwd(\(pid)): failed to run lsof: \(error)")
            return nil
        }

        // Read data BEFORE waiting to avoid deadlock
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let exitCode = task.terminationStatus
        let output = String(data: data, encoding: .utf8) ?? ""
        let errOutput = String(data: errData, encoding: .utf8) ?? ""

        debugLog?("getCwd(\(pid)): exit=\(exitCode), stdout='\(output.prefix(100))', stderr='\(errOutput.prefix(100))'")

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    // MARK: - Claude Process Detection

    /// Check if a Claude process is running under the given Ghostty PID
    func hasClaudeProcess(ghosttyPid: pid_t) -> Bool {
        for claudePid in cachedClaudePids {
            if traceToGhostty(from: claudePid) == ghosttyPid {
                return true
            }
        }
        return false
    }

    private func traceToGhostty(from pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<15 {
            guard let info = cachedProcessTree[current] else { return nil }
            let parent = info.ppid
            if parent <= 1 { return nil }
            // Check if parent is a Ghostty window we know about
            if windows.contains(where: { $0.pid == parent }) {
                return parent
            }
            current = parent
        }
        return nil
    }

    func handleKeyDown(_ event: NSEvent, onDismiss: (() -> Void)?) -> Bool {
        guard !filteredWindows.isEmpty else { return false }

        switch Int(event.keyCode) {
        case 125: // Down arrow
            selectedIndex = (selectedIndex + 1) % filteredWindows.count
            return true
        case 126: // Up arrow
            selectedIndex = (selectedIndex - 1 + filteredWindows.count) % filteredWindows.count
            return true
        case 36, 76: // Enter/Return
            let window = filteredWindows[selectedIndex]
            focusWindow(axIndex: window.axIndex, pid: window.pid)
            onDismiss?()
            return true
        default:
            return false
        }
    }

    func focusWindow(axIndex: Int, pid: pid_t) {
        // Use NSRunningApplication to activate the specific process by PID
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            print("Could not find application with PID \(pid)")
            return
        }

        // Activate the specific process
        app.activate(options: [.activateIgnoringOtherApps])

        // Use Accessibility API to raise the specific window
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        guard result == .success,
              let windows = windowsRef as? [AXUIElement],
              axIndex > 0 && axIndex <= windows.count else {
            print("Could not get window \(axIndex) for PID \(pid)")
            return
        }

        let windowElement = windows[axIndex - 1]  // axIndex is 1-based
        AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
    }
}

struct WindowSwitcherView: View {
    @StateObject private var viewModel = WindowSwitcherViewModel()
    var themeManager: ThemeManager?
    weak var panel: KeyHandlingPanel?
    var onDismiss: (() -> Void)?

    init(themeManager: ThemeManager? = nil, panel: KeyHandlingPanel? = nil, onDismiss: (() -> Void)? = nil) {
        self.themeManager = themeManager
        self.panel = panel
        self.onDismiss = onDismiss
    }

    // Check if Screen Recording permission is granted
    private func checkPermissions() {
        viewModel.hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "macwindow.on.rectangle")
                    .foregroundColor(.accentColor)
                Text("Switch Window")
                    .font(.headline)
                Spacer()
                Text("⌃⌥P")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Search field
            TextField("Search windows...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.top, 8)

            // Window list
            if !viewModel.hasScreenRecordingPermission {
                VStack(spacing: 16) {
                    Spacer()
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 40))
                        .foregroundColor(.orange)

                    Text("Screen Recording Permission Required")
                        .font(.headline)

                    Text("Window names require Screen Recording permission to be displayed.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    VStack(spacing: 8) {
                        Button {
                            // Open System Settings to Privacy & Security > Screen Recording
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            HStack {
                                Image(systemName: "gear")
                                Text("Open System Settings")
                            }
                        }

                        Button {
                            checkPermissions()
                            if viewModel.hasScreenRecordingPermission {
                                loadWindows()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry")
                            }
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if viewModel.filteredWindows.isEmpty {
                VStack {
                    Spacer()
                    Text(viewModel.windows.isEmpty ? "No Ghostty windows open" : "No matching windows")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(Array(viewModel.filteredWindows.enumerated()), id: \.element.id) { index, window in
                                // Section header when state changes
                                if index == 0 || viewModel.filteredWindows[index - 1].claudeState != window.claudeState {
                                    sectionHeader(for: window.claudeState)
                                }

                                Button {
                                    viewModel.focusWindow(axIndex: window.axIndex, pid: window.pid)
                                    onDismiss?()
                                } label: {
                                    windowRow(window: window, isSelected: index == viewModel.selectedIndex)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    .onChange(of: viewModel.selectedIndex) { newIndex in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Text("↑↓ Navigate • Enter Select • Esc Close")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(viewModel.windows.count) window\(viewModel.windows.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
        .frame(width: 400, height: 300)
        .onAppear {
            debugLog("👁️ WindowSwitcherView.onAppear called")
            // Connect viewModel to themeManager for workstream lookup
            viewModel.themeManager = themeManager

            checkPermissions()
            if viewModel.hasScreenRecordingPermission {
                loadWindows()
            } else {
                debugLog("⚠️ No screen recording permission, requesting...")
                // Request permission (will show system dialog)
                CGRequestScreenCaptureAccess()
            }

            // Set up key handler on panel
            panel?.keyHandler = { [weak viewModel, onDismiss] event in
                viewModel?.handleKeyDown(event, onDismiss: onDismiss) ?? false
            }
        }
        .onDisappear {
            debugLog("👁️ WindowSwitcherView.onDisappear called")
            panel?.keyHandler = nil
        }
        .onChange(of: viewModel.searchText) { _ in
            viewModel.selectedIndex = 0
        }
        .onExitCommand {
            onDismiss?()
        }
    }

    // MARK: - View Helpers

    @ViewBuilder
    private func sectionHeader(for state: ClaudeState) -> some View {
        if state != .notRunning {
            HStack {
                Image(systemName: state.icon)
                    .font(.caption)
                Text(state.label)
                    .font(.caption)
                    .fontWeight(.semibold)
                Spacer()
            }
            .foregroundColor(state == .waiting ? .orange : .secondary)
            .padding(.horizontal, 4)
            .padding(.top, index(of: state) > 0 ? 12 : 4)
            .padding(.bottom, 4)
        }
    }

    private func index(of state: ClaudeState) -> Int {
        let states: [ClaudeState] = [.waiting, .running, .working, .notRunning]
        return states.firstIndex(of: state) ?? 0
    }

    @ViewBuilder
    private func windowRow(window: GhosttyWindow, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            // State icon
            Image(systemName: window.claudeState.icon)
                .foregroundColor(iconColor(for: window.claudeState))
                .frame(width: 16)

            // Window info
            VStack(alignment: .leading, spacing: 2) {
                // Primary: workstream name or display name
                Text(window.displayName)
                    .fontWeight(window.workstreamName != nil ? .medium : .regular)

                // Secondary: window title if different from display name
                if window.workstreamName != nil {
                    Text(window.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Claude state badge for "running" (when we detect Claude but can't tell exact state)
            if window.claudeState == .running {
                Text("Claude")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.2)
                : Color(NSColor.controlBackgroundColor).opacity(0.5)
        )
        .cornerRadius(6)
    }

    private func iconColor(for state: ClaudeState) -> Color {
        switch state {
        case .asking: return .red
        case .waiting: return .orange
        case .running: return .accentColor
        case .working: return .blue
        case .notRunning: return .secondary
        }
    }

    private func loadWindows() {
        debugLog("🔄 loadWindows() called")
        // Try to load windows using Accessibility API first (correct order for AppleScript)
        if loadWindowsViaAccessibilityAPI() {
            debugLog("✅ loadWindowsViaAccessibilityAPI succeeded")
            return
        }

        // Fall back to CGWindowList API if Accessibility fails
        debugLog("⚠️ Falling back to CGWindowList API")
        print("Falling back to CGWindowList API")
        loadWindowsViaCGWindowList()
    }

    private func loadWindowsViaAccessibilityAPI() -> Bool {
        // Get ALL Ghostty processes (not just the first one)
        let runningApps = NSWorkspace.shared.runningApplications
        let ghosttyApps = runningApps.filter { $0.bundleIdentifier == "com.mitchellh.ghostty" }

        guard !ghosttyApps.isEmpty else {
            print("No Ghostty processes found")
            return false
        }

        print("Found \(ghosttyApps.count) Ghostty process(es)")

        var ghosttyWindows: [GhosttyWindow] = []

        // Query windows from each Ghostty process
        for ghosttyApp in ghosttyApps {
            let pid = ghosttyApp.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            // Query windows from this specific process
            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

            guard result == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                print("Failed to get accessibility windows for PID \(pid) (error: \(result.rawValue))")
                continue  // Skip this process, try others
            }

            print("Process PID \(pid) returned \(windows.count) window(s)")

            // Enumerate windows from this process (1-based index per process)
            for (perProcessIndex, windowElement) in windows.enumerated() {
                // Get window title first for logging
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? "Window \(ghosttyWindows.count + 1)"

                // Get subrole for filtering
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String

                debugLog("  📋 Window[\(perProcessIndex)]: '\(title)' subrole=\(subrole ?? "nil")")

                // Skip utility windows, dialogs, floating panels
                if subrole == "AXFloatingWindow" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                    debugLog("    ❌ FILTERED OUT (subrole: \(subrole ?? "nil"))")
                    continue
                }

                // Use a unique ID based on current count, but axIndex is per-process (1-based)
                let id = ghosttyWindows.count + 1
                ghosttyWindows.append(GhosttyWindow(id: id, name: title, axIndex: perProcessIndex + 1, pid: pid))
                debugLog("    ✅ INCLUDED")
            }
        }

        print("Extracted \(ghosttyWindows.count) total Ghostty windows from Accessibility API")

        // Only return true if we actually found windows
        guard !ghosttyWindows.isEmpty else {
            print("Accessibility API returned empty window list - using CGWindowList fallback")
            return false
        }

        // Apply cached workstream names BEFORE displaying (makes repeat opens instant)
        viewModel.applyCachedWorkstreamNames(to: &ghosttyWindows)

        // Clean up cache for windows that no longer exist
        let activePids = Set(ghosttyWindows.map { $0.pid })
        viewModel.cleanupWorkstreamCache(activePids: activePids)

        // Show windows immediately with cached data
        debugLog("📺 Setting viewModel.windows (Accessibility API) with \(ghosttyWindows.count) windows:")
        for w in ghosttyWindows {
            debugLog("  - '\(w.name)' (PID: \(w.pid), axIndex: \(w.axIndex))")
        }
        viewModel.windows = ghosttyWindows

        // Reset selection if out of bounds
        if viewModel.selectedIndex >= ghosttyWindows.count {
            viewModel.selectedIndex = 0
        }

        // Enrich only windows that need it (skips cached ones)
        enrichWindowsAsync(ghosttyWindows)

        print("Successfully loaded \(ghosttyWindows.count) windows via Accessibility API")
        return true
    }

    private func debugLog(_ msg: String) {
        let log = "[\(Date())] \(msg)\n"
        if let data = log.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/gtp_debug.log") {
                if let handle = FileHandle(forWritingAtPath: "/tmp/gtp_debug.log") {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                FileManager.default.createFile(atPath: "/tmp/gtp_debug.log", contents: data)
            }
        }
    }

    /// Enrich windows with workstream names, shell cwd, and Claude process detection (async)
    private func enrichWindowsAsync(_ windows: [GhosttyWindow]) {
        debugLog("enrichWindowsAsync called with \(windows.count) windows")
        debugLog("themeManager is \(themeManager == nil ? "nil" : "set")")

        // Check which windows actually need workstream enrichment (expensive lsof calls)
        let windowsNeedingEnrichment = windows.filter { viewModel.needsWorkstreamEnrichment(pid: $0.pid) }
        debugLog("\(windowsNeedingEnrichment.count) of \(windows.count) windows need workstream enrichment")

        // If no windows need enrichment, we can skip the slow parts
        // But we still need to check Claude process status (uses cached process tree)
        let needsFullEnrichment = !windowsNeedingEnrichment.isEmpty

        let logFunc = self.debugLog
        DispatchQueue.global(qos: .userInitiated).async { [weak viewModel, weak themeManager] in
            logFunc("Inside async block, viewModel=\(viewModel == nil ? "nil" : "set"), themeManager=\(themeManager == nil ? "nil" : "set")")
            guard let viewModel = viewModel else {
                logFunc("viewModel is nil, returning")
                return
            }

            // Set debug logging on viewModel
            viewModel.debugLog = logFunc

            // Load process tree data once (single ps call) - needed for Claude detection
            viewModel.loadProcessCache()
            viewModel.loadHookStates()
            logFunc("Process cache loaded with \(viewModel.cachedProcessTree.count) entries")

            // Debug: show relevant entries for our window PIDs
            for window in windows {
                let children = viewModel.cachedProcessTree.filter { $0.value.ppid == window.pid }
                logFunc("  Children of PID \(window.pid): \(children.map { "(\($0.key): \($0.value.comm))" }.joined(separator: ", "))")
            }

            let enriched = windows.map { window -> GhosttyWindow in
                var enriched = window

                // Only do expensive lsof lookup if this window needs workstream enrichment
                if viewModel.needsWorkstreamEnrichment(pid: window.pid) {
                    // Get shell working directory (expensive - calls lsof)
                    enriched.shellCwd = viewModel.getShellCwd(ghosttyPid: window.pid)

                    // Get workstream name (from directory match)
                    let wsName = themeManager?.workstreamNameForPID(window.pid, shellCwd: enriched.shellCwd)
                    enriched.workstreamName = wsName

                    // Cache the result for next time (even if nil)
                    viewModel.cacheWorkstreamName(wsName, forPid: window.pid)
                    logFunc("Cached workstream for PID \(window.pid): \(wsName ?? "nil")")
                }
                // If workstream was already set from cache, keep it
                // (workstreamName was already populated by applyCachedWorkstreamNames)

                // Check for Claude process (uses cached process tree, fast)
                enriched.hasClaudeProcess = viewModel.hasClaudeProcess(ghosttyPid: window.pid)

                // Apply hook state from ~/.claude-states/
                let cwd = enriched.shellCwd ?? viewModel.getShellCwd(ghosttyPid: window.pid)
                if let cwd = cwd {
                    enriched.shellCwd = cwd
                    enriched.hookState = viewModel.getHookState(forCwd: cwd)
                }

                return enriched
            }

            logFunc("Enrichment complete. Windows with workstream names:")
            for w in enriched {
                logFunc("  PID \(w.pid): ws=\(w.workstreamName ?? "nil"), cwd=\(w.shellCwd ?? "nil"), cached=\(!viewModel.needsWorkstreamEnrichment(pid: w.pid))")
            }

            // Update UI on main thread - merge enriched data into current windows
            DispatchQueue.main.async {
                logFunc("🔀 Merging enriched windows into viewModel.windows")
                logFunc("  Current viewModel.windows count: \(viewModel.windows.count)")
                logFunc("  Enriched windows count: \(enriched.count)")
                // Update existing windows in place rather than replacing the list
                // This prevents windows from disappearing if the list changed during enrichment
                for enrichedWindow in enriched {
                    if let index = viewModel.windows.firstIndex(where: { $0.pid == enrichedWindow.pid && $0.axIndex == enrichedWindow.axIndex }) {
                        viewModel.windows[index].workstreamName = enrichedWindow.workstreamName
                        viewModel.windows[index].shellCwd = enrichedWindow.shellCwd
                        viewModel.windows[index].hasClaudeProcess = enrichedWindow.hasClaudeProcess
                        viewModel.windows[index].hookState = enrichedWindow.hookState
                        logFunc("  ✅ Merged: '\(enrichedWindow.name)' (PID: \(enrichedWindow.pid))")
                    } else {
                        logFunc("  ⚠️ No match for: '\(enrichedWindow.name)' (PID: \(enrichedWindow.pid), axIndex: \(enrichedWindow.axIndex))")
                    }
                }
                logFunc("  Final viewModel.windows count: \(viewModel.windows.count)")
            }
        }
    }

    private func loadWindowsViaCGWindowList() {
        debugLog("🔄 loadWindowsViaCGWindowList() called")
        // Use CGWindowList API to get Ghostty windows (fallback method)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            debugLog("❌ CGWindowListCopyWindowInfo returned nil")
            return
        }

        var ghosttyWindows: [GhosttyWindow] = []
        var perProcessIndices: [pid_t: Int] = [:]  // Track per-process window indices

        for window in windowList {
            let ownerName = window["kCGWindowOwnerName"] as? String
            let windowName = window["kCGWindowName"] as? String
            let windowLayer = window["kCGWindowLayer"] as? Int

            // Log Ghostty windows even if filtered
            if ownerName == "Ghostty" {
                debugLog("  📋 CGWindow: '\(windowName ?? "nil")' layer=\(windowLayer ?? -1)")
            }

            guard ownerName == "Ghostty",
                  let ownerPID = window["kCGWindowOwnerPID"] as? Int,
                  let layer = windowLayer,
                  layer == 0 else {  // Normal windows only (excludes utility windows, panels)
                if ownerName == "Ghostty" {
                    debugLog("    ❌ FILTERED OUT (layer: \(windowLayer ?? -1))")
                }
                continue
            }

            let pid = pid_t(ownerPID)
            let name = windowName ?? "Window \(ghosttyWindows.count + 1)"
            let windowNumber = window["kCGWindowNumber"] as? Int ?? ghosttyWindows.count + 1

            // Track per-process window index (1-based)
            let perProcessIndex = (perProcessIndices[pid] ?? 0) + 1
            perProcessIndices[pid] = perProcessIndex

            ghosttyWindows.append(GhosttyWindow(id: windowNumber, name: name, axIndex: perProcessIndex, pid: pid))
            debugLog("    ✅ INCLUDED")
        }

        // Apply cached workstream names BEFORE displaying
        viewModel.applyCachedWorkstreamNames(to: &ghosttyWindows)

        // Clean up cache for windows that no longer exist
        let activePids = Set(ghosttyWindows.map { $0.pid })
        viewModel.cleanupWorkstreamCache(activePids: activePids)

        // Show windows immediately with cached data
        debugLog("📺 Setting viewModel.windows (CGWindowList) with \(ghosttyWindows.count) windows:")
        for w in ghosttyWindows {
            debugLog("  - '\(w.name)' (PID: \(w.pid), axIndex: \(w.axIndex))")
        }
        viewModel.windows = ghosttyWindows

        // Reset selection if out of bounds
        if viewModel.selectedIndex >= ghosttyWindows.count {
            viewModel.selectedIndex = 0
        }

        // Enrich only windows that need it
        enrichWindowsAsync(ghosttyWindows)
    }
}

// MARK: - Quick Launch Panel

class QuickLaunchPanel {
    static let shared = QuickLaunchPanel()
    private var panel: NSPanel?
    private var themeManager: ThemeManager?

    func show(themeManager: ThemeManager?) {
        self.themeManager = themeManager

        if let existing = panel {
            existing.close()
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.windowBackgroundColor

        let view = QuickLaunchView(themeManager: themeManager ?? ThemeManager()) {
            panel.close()
        }

        panel.contentView = NSHostingView(rootView: view)
        panel.center()

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - Quick Launch View

struct QuickLaunchView: View {
    @ObservedObject var themeManager: ThemeManager
    var onDismiss: (() -> Void)?
    @State private var windowName: String = ""

    init(themeManager: ThemeManager, onDismiss: (() -> Void)? = nil) {
        self.themeManager = themeManager
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.accentColor)
                Text("Quick Launch")
                    .font(.headline)
                Spacer()
                Text("⌃⌥G")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // Window Name (optional)
                    HStack {
                        Image(systemName: "tag")
                            .frame(width: 24)
                            .foregroundColor(.secondary)
                        TextField("Window name (optional)", text: $windowName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                    // Random Theme
                    Button {
                        if let theme = themeManager.pickRandomTheme() {
                            themeManager.launchGhostty(withTheme: theme, name: windowName.isEmpty ? nil : windowName)
                            windowName = ""
                        }
                        onDismiss?()
                    } label: {
                        HStack {
                            Image(systemName: "dice")
                                .frame(width: 24)
                            Text("Random Theme")
                            Spacer()
                            Text("New window with random theme")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)

                    // Workstreams
                    if !themeManager.workstreams.isEmpty {
                        Text("WORKSTREAMS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)

                        ForEach(themeManager.workstreams) { workstream in
                            Button {
                                themeManager.launchWorkstream(workstream)
                                onDismiss?()
                            } label: {
                                HStack {
                                    ThemeSwatchView(colors: themeManager.getThemeColors(workstream.theme))
                                    VStack(alignment: .leading) {
                                        Text(workstream.name)
                                        if let dir = workstream.directory {
                                            Text(dir)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    Text(workstream.theme)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Favorites
                    if !themeManager.favoriteThemes.isEmpty {
                        Text("FAVORITES")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)

                        ForEach(themeManager.favoriteThemes, id: \.self) { theme in
                            Button {
                                themeManager.launchGhostty(withTheme: theme, name: windowName.isEmpty ? nil : windowName)
                                windowName = ""
                                onDismiss?()
                            } label: {
                                HStack {
                                    ThemeSwatchView(colors: themeManager.getThemeColors(theme))
                                    Image(systemName: "star.fill")
                                        .foregroundColor(.yellow)
                                        .font(.caption)
                                    Text(theme)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Recent
                    if !themeManager.recentThemes.isEmpty {
                        Text("RECENT")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 8)

                        ForEach(themeManager.recentThemes, id: \.self) { theme in
                            Button {
                                themeManager.launchGhostty(withTheme: theme, name: windowName.isEmpty ? nil : windowName)
                                windowName = ""
                                onDismiss?()
                            } label: {
                                HStack {
                                    ThemeSwatchView(colors: themeManager.getThemeColors(theme))
                                    Image(systemName: "clock")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                    Text(theme)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Text("Press Esc to close")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(8)
        }
        .frame(width: 320, height: 400)
        .onExitCommand {
            onDismiss?()
        }
    }
}

// MARK: - Save Workstream Panel

class SaveWorkstreamPanel {
    static let shared = SaveWorkstreamPanel()
    private var panel: NSPanel?

    func show(capturedWindow: CapturedWindow, themeManager: ThemeManager) {
        if let existing = panel {
            existing.close()
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = "Save Window as Workstream"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor.windowBackgroundColor

        let view = SaveWorkstreamView(
            capturedWindow: capturedWindow,
            themeManager: themeManager
        ) {
            panel.close()
        }

        panel.contentView = NSHostingView(rootView: view)
        panel.center()

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

// MARK: - Save Workstream View

struct SaveWorkstreamView: View {
    let capturedWindow: CapturedWindow
    @ObservedObject var themeManager: ThemeManager
    var onDismiss: (() -> Void)?

    @State private var name: String = ""
    @State private var selectedTheme: String = ""
    @State private var command: String = ""

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedTheme.isEmpty
    }

    /// Check if a workstream with this directory already exists
    var existingWorkstream: Workstream? {
        themeManager.workstreams.first { $0.directory == capturedWindow.directory }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Warning if workstream exists
                    if let existing = existingWorkstream {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("A workstream for this directory already exists: \"\(existing.name)\"")
                                .font(.caption)
                        }
                        .padding(8)
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(6)
                    }

                    // Name field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Workstream name", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Directory (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Directory")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Text(capturedWindow.directory)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                        .padding(8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                        Text("Detected from window")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Theme
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Theme")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let detectedTheme = capturedWindow.theme {
                            // Theme was detected
                            HStack {
                                ThemeSwatchView(colors: themeManager.getThemeColors(detectedTheme))
                                Text(detectedTheme)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            Text("Detected from launch")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            // Theme picker required
                            Picker("Theme", selection: $selectedTheme) {
                                Text("Select a theme...").tag("")
                                ForEach(themeManager.themes, id: \.self) { theme in
                                    HStack {
                                        Text(theme)
                                    }
                                    .tag(theme)
                                }
                            }
                            .labelsHidden()

                            if !selectedTheme.isEmpty {
                                HStack {
                                    ThemeSwatchView(colors: themeManager.getThemeColors(selectedTheme))
                                    Text(selectedTheme)
                                        .font(.caption)
                                }
                            }

                            Text("Window opened externally - please select theme")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }

                    // Command (optional)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command (optional)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., claude, zsh, nvim", text: $command)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave empty for default shell")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }

            Divider()

            // Buttons
            HStack {
                Button("Cancel") {
                    onDismiss?()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button("Save Workstream") {
                    saveWorkstream()
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 400, height: 380)
        .onAppear {
            // Initialize with captured data
            name = capturedWindow.suggestedName
            selectedTheme = capturedWindow.theme ?? ""
        }
    }

    private func saveWorkstream() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedCmd = command.trimmingCharacters(in: .whitespaces)
        let theme = capturedWindow.theme ?? selectedTheme

        themeManager.addWorkstream(
            name: trimmedName,
            theme: theme,
            directory: capturedWindow.directory,
            windowTitle: nil,
            command: trimmedCmd.isEmpty ? nil : trimmedCmd,
            autoLaunch: false,
            extraArgs: nil
        )

        onDismiss?()
    }
}

// MARK: - Theme Swatch View

struct ThemeSwatchView: View {
    let colors: ThemeColors
    let size: CGFloat

    init(colors: ThemeColors, size: CGFloat = 16) {
        self.colors = colors
        self.size = size
    }

    var body: some View {
        HStack(spacing: 1) {
            Rectangle()
                .fill(colors.background)
                .frame(width: size, height: size)
                .help("Background")
            Rectangle()
                .fill(colors.foreground)
                .frame(width: size * 0.5, height: size)
                .help("Foreground")
            Rectangle()
                .fill(colors.accent1)
                .frame(width: size * 0.5, height: size)
                .help("Accent (Magenta)")
            Rectangle()
                .fill(colors.accent2)
                .frame(width: size * 0.5, height: size)
                .help("Accent (Cyan)")
        }
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - Menu Content

struct MenuContent: View {
    @ObservedObject var themeManager: ThemeManager
    @Binding var showingWorkstreams: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = debugLog("MenuContent body, workstreams count: \(themeManager.workstreams.count)")
        // Workstreams Section
        if !themeManager.workstreams.isEmpty {
            Text("Workstreams")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(themeManager.workstreams) { workstream in
                Button {
                    debugLog("Button clicked for workstream: \(workstream.name)")
                    themeManager.launchWorkstream(workstream)
                } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(workstream.name)
                        Spacer()
                        Text(workstream.theme)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()
        }

        // Random Theme Button
        Button {
            if let theme = themeManager.pickRandomTheme() {
                themeManager.launchGhostty(withTheme: theme)
            }
        } label: {
            HStack {
                Image(systemName: "dice")
                Text("Random Theme")
            }
        }
        .keyboardShortcut("r", modifiers: .command)

        // Show last selected theme
        if let lastTheme = themeManager.lastSelectedTheme {
            Text("Last: \(lastTheme)")
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Divider()

        // Save Current Window as Workstream
        Button {
            if let captured = WindowCapture.captureFrontmostGhosttyWindow(themeManager: themeManager) {
                SaveWorkstreamPanel.shared.show(capturedWindow: captured, themeManager: themeManager)
            } else {
                // No Ghostty window found - could show an alert
                print("No Ghostty window found to capture")
            }
        } label: {
            HStack {
                Image(systemName: "plus.rectangle.on.folder")
                Text("Save Current Window as Workstream...")
            }
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Divider()

        // Favorites Section
        if !themeManager.favoriteThemes.isEmpty {
            Menu("Favorites") {
                ForEach(themeManager.favoriteThemes, id: \.self) { theme in
                    Button {
                        themeManager.launchGhostty(withTheme: theme)
                    } label: {
                        Label(theme, systemImage: "star.fill")
                    }
                }
            }

            Divider()
        }

        // Recent Themes Section
        if !themeManager.recentThemes.isEmpty {
            Menu("Recent") {
                ForEach(themeManager.recentThemes, id: \.self) { theme in
                    Button {
                        themeManager.launchGhostty(withTheme: theme)
                    } label: {
                        if themeManager.isFavorite(theme) {
                            Label(theme, systemImage: "star.fill")
                        } else {
                            Text(theme)
                        }
                    }
                }

                Divider()

                if let lastTheme = themeManager.lastSelectedTheme {
                    Button {
                        themeManager.toggleFavorite(lastTheme)
                    } label: {
                        if themeManager.isFavorite(lastTheme) {
                            Label("Remove from Favorites", systemImage: "star.slash")
                        } else {
                            Label("Add to Favorites", systemImage: "star")
                        }
                    }

                    Button {
                        themeManager.toggleExcluded(lastTheme)
                    } label: {
                        if themeManager.isExcluded(lastTheme) {
                            Label("Include '\(lastTheme)' in Random", systemImage: "arrow.uturn.backward")
                        } else {
                            Label("Exclude '\(lastTheme)' from Random", systemImage: "eye.slash")
                        }
                    }
                }
            }

            Divider()
        }

        // Excluded Themes Section
        if !themeManager.excludedThemes.isEmpty {
            Menu("Excluded (\(themeManager.excludedThemes.count))") {
                ForEach(themeManager.excludedThemes, id: \.self) { theme in
                    Button {
                        themeManager.includeTheme(theme)
                    } label: {
                        Label(theme, systemImage: "arrow.uturn.backward")
                    }
                }

                Divider()

                Button {
                    themeManager.clearExcludedThemes()
                } label: {
                    Label("Clear All Excluded", systemImage: "trash")
                }
            }

            Divider()
        }

        // Theme count
        let availableCount = themeManager.themes.count - themeManager.excludedThemes.count
        Text("\(availableCount) themes available")
            .font(.caption)
            .foregroundColor(.secondary)

        Divider()

        // Settings & Actions
        Button {
            openWindow(id: "workstreams")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            HStack {
                Image(systemName: "gear")
                Text("Settings...")
            }
        }
        .keyboardShortcut(",", modifiers: .command)

        Button {
            themeManager.fetchThemes()
        } label: {
            HStack {
                Image(systemName: "arrow.clockwise")
                Text("Refresh Themes")
            }
        }

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

// MARK: - Settings View (Tabbed)

struct SettingsView: View {
    @ObservedObject var themeManager: ThemeManager
    @ObservedObject var hotkeyManager: HotkeyManager

    var body: some View {
        TabView {
            WorkstreamsSettingsView(themeManager: themeManager)
                .tabItem {
                    Label("Workstreams", systemImage: "folder")
                }

            ClaudeHooksSettingsView()
                .tabItem {
                    Label("Claude Hooks", systemImage: "terminal.fill")
                }

            StreamDeckSettingsView()
                .tabItem {
                    Label("Stream Deck", systemImage: "square.grid.3x3")
                }

            HotkeysSettingsView(hotkeyManager: hotkeyManager)
                .tabItem {
                    Label("Hotkeys", systemImage: "keyboard")
                }
        }
        .frame(width: 500, height: 400)
    }
}

// MARK: - Workstreams Settings View

struct WorkstreamsSettingsView: View {
    @ObservedObject var themeManager: ThemeManager
    @State private var showingAddSheet = false
    @State private var showingExportSheet = false
    @State private var editingWorkstream: Workstream?
    @State private var selectedForExport: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workstreams")
                .font(.headline)

            Text("Create named workstreams with assigned themes and directories for quick access.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(themeManager.workstreams) { workstream in
                    HStack {
                        if workstream.autoLaunch {
                            Image(systemName: "play.circle.fill")
                                .foregroundColor(.green)
                                .help("Auto-launches on startup")
                        }
                        VStack(alignment: .leading) {
                            Text(workstream.name)
                                .fontWeight(.medium)
                            HStack {
                                Text(workstream.theme)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if let dir = workstream.directory, !dir.isEmpty {
                                    Text("•")
                                        .foregroundColor(.secondary)
                                    Text(dir)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }

                        Spacer()

                        Button {
                            editingWorkstream = workstream
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)

                        Button {
                            themeManager.deleteWorkstream(workstream)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.red)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 150)

            HStack {
                Button {
                    importWorkstreams()
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import...")
                    }
                }

                Button {
                    selectedForExport = Set(themeManager.workstreams.map { $0.id })
                    showingExportSheet = true
                } label: {
                    HStack {
                        Image(systemName: "square.and.arrow.up")
                        Text("Export...")
                    }
                }
                .disabled(themeManager.workstreams.isEmpty)

                Spacer()

                Button {
                    showingAddSheet = true
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Add Workstream")
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showingAddSheet) {
            WorkstreamEditorView(themeManager: themeManager, workstream: nil) {
                showingAddSheet = false
            }
        }
        .sheet(item: $editingWorkstream) { workstream in
            WorkstreamEditorView(themeManager: themeManager, workstream: workstream) {
                editingWorkstream = nil
            }
        }
        .sheet(isPresented: $showingExportSheet) {
            ExportWorkstreamsView(
                themeManager: themeManager,
                selectedForExport: $selectedForExport
            ) {
                showingExportSheet = false
            }
        }
    }

    private func importWorkstreams() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "Import Workstreams"

        if panel.runModal() == .OK, let url = panel.url {
            if let data = try? Data(contentsOf: url) {
                let count = themeManager.importWorkstreams(from: data)
                if count > 0 {
                    // Show brief confirmation - workstreams will appear in list
                }
            }
        }
    }
}

// MARK: - Claude Hooks Settings View

struct ClaudeHooksSettingsView: View {
    @State private var isInstalled = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Asking Detection")
                .font(.headline)

            Text("Install Claude Code hooks to detect when Claude asks a question or needs permission. This enables the \"asking\" state indicator in the window switcher and Stream Deck.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Status indicator
            HStack {
                Image(systemName: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(isInstalled ? .green : .secondary)
                Text(isInstalled ? "Hooks installed" : "Hooks not installed")
                    .font(.body)
            }
            .padding(.vertical, 4)

            // Description of what gets installed
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This will install:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text("~/.claude/hooks/claude-state-hook.sh")
                                    .font(.system(.caption, design: .monospaced))
                                Text("Detects when Claude asks questions in responses")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack(alignment: .top) {
                            Image(systemName: "doc.text")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text("~/.claude/hooks/permission-hook.sh")
                                    .font(.system(.caption, design: .monospaced))
                                Text("Detects permission prompts")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack(alignment: .top) {
                            Image(systemName: "gearshape")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text("~/.claude/settings.json")
                                    .font(.system(.caption, design: .monospaced))
                                Text("Adds hook configuration (preserves existing settings)")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // Error/Success messages
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if let success = successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            // Action buttons
            HStack {
                if isInstalled {
                    Button {
                        uninstallHooks()
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text("Uninstall Hooks")
                        }
                    }
                    .disabled(isProcessing)
                } else {
                    Button {
                        installHooks()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Install Hooks")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)
                }

                if isProcessing {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .padding()
        .onAppear {
            checkInstallationStatus()
        }
    }

    private func checkInstallationStatus() {
        isInstalled = HookInstaller.shared.areHooksInstalled()
    }

    private func installHooks() {
        isProcessing = true
        errorMessage = nil
        successMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try HookInstaller.shared.installHooks()
                DispatchQueue.main.async {
                    isProcessing = false
                    isInstalled = true
                    successMessage = "Hooks installed successfully. Restart Claude Code to activate."
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func uninstallHooks() {
        isProcessing = true
        errorMessage = nil
        successMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try HookInstaller.shared.uninstallHooks()
                DispatchQueue.main.async {
                    isProcessing = false
                    isInstalled = false
                    successMessage = "Hooks uninstalled successfully."
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Stream Deck Settings View

struct StreamDeckSettingsView: View {
    @State private var isInstalled = false
    @State private var installedVersion: String?
    @State private var latestVersion: String?
    @State private var downloadURL: String?
    @State private var isLoading = false
    @State private var isDownloading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var streamDeckInstalled = false

    private var updateAvailable: Bool {
        guard let installed = installedVersion, let latest = latestVersion else { return false }
        return StreamDeckInstaller.shared.isUpdateAvailable(installed: installed, latest: latest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Stream Deck Plugin")
                .font(.headline)

            Text("Install the Ghostty Claude plugin for Elgato Stream Deck to display Claude state indicators and quickly switch between Ghostty windows.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Stream Deck app status
            if !streamDeckInstalled {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Stream Deck app not detected")
                        .font(.caption)
                    Spacer()
                    Link("Get a Stream Deck", destination: URL(string: "https://www.elgato.com/us/en/s/explore-stream-deck")!)
                        .font(.caption)
                }
                .padding(.vertical, 4)
            }

            // Plugin status
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(isInstalled ? .green : .secondary)
                        if isInstalled {
                            Text("Plugin installed")
                            if let version = installedVersion {
                                Text("v\(version)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            Text("Plugin not installed")
                        }
                    }

                    if let latest = latestVersion {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundColor(.blue)
                            Text("Latest version: v\(latest)")
                                .font(.caption)
                            if updateAvailable {
                                Text("(Update available)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                        }
                    }

                    if isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Checking for updates...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // Description
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Features:")
                        .font(.caption)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("Show Claude state for each Ghostty window", systemImage: "circle.fill")
                            .font(.caption)
                        Label("Click to focus window", systemImage: "arrow.right.circle")
                            .font(.caption)
                        Label("Windows sorted by priority (asking first)", systemImage: "list.number")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            // Error/Success messages
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if let success = successMessage {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(success)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            // Action buttons
            HStack {
                Button {
                    checkForUpdates()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Check for Updates")
                    }
                }
                .disabled(isLoading || isDownloading)

                Spacer()

                if isInstalled && updateAvailable {
                    Button {
                        installOrUpdate()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                            Text("Update Plugin")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading || downloadURL == nil)
                } else if !isInstalled {
                    Button {
                        installOrUpdate()
                    } label: {
                        HStack {
                            Image(systemName: "square.and.arrow.down")
                            Text("Install Plugin")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDownloading || downloadURL == nil)
                }

                if isDownloading {
                    ProgressView()
                        .scaleEffect(0.6)
                }
            }
        }
        .padding()
        .onAppear {
            checkStatus()
            checkForUpdates()
        }
    }

    private func checkStatus() {
        streamDeckInstalled = StreamDeckInstaller.shared.isStreamDeckInstalled()
        isInstalled = StreamDeckInstaller.shared.isInstalled()
        installedVersion = StreamDeckInstaller.shared.installedVersion()
    }

    private func checkForUpdates() {
        isLoading = true
        errorMessage = nil

        StreamDeckInstaller.shared.fetchLatestRelease { result in
            DispatchQueue.main.async {
                isLoading = false
                switch result {
                case .success(let release):
                    latestVersion = release.version
                    downloadURL = release.downloadURL
                case .failure(let error):
                    errorMessage = "Failed to check for updates: \(error.localizedDescription)"
                }
            }
        }
    }

    private func installOrUpdate() {
        guard let url = downloadURL else { return }

        isDownloading = true
        errorMessage = nil
        successMessage = nil

        StreamDeckInstaller.shared.installPlugin(from: url) { result in
            DispatchQueue.main.async {
                isDownloading = false
                switch result {
                case .success:
                    successMessage = "Plugin downloaded. Stream Deck installer should open automatically."
                    // Refresh status after a delay to allow installation
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        checkStatus()
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Hotkeys Settings View

struct HotkeysSettingsView: View {
    @ObservedObject var hotkeyManager: HotkeyManager
    @State private var recordingTarget: RecordingTarget?
    @State private var eventMonitor: Any?
    @State private var conflictWarning: String?

    enum RecordingTarget {
        case quickLaunch
        case windowSwitcher
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Global Hotkeys")
                .font(.headline)

            Text("Customize keyboard shortcuts for Quick Launch and Window Switcher.")
                .font(.caption)
                .foregroundColor(.secondary)

            GroupBox {
                VStack(spacing: 0) {
                    hotkeyRow(
                        label: "Quick Launch",
                        config: $hotkeyManager.quickLaunchConfig,
                        target: .quickLaunch,
                        defaultConfig: .defaultQuickLaunch
                    )

                    Divider()

                    hotkeyRow(
                        label: "Window Switcher",
                        config: $hotkeyManager.windowSwitcherConfig,
                        target: .windowSwitcher,
                        defaultConfig: .defaultWindowSwitcher
                    )
                }
            }

            if let warning = conflictWarning {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(warning)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
                Text("Press Record, then press your desired key combination. At least one modifier key (⌃⌥⇧⌘) is required.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Reset All") {
                    hotkeyManager.quickLaunchConfig = .defaultQuickLaunch
                    hotkeyManager.windowSwitcherConfig = .defaultWindowSwitcher
                    hotkeyManager.reregisterHotkeys()
                    conflictWarning = nil
                }
                .disabled(
                    hotkeyManager.quickLaunchConfig == .defaultQuickLaunch &&
                    hotkeyManager.windowSwitcherConfig == .defaultWindowSwitcher
                )
            }
        }
        .padding()
    }

    @ViewBuilder
    private func hotkeyRow(
        label: String,
        config: Binding<HotkeyConfig>,
        target: RecordingTarget,
        defaultConfig: HotkeyConfig
    ) -> some View {
        HStack(spacing: 12) {
            Toggle(label, isOn: config.enabled)
                .onChange(of: config.wrappedValue.enabled) { _ in
                    checkConflicts()
                    hotkeyManager.reregisterHotkeys()
                }
                .frame(width: 150, alignment: .leading)

            if recordingTarget == target {
                Text("Press keys...")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(4)
                    .frame(minWidth: 80)
            } else {
                Text(config.wrappedValue.displayString)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(4)
                    .frame(minWidth: 80)
            }

            Button(recordingTarget == target ? "Cancel" : "Record") {
                if recordingTarget == target {
                    stopRecording()
                } else {
                    startRecording(for: target)
                }
            }
            .buttonStyle(.bordered)

            Button("Reset") {
                config.wrappedValue = defaultConfig
                checkConflicts()
                hotkeyManager.reregisterHotkeys()
            }
            .disabled(config.wrappedValue == defaultConfig)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }

    private func startRecording(for target: RecordingTarget) {
        recordingTarget = target
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { // Escape
                stopRecording()
                return nil
            }

            let mods = carbonModifiers(from: event.modifierFlags)
            if mods == 0 {
                // No modifier pressed, ignore
                return nil
            }

            let newConfig = HotkeyConfig(
                keyCode: UInt32(event.keyCode),
                modifiers: mods,
                enabled: true
            )

            switch target {
            case .quickLaunch:
                hotkeyManager.quickLaunchConfig = newConfig
            case .windowSwitcher:
                hotkeyManager.windowSwitcherConfig = newConfig
            }

            stopRecording()
            checkConflicts()
            hotkeyManager.reregisterHotkeys()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingTarget = nil
    }

    private func checkConflicts() {
        let q = hotkeyManager.quickLaunchConfig
        let w = hotkeyManager.windowSwitcherConfig
        if q.enabled && w.enabled && q.keyCode == w.keyCode && q.modifiers == w.modifiers {
            conflictWarning = "Both hotkeys are set to the same shortcut (\(q.displayString)). Only Quick Launch will be registered."
        } else {
            conflictWarning = nil
        }
    }
}

// MARK: - Export Workstreams View

struct ExportWorkstreamsView: View {
    @ObservedObject var themeManager: ThemeManager
    @Binding var selectedForExport: Set<UUID>
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Workstreams")
                .font(.headline)

            Text("Select which workstreams to export:")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(themeManager.workstreams) { workstream in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { selectedForExport.contains(workstream.id) },
                            set: { isSelected in
                                if isSelected {
                                    selectedForExport.insert(workstream.id)
                                } else {
                                    selectedForExport.remove(workstream.id)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)

                        ThemeSwatchView(colors: themeManager.getThemeColors(workstream.theme), size: 14)

                        VStack(alignment: .leading) {
                            Text(workstream.name)
                                .fontWeight(.medium)
                            Text(workstream.theme)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 150)

            HStack {
                Button("Select All") {
                    selectedForExport = Set(themeManager.workstreams.map { $0.id })
                }

                Button("Select None") {
                    selectedForExport.removeAll()
                }

                Spacer()

                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.escape)

                Button("Export...") {
                    exportSelected()
                }
                .keyboardShortcut(.return)
                .disabled(selectedForExport.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }

    private func exportSelected() {
        let selected = themeManager.workstreams.filter { selectedForExport.contains($0.id) }
        guard let data = themeManager.exportWorkstreams(selected) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "workstreams.json"
        panel.title = "Export Workstreams"

        if panel.runModal() == .OK, let url = panel.url {
            try? data.write(to: url)
            onDismiss()
        }
    }
}

// MARK: - Workstream Editor

struct WorkstreamEditorView: View {
    @ObservedObject var themeManager: ThemeManager
    let workstream: Workstream?
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var selectedTheme: String = ""
    @State private var directory: String = ""
    @State private var windowTitle: String = ""
    @State private var command: String = ""
    @State private var extraArgs: String = ""
    @State private var autoLaunch: Bool = false
    @State private var themeSearchText: String = ""
    @State private var themeCategory: ThemeCategory = .all

    enum ThemeCategory: String, CaseIterable {
        case all = "All"
        case dark = "Dark"
        case light = "Light"
    }

    var filteredThemes: [String] {
        var themes = themeManager.themes

        // Filter by category
        switch themeCategory {
        case .all:
            break
        case .dark:
            themes = themes.filter { themeManager.isDarkTheme($0) }
        case .light:
            themes = themes.filter { !themeManager.isDarkTheme($0) }
        }

        // Filter by search text
        if !themeSearchText.isEmpty {
            themes = themes.filter { $0.localizedCaseInsensitiveContains(themeSearchText) }
        }

        return themes
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !selectedTheme.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(workstream == nil ? "New Workstream" : "Edit Workstream")
                .font(.headline)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name field
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., Backend API, Bug Fixes", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Theme picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Theme")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("Search themes...", text: $themeSearchText)
                                .textFieldStyle(.roundedBorder)

                            Picker("", selection: $themeCategory) {
                                ForEach(ThemeCategory.allCases, id: \.self) { category in
                                    Text(category.rawValue).tag(category)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 150)

                            Button {
                                if let randomTheme = filteredThemes.randomElement() {
                                    selectedTheme = randomTheme
                                }
                            } label: {
                                Image(systemName: "dice")
                            }
                            .help("Pick random theme")
                        }

                        Text("\(filteredThemes.count) themes")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        List(filteredThemes.prefix(100), id: \.self, selection: $selectedTheme) { theme in
                            HStack {
                                ThemeSwatchView(colors: themeManager.getThemeColors(theme), size: 14)
                                Text(theme)
                            }
                            .tag(theme)
                        }
                        .frame(height: 100)
                        .border(Color.gray.opacity(0.3))

                        if !selectedTheme.isEmpty {
                            HStack {
                                ThemeSwatchView(colors: themeManager.getThemeColors(selectedTheme))
                                Text("Selected: \(selectedTheme)")
                                    .font(.caption)
                                    .foregroundColor(.blue)
                            }
                        }
                    }

                    // Directory picker
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Working Directory")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("/path/to/project", text: $directory)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse...") {
                                selectDirectory()
                            }
                        }
                    }

                    // Window Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Window Title")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., Claude - Backend", text: $windowTitle)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Command
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Command to Run")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., claude, zsh, nvim", text: $command)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave empty for default shell")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Extra Ghostty Args
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Extra Ghostty Options")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., --font-size=14 --window-padding-x=10", text: $extraArgs)
                            .textFieldStyle(.roundedBorder)
                        Text("Space-separated Ghostty CLI options")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    // Auto-launch
                    Divider()
                    Toggle(isOn: $autoLaunch) {
                        VStack(alignment: .leading) {
                            Text("Auto-launch on startup")
                            Text("Open this workstream when the app starts")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()
                .padding(.vertical, 12)

            // Buttons
            HStack {
                Button("Cancel") {
                    onDismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Button(workstream == nil ? "Create" : "Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 450, height: 520)
        .onAppear {
            if let ws = workstream {
                name = ws.name
                selectedTheme = ws.theme
                directory = ws.directory ?? ""
                windowTitle = ws.windowTitle ?? ""
                command = ws.command ?? ""
                extraArgs = ws.extraArgs ?? ""
                autoLaunch = ws.autoLaunch
            }
        }
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            directory = url.path
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDir = directory.trimmingCharacters(in: .whitespaces)
        let trimmedTitle = windowTitle.trimmingCharacters(in: .whitespaces)
        let trimmedCmd = command.trimmingCharacters(in: .whitespaces)
        let trimmedArgs = extraArgs.trimmingCharacters(in: .whitespaces)

        if let existing = workstream {
            var updated = existing
            updated.name = trimmedName
            updated.theme = selectedTheme
            updated.directory = trimmedDir.isEmpty ? nil : trimmedDir
            updated.windowTitle = trimmedTitle.isEmpty ? nil : trimmedTitle
            updated.command = trimmedCmd.isEmpty ? nil : trimmedCmd
            updated.extraArgs = trimmedArgs.isEmpty ? nil : trimmedArgs
            updated.autoLaunch = autoLaunch
            themeManager.updateWorkstream(updated)
        } else {
            themeManager.addWorkstream(
                name: trimmedName,
                theme: selectedTheme,
                directory: trimmedDir.isEmpty ? nil : trimmedDir,
                windowTitle: trimmedTitle.isEmpty ? nil : trimmedTitle,
                command: trimmedCmd.isEmpty ? nil : trimmedCmd,
                autoLaunch: autoLaunch,
                extraArgs: trimmedArgs.isEmpty ? nil : trimmedArgs
            )
        }
        onDismiss()
    }
}

// Helper extension for debug logging
extension String {
    func appendToFile(atPath path: String) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            try self.write(toFile: path, atomically: true, encoding: .utf8)
        } else {
            let fileHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            fileHandle.seekToEndOfFile()
            if let data = self.data(using: .utf8) {
                fileHandle.write(data)
            }
            fileHandle.closeFile()
        }
    }
}
