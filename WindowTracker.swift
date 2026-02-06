import Foundation
import AppKit
import ApplicationServices

// MARK: - Window Tracker

/// Tracks Ghostty windows continuously in the background for API access.
/// Unlike WindowSwitcherViewModel which only runs when the panel is open,
/// this tracker runs continuously to provide fresh data to the API.
class WindowTracker: ObservableObject {
    static let shared = WindowTracker()

    @Published var ghosttyWindows: [GhosttyWindow] = []

    weak var themeManager: ThemeManager?

    private var refreshTimer: Timer?
    private let refreshInterval: TimeInterval = 1.0  // 1 second

    // Cached process data
    private var cachedProcessTree: [pid_t: (ppid: pid_t, comm: String)] = [:]
    private var cachedClaudePids: Set<pid_t> = []
    private var cachedShellCwds: [pid_t: String] = [:]
    private var workstreamCache: [pid_t: String?] = [:]
    private var hookStateCache: [String: (state: String, timestamp: TimeInterval)] = [:]  // cwd -> hook state

    private init() {}

    func start() {
        guard refreshTimer == nil else { return }

        // Debug: Print accessibility hierarchy for first window
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let firstWindow = self.ghosttyWindows.first {
                print("=== DEBUG: Exploring Ghostty accessibility hierarchy ===")
                TerminalContentReader.debugHierarchy(pid: firstWindow.pid, axIndex: firstWindow.axIndex)
                print("=== END DEBUG ===")
            }
        }

        // Initial refresh
        refreshWindows()

        // Start periodic refresh
        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshWindows()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)

        print("WindowTracker started")
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        print("WindowTracker stopped")
    }

    // MARK: - Window Refresh

    func refreshWindows() {
        // Check screen recording permission first
        guard CGPreflightScreenCaptureAccess() else {
            return
        }

        // Load process tree data (single ps call)
        loadProcessCache()

        // Get windows via Accessibility API (preferred) or CGWindowList (fallback)
        var windows = loadWindowsViaAccessibilityAPI()
        if windows.isEmpty {
            windows = loadWindowsViaCGWindowList()
        }

        // Apply cached workstream names
        applyCachedWorkstreamNames(to: &windows)

        // Enrich windows with Claude process detection
        enrichWindows(&windows)

        // Clean up cache for PIDs that no longer exist
        let activePids = Set(windows.map { $0.pid })
        workstreamCache = workstreamCache.filter { activePids.contains($0.key) }

        // Update published property on main thread
        DispatchQueue.main.async {
            self.ghosttyWindows = windows
        }
    }

    // MARK: - Window Loading

    private func loadWindowsViaAccessibilityAPI() -> [GhosttyWindow] {
        let runningApps = NSWorkspace.shared.runningApplications
        let ghosttyApps = runningApps.filter { $0.bundleIdentifier == "com.mitchellh.ghostty" }

        guard !ghosttyApps.isEmpty else {
            return []
        }

        var windows: [GhosttyWindow] = []

        for ghosttyApp in ghosttyApps {
            let pid = ghosttyApp.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            var windowsRef: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

            guard result == .success,
                  let axWindows = windowsRef as? [AXUIElement] else {
                continue
            }

            for (perProcessIndex, windowElement) in axWindows.enumerated() {
                // Get window title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? "Window \(windows.count + 1)"

                // Get subrole for filtering
                var subroleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXSubroleAttribute as CFString, &subroleRef)
                let subrole = subroleRef as? String

                // Skip utility windows, dialogs, floating panels
                if subrole == "AXFloatingWindow" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                    continue
                }

                let id = windows.count + 1
                windows.append(GhosttyWindow(id: id, name: title, axIndex: perProcessIndex + 1, pid: pid))
            }
        }

        return windows
    }

    private func loadWindowsViaCGWindowList() -> [GhosttyWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var windows: [GhosttyWindow] = []
        var perProcessIndices: [pid_t: Int] = [:]

        for window in windowList {
            guard let ownerName = window["kCGWindowOwnerName"] as? String,
                  ownerName == "Ghostty",
                  let ownerPID = window["kCGWindowOwnerPID"] as? Int,
                  let layer = window["kCGWindowLayer"] as? Int,
                  layer == 0 else {
                continue
            }

            let pid = pid_t(ownerPID)
            let name = window["kCGWindowName"] as? String ?? "Window \(windows.count + 1)"
            let windowNumber = window["kCGWindowNumber"] as? Int ?? windows.count + 1

            let perProcessIndex = (perProcessIndices[pid] ?? 0) + 1
            perProcessIndices[pid] = perProcessIndex

            windows.append(GhosttyWindow(id: windowNumber, name: name, axIndex: perProcessIndex, pid: pid))
        }

        return windows
    }

    // MARK: - Process Cache

    private func loadProcessCache() {
        cachedProcessTree.removeAll()
        cachedClaudePids.removeAll()

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

    // MARK: - Enrichment

    private func applyCachedWorkstreamNames(to windows: inout [GhosttyWindow]) {
        for i in windows.indices {
            let pid = windows[i].pid
            if let name = themeManager?.launchedWindows[pid] {
                windows[i].workstreamName = name
            } else if let cached = workstreamCache[pid], let name = cached {
                windows[i].workstreamName = name
            }
        }
    }

    private func enrichWindows(_ windows: inout [GhosttyWindow]) {
        // Load hook state files once per refresh
        loadHookStates()

        for i in windows.indices {
            let pid = windows[i].pid

            // Get shell CWD if not cached
            if windows[i].workstreamName == nil && !workstreamCache.keys.contains(pid) {
                if let cwd = getShellCwd(ghosttyPid: pid) {
                    windows[i].shellCwd = cwd
                    let wsName = themeManager?.workstreamNameForPID(pid, shellCwd: cwd)
                    windows[i].workstreamName = wsName
                    workstreamCache[pid] = wsName
                } else {
                    workstreamCache[pid] = nil
                }
            }

            // Check for Claude process
            windows[i].hasClaudeProcess = hasClaudeProcess(ghosttyPid: pid)

            // Apply hook state - try multiple sources for CWD
            var cwdToCheck: String? = windows[i].shellCwd

            // If no shellCwd, try to get directory from workstream
            if cwdToCheck == nil, let wsName = windows[i].workstreamName {
                cwdToCheck = themeManager?.directoryForWorkstream(wsName)
            }

            // Last resort: try to get fresh shell CWD
            if cwdToCheck == nil {
                cwdToCheck = getShellCwd(ghosttyPid: pid)
                if let cwd = cwdToCheck {
                    windows[i].shellCwd = cwd
                }
            }

            if let cwd = cwdToCheck {
                windows[i].hookState = getHookState(forCwd: cwd)
            }
        }
    }

    // MARK: - Hook State Reading

    private func loadHookStates() {
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

            // Only update cache if this is newer than what we have
            // This keeps "asking" state until a newer state replaces it
            if let existing = hookStateCache[cwd] {
                if timestamp > existing.timestamp {
                    hookStateCache[cwd] = (state: state, timestamp: timestamp)
                }
            } else {
                hookStateCache[cwd] = (state: state, timestamp: timestamp)
            }
        }
    }

    private func getHookState(forCwd cwd: String) -> String? {
        // Direct match
        if let cached = hookStateCache[cwd] {
            return cached.state
        }

        // Try matching by subdirectory (hook might be running in a subdirectory)
        for (cachedCwd, cached) in hookStateCache {
            if cwd.hasPrefix(cachedCwd + "/") || cachedCwd.hasPrefix(cwd + "/") {
                return cached.state
            }
        }

        return nil
    }

    private func getShellCwd(ghosttyPid: pid_t) -> String? {
        // Find login -> shell chain
        guard let loginPid = cachedProcessTree.first(where: {
            $0.value.ppid == ghosttyPid && $0.value.comm.contains("login")
        })?.key else {
            return nil
        }

        guard let shellEntry = cachedProcessTree.first(where: {
            $0.value.ppid == loginPid
        }) else {
            return nil
        }

        let shellPid = shellEntry.key

        // Check cache
        if let cached = cachedShellCwds[shellPid] {
            return cached
        }

        // Get CWD using lsof
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-p", "\(shellPid)", "-d", "cwd", "-F", "n"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                let cwd = String(line.dropFirst())
                cachedShellCwds[shellPid] = cwd
                return cwd
            }
        }

        return nil
    }

    private func hasClaudeProcess(ghosttyPid: pid_t) -> Bool {
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
            if ghosttyWindows.contains(where: { $0.pid == parent }) {
                return parent
            }
            current = parent
        }
        return nil
    }

    // MARK: - Focus Window

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
