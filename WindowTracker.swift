import Foundation
import AppKit
import ApplicationServices

// MARK: - Process Helpers

/// A process's argv (including argv[0]) via sysctl, or nil if it can't be read
func processArguments(pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

    // Layout: argc (Int32), executable path, NUL padding, then argc NUL-terminated args
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    let strings = buffer[MemoryLayout<Int32>.size..<size]
        .split(separator: 0, omittingEmptySubsequences: true)
        .map { String(decoding: $0, as: UTF8.self) }
    return Array(strings.dropFirst().prefix(Int(argc)))  // drop executable path
}

/// When a process started, via sysctl
func processStartDate(pid: pid_t) -> Date? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let start = info.kp_proc.p_un.__p_starttime
    return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
}

/// Names a shell from the command Claude's Bash tool ran, e.g. "gh pr checks" for
/// `until out=$(gh pr checks 404); do sleep 30; done`
enum ShellCommandNamer {
    /// Commands that say nothing about what a shell is for (their whole simple command is skipped)
    static let uninformative: Set<String> = [
        "sleep", "cat", "tee", "head", "tail", "grep", "egrep", "sed", "awk", "xargs", "wc", "sort",
        "uniq", "cut", "tr", "true", "false", "timeout", "caffeinate", "echo", "printf", "test", "[", "[[",
        "cd", "pushd", "popd", "export", "unset", "set", "setopt", "source", ".", "local", "read",
        "eval", "trap", "wait", "exit", "return", "break", "continue", "mkdir", "rm", "date",
    ]
    /// Wrappers whose arguments are the real command
    private static let prefixes: Set<String> = [
        "sh", "bash", "zsh", "env", "nohup", "sudo", "exec", "time", "command", "builtin", "nice",
    ]
    /// Interpreters that add nothing as a "› current process" suffix (`npm run dev › node`)
    static let runtimes: Set<String> = ["node", "python", "python3", "ruby", "java", "deno", "bun", "Python"]

    /// "what Claude ran › what's running now", dropping the suffix when it adds nothing
    static func displayLabel(script: String?, leaf: String) -> String {
        guard let script = script, let command = label(forScript: script) else { return leaf }
        let commandName = command.split(separator: " ").first.map(String.init) ?? command
        let leafAddsInfo = !uninformative.contains(leaf) && !prefixes.contains(leaf) &&
            !runtimes.contains(leaf) && leaf != commandName
        return leafAddsInfo ? "\(command) › \(leaf)" : command
    }

    private static let keywords: Set<String> = [
        "until", "while", "if", "then", "do", "done", "else", "elif", "fi", "!", "esac",
    ]
    /// Keywords whose whole simple command is syntax, not a command (`for i in 1 2`)
    private static let skipKeywords: Set<String> = ["for", "select", "case", "function"]

    /// The command Claude asked for: the body of `eval '…'` in the snapshot wrapper
    static func evalBody(_ script: String) -> String? {
        guard let start = script.range(of: "eval '") else { return nil }
        var body = ""
        var i = start.upperBound
        while i < script.endIndex {
            let rest = script[i...]
            if rest.hasPrefix("'\\''") {             // '\'' escaped single quote
                body.append("'")
                i = script.index(i, offsetBy: 4)
            } else if rest.hasPrefix("'\"'\"'") {     // '"'"' escaped single quote
                body.append("'")
                i = script.index(i, offsetBy: 5)
            } else if script[i] == "'" {
                return body
            } else {
                body.append(script[i])
                i = script.index(after: i)
            }
        }
        return body
    }

    /// Split a shell snippet into simple commands at ; | & ( ) { } and newlines, ignoring
    /// separators inside quotes (e.g. a grep pattern "a|b"). `$(` always starts a new command.
    private static func simpleCommands(in script: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var previous: Character?
        for ch in script {
            defer { previous = ch }
            if ch == "(" && previous == "$" {
                current.removeLast()  // drop the "$"
                segments.append(current); current = ""
                quote = nil           // inside $( … ) quoting starts fresh
                continue
            }
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                current.append(ch)
            case ";", "|", "&", "(", ")", "{", "}", "\n", "`":
                segments.append(current); current = ""
            default:
                current.append(ch)
            }
        }
        segments.append(current)
        return segments
    }

    /// First meaningful command in a shell snippet, with up to two plain subcommand words
    /// e.g. "until out=$(gh pr checks 404 …); do sleep 30; done" -> "gh pr checks"
    static func label(forScript script: String) -> String? {
        for segment in simpleCommands(in: script) {
            var tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)[...]
            // Strip keywords, assignments and wrappers in front of the command
            while let first = tokens.first,
                  keywords.contains(first) || prefixes.contains(first) || first.hasPrefix("-") ||
                  first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil {
                tokens = tokens.dropFirst()
            }
            guard let command = tokens.first, !skipKeywords.contains(command) else { continue }
            // Accept quoted / variable paths like "$TMPDIR/deploy.sh" as long as the name itself is plain
            let unquoted = command.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let name = (unquoted as NSString).lastPathComponent
            guard name.range(of: #"^[A-Za-z0-9_.+-]+$"#, options: .regularExpression) != nil,
                  !uninformative.contains(name), Double(name) == nil else { continue }

            // Add subcommand words like "pr checks" / "run dev"
            var parts = [name]
            for word in tokens.dropFirst() {
                guard parts.count < 3,
                      word.range(of: #"^[a-z][a-z0-9-]*$"#, options: .regularExpression) != nil else { break }
                parts.append(word)
            }
            return parts.joined(separator: " ")
        }
        return nil
    }
}

/// A shell command Claude Code's Bash tool is running in a window
struct ClaudeShellCommand: Equatable {
    struct Shell: Equatable {
        let label: String     // e.g. "gh pr checks", "deploy-gke.sh › kubectl"
        let started: Date     // when Claude launched the shell
        let script: String?   // the command Claude ran
    }

    let shells: [Shell]       // oldest first, never empty

    var label: String { shells[0].label }
    var started: Date { shells[0].started }
    var otherCount: Int { shells.count - 1 }
}

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
    private var claudeShellCache: [pid_t: (isClaudeShell: Bool, started: Date?, script: String?)] = [:]  // child of claude -> classification

    private init() {}

    func start() {
        guard refreshTimer == nil else { return }

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
        claudeShellCache = claudeShellCache.filter { cachedProcessTree[$0.key] != nil }

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
            if windows[i].hasClaudeProcess {
                windows[i].claudeShellCommand = claudeShellCommand(ghosttyPid: pid)
            }

            // Apply hook state - always try to get fresh shell CWD for accurate matching
            // The shell CWD is the most reliable source for hook state matching
            var cwdToCheck: String? = getShellCwd(ghosttyPid: pid)
            if let cwd = cwdToCheck {
                windows[i].shellCwd = cwd
            }

            // Fallback: try workstream directory if shell CWD lookup failed
            if cwdToCheck == nil, let wsName = windows[i].workstreamName {
                cwdToCheck = themeManager?.directoryForWorkstream(wsName)
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

    /// How long a hook-written state (e.g. "asking") stays valid before we stop trusting it.
    /// Guards against a stuck state when the hook that's supposed to clear it (Stop) never
    /// fires for a given session/profile - falls back to title/process detection instead.
    private let hookStateStaleness: TimeInterval = 120

    private func getHookState(forCwd cwd: String) -> String? {
        let now = Date().timeIntervalSince1970

        // Direct match
        if let cached = hookStateCache[cwd], now - cached.timestamp <= hookStateStaleness {
            return cached.state
        }

        // Try matching by subdirectory (hook might be running in a subdirectory)
        for (cachedCwd, cached) in hookStateCache {
            guard now - cached.timestamp <= hookStateStaleness else { continue }
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

    /// Find shells Claude Code's Bash tool is running under this window. They're recognisable by
    /// Claude's shell-snapshot wrapper (`zsh -c source …/shell-snapshots/snapshot-….sh`), which
    /// separates them from Claude's other children such as MCP servers.
    private func claudeShellCommand(ghosttyPid: pid_t) -> ClaudeShellCommand? {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, info) in cachedProcessTree {
            children[info.ppid, default: []].append(pid)
        }

        var shells: [ClaudeShellCommand.Shell] = []
        for claudePid in cachedClaudePids where traceToGhostty(from: claudePid) == ghosttyPid {
            for child in children[claudePid] ?? [] {
                let entry = claudeShellCache[child] ?? {
                    let wrapper = processArguments(pid: child)?.first { $0.contains("shell-snapshots/snapshot-") }
                    let classified = (
                        isClaudeShell: wrapper != nil,
                        started: wrapper != nil ? processStartDate(pid: child) : nil,
                        script: wrapper.flatMap(ShellCommandNamer.evalBody)
                    )
                    claudeShellCache[child] = classified
                    return classified
                }()
                guard entry.isClaudeShell else { continue }
                let leaf = deepestDescendant(of: child, children: children)
                shells.append(ClaudeShellCommand.Shell(
                    label: ShellCommandNamer.displayLabel(script: entry.script, leaf: leaf),
                    started: entry.started ?? Date(),
                    script: entry.script
                ))
            }
        }

        guard !shells.isEmpty else { return nil }
        return ClaudeShellCommand(shells: shells.sorted { $0.started < $1.started })
    }

    /// Name of the deepest process under `pid` (the command actually doing the work)
    private func deepestDescendant(of pid: pid_t, children: [pid_t: [pid_t]]) -> String {
        var best = (depth: 0, pid: pid)
        var stack = [(pid, 0)]
        while let (current, depth) = stack.popLast() {
            if depth > best.depth { best = (depth, current) }
            for child in children[current] ?? [] where depth < 15 {
                stack.append((child, depth + 1))
            }
        }
        let comm = cachedProcessTree[best.pid]?.comm ?? "shell"
        return (comm as NSString).lastPathComponent
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
