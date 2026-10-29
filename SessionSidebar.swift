import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Session Sidebar Panel

/// Light/dark override for the sidebar, independent of the system appearance
enum SidebarAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "sessionSidebarAppearance"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    static var current: SidebarAppearance {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(SidebarAppearance.init) ?? .system
    }
}

/// Always-visible panel docked to the left screen edge listing Ghostty sessions by status.
/// Spike: reads from WindowTracker.shared (already refreshing every second) — no extra polling.
class SessionSidebarPanel: ObservableObject {
    static let shared = SessionSidebarPanel()

    @Published private(set) var isVisible = false
    /// "pid-axIndex" of the most recently focused Ghostty window (kept while another app is frontmost)
    @Published private(set) var activeWindowKey: String?
    @Published private(set) var ghosttyIsFrontmost = false

    /// UserDefaults key: preview what Claude is asking (Needs You), saying while it works (Running),
    /// or a recap once it's done (Ready)
    static let showsPromptKey = "sessionSidebarShowsPrompt"

    /// Opens the Settings window; set by the menu bar content, which has the SwiftUI openWindow action
    var openSettings: (() -> Void)?

    private var panel: NSPanel?
    private let width: CGFloat = 280
    private let visibleKey = "sessionSidebarVisible"
    private var didRestore = false

    private init() {
        // Float only while Ghostty (or this app) is frontmost; otherwise let other apps cover the sidebar
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.updateLevel(frontmost: app)
            self?.refreshActiveWindow()
        }
    }

    /// Work out which Ghostty window has focus by comparing AX elements, not titles
    /// (Claude's spinner changes the title every frame)
    func refreshActiveWindow() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.mitchellh.ghostty" else {
            ghosttyIsFrontmost = false
            return
        }
        ghosttyIsFrontmost = true

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let focused = focusedRef,
              let windows = windowsRef as? [AXUIElement],
              let index = windows.firstIndex(where: { CFEqual($0, focused) }) else {
            return
        }
        let key = "\(app.processIdentifier)-\(index + 1)"
        if key != activeWindowKey {
            activeWindowKey = key
        }
    }

    private func updateLevel(frontmost app: NSRunningApplication?) {
        guard let panel = panel, isVisible else { return }
        let ownsFocus = app?.bundleIdentifier == "com.mitchellh.ghostty" ||
            app?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        if ownsFocus {
            panel.level = .floating
            panel.orderFrontRegardless()
        } else {
            // Normal level: the newly active app's windows come forward over the sidebar
            panel.level = .normal
        }
    }

    func toggle(themeManager: ThemeManager) {
        if isVisible {
            hide()
        } else {
            show(themeManager: themeManager)
        }
    }

    /// Reopen the sidebar on launch if it was open when the app last quit
    func restoreIfNeeded(themeManager: ThemeManager) {
        guard !didRestore else { return }
        didRestore = true
        if UserDefaults.standard.bool(forKey: visibleKey) {
            show(themeManager: themeManager)
        }
    }

    func show(themeManager: ThemeManager) {
        if panel == nil {
            panel = makePanel(themeManager: themeManager)
        }
        dock()
        // orderFront (not makeKey) so showing the sidebar doesn't steal focus from Ghostty
        panel?.orderFrontRegardless()
        isVisible = true
        UserDefaults.standard.set(true, forKey: visibleKey)
        updateLevel(frontmost: NSWorkspace.shared.frontmostApplication)

        // Docking needs Accessibility; prompt for this exact binary if it isn't trusted
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        UserDefaults.standard.set(false, forKey: visibleKey)
    }

    /// Re-read the saved appearance; nil follows the system
    func applyAppearance() {
        panel?.appearance = SidebarAppearance.current.nsAppearance
    }

    private func makePanel(themeManager: ThemeManager) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.appearance = SidebarAppearance.current.nsAppearance

        let view = SessionSidebarView(tracker: WindowTracker.shared, themeManager: themeManager) { [weak self] in
            self?.hide()
        }
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    /// Pin to the left edge of the main screen, full visible height
    private func dock() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.minX, y: visible.minY, width: width, height: visible.height), display: true)
    }

    /// Focus a session and tile its window into the space right of the sidebar. A window on another
    /// display is only focused, left where it is.
    func focusAndDock(_ window: GhosttyWindow) {
        // Resolve the AX element before focusing: raising a window reorders the per-process AX list
        let element = WindowTracker.shared.axWindow(axIndex: window.axIndex, pid: window.pid)
        WindowTracker.shared.focusWindow(axIndex: window.axIndex, pid: window.pid)

        guard let element = element,
              let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }
        if let frame = WindowTracker.shared.frame(of: element),
           let windowScreen = Self.screen(containingMostOf: frame),
           windowScreen != screen {
            return
        }
        let visible = screen.visibleFrame
        let target = NSRect(
            x: panel.frame.maxX,
            y: visible.minY,
            width: visible.maxX - panel.frame.maxX,
            height: visible.height
        )
        WindowTracker.shared.setFrame(target, of: element)
    }

    /// The display holding the largest part of `frame` (Cocoa coordinates)
    private static func screen(containingMostOf frame: NSRect) -> NSScreen? {
        NSScreen.screens
            .map { ($0, $0.frame.intersection(frame)) }
            .filter { !$0.1.isNull }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?
            .0
    }
}

extension WindowTracker {
    func axWindow(axIndex: Int, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement],
              axIndex > 0 && axIndex <= windows.count else {
            return nil
        }
        return windows[axIndex - 1]
    }

    /// A window's frame via Accessibility, in Cocoa screen coordinates
    func frame(of windowElement: AXUIElement) -> NSRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef = positionRef, let sizeRef = sizeRef else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        // AX uses a top-left origin relative to the primary screen; Cocoa uses bottom-left
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: origin.x, y: primaryHeight - origin.y - size.height, width: size.width, height: size.height)
    }

    /// Move/resize a window via Accessibility. `frame` is in Cocoa screen coordinates.
    func setFrame(_ frame: NSRect, of windowElement: AXUIElement) {
        // AX uses a top-left origin relative to the primary screen; Cocoa uses bottom-left
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        var size = CGSize(width: frame.width, height: frame.height)

        // Position first so the resize isn't clamped by the old location, then size, then position again
        // in case the window refused part of the size change (e.g. cell-size snapping)
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, position)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue)
        }
        if let position = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, position)
        }
    }
}

// MARK: - Session Sidebar View

/// Sidebar grouping: status matters more than the exact Claude state
private enum SessionGroup: Int, CaseIterable {
    case needsYou, ready, running, terminals

    var title: String {
        switch self {
        case .needsYou: return "NEEDS YOU"
        case .ready: return "READY"
        case .running: return "RUNNING"
        case .terminals: return "TERMINALS"
        }
    }

    /// Needs You is only for something blocking Claude (a question or permission prompt);
    /// a finished session waiting for the next prompt is Ready, so real questions don't get buried
    static func of(_ state: ClaudeState) -> SessionGroup {
        switch state {
        case .asking: return .needsYou
        case .waiting: return .ready
        case .working, .running: return .running
        case .notRunning: return .terminals
        }
    }
}

struct SessionSidebarView: View {
    @ObservedObject var tracker: WindowTracker
    @ObservedObject var themeManager: ThemeManager
    @ObservedObject private var sidebar = SessionSidebarPanel.shared
    var onClose: () -> Void

    @State private var filter = ""
    // When each session entered its current state, keyed by pid + window index
    @State private var stateSince: [String: (state: ClaudeState, since: Date)] = [:]
    @State private var missingPermissions: [SidebarPermission] = []
    @AppStorage(SessionSidebarPanel.showsPromptKey) private var showsPrompt = true
    @AppStorage(SidebarAppearance.defaultsKey) private var appearance = SidebarAppearance.system.rawValue

    // Permissions can be granted/revoked in System Settings at any time, so re-check periodically
    private let permissionTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var sessions: [GhosttyWindow] {
        let all = tracker.ghosttyWindows
        guard !filter.isEmpty else { return all }
        return all.filter {
            $0.displayName.localizedCaseInsensitiveContains(filter) ||
            ($0.shellCwd?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            TextField("Filter…", text: $filter)
                .textFieldStyle(.roundedBorder)
                .overlay(alignment: .trailing) {
                    if !filter.isEmpty {
                        Button {
                            filter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 5)
                        .help("Clear filter")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SessionGroup.allCases, id: \.self) { group in
                        let items = sessions
                            .filter { SessionGroup.of($0.claudeState) == group }
                            .sorted(by: sessionOrder)
                        if !items.isEmpty {
                            // Count on the right, in line with the status badges; Needs You in orange
                            HStack {
                                Text(group.title)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(items.count)")
                                    .monospacedDigit()
                                    .foregroundColor(group == .needsYou ? .orange : .secondary)
                            }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.top, 10)

                            ForEach(items, id: \.id) { window in
                                SessionRow(
                                    window: window,
                                    themeColors: themeColors(for: window),
                                    since: stateSince[key(for: window)]?.since,
                                    highlight: highlight(for: window),
                                    showsPrompt: showsPrompt
                                ) {
                                    SessionSidebarPanel.shared.focusAndDock(window)
                                }
                            }
                        }
                    }

                    if sessions.isEmpty {
                        Text(filter.isEmpty ? "No Ghostty windows" : "No matches")
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(.bottom, 12)
            }

            if !missingPermissions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(missingPermissions, id: \.self) { permission in
                        PermissionWarningRow(permission: permission)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .onReceive(tracker.$ghosttyWindows) {
            updateStateTimes($0)
            sidebar.refreshActiveWindow()
        }
        .onAppear { missingPermissions = SidebarPermission.missing() }
        .onReceive(permissionTimer) { _ in missingPermissions = SidebarPermission.missing() }
    }

    private var header: some View {
        HStack {
            Text("SESSIONS")
                .font(.headline)
            Spacer()
            optionsMenu
            Button(action: onClose) {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help("Hide sidebar")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// Sidebar options, mirrored in Settings → General (both read the same UserDefaults keys)
    private var optionsMenu: some View {
        Menu {
            Toggle("Show Session Previews", isOn: $showsPrompt)
            Picker("Appearance", selection: $appearance) {
                ForEach(SidebarAppearance.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Sidebar Settings…") {
                sidebar.openSettings?()
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sidebar options")
        .onChange(of: appearance) { _ in
            sidebar.applyAppearance()
        }
    }

    private func key(for window: GhosttyWindow) -> String {
        "\(window.pid)-\(window.axIndex)"
    }

    /// Higher-priority state first (asking > waiting, working > running); within a state,
    /// the session that has been in it longest first; name breaks ties so rows don't jump
    private func sessionOrder(_ a: GhosttyWindow, _ b: GhosttyWindow) -> Bool {
        if a.claudeState != b.claudeState {
            return a.claudeState > b.claudeState
        }
        let sinceA = stateSince[key(for: a)]?.since ?? .distantFuture
        let sinceB = stateSince[key(for: b)]?.since ?? .distantFuture
        if sinceA != sinceB {
            return sinceA < sinceB
        }
        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    private func highlight(for window: GhosttyWindow) -> SessionRow.Highlight {
        guard key(for: window) == sidebar.activeWindowKey else { return .none }
        return sidebar.ghosttyIsFrontmost ? .focused : .lastFocused
    }

    private func themeColors(for window: GhosttyWindow) -> ThemeColors? {
        guard let theme = themeManager.themeForPID(window.pid) else { return nil }
        return themeManager.getThemeColors(theme)
    }

    private func updateStateTimes(_ windows: [GhosttyWindow]) {
        var next: [String: (state: ClaudeState, since: Date)] = [:]
        for window in windows {
            let k = key(for: window)
            if let prev = stateSince[k], prev.state == window.claudeState {
                next[k] = prev
            } else {
                next[k] = (window.claudeState, Date())
            }
        }
        stateSince = next
    }
}

// MARK: - Permission Warning

enum SidebarPermission: CaseIterable {
    case screenRecording, accessibility

    static func missing() -> [SidebarPermission] {
        allCases.filter { !$0.isGranted }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility: return AXIsProcessTrusted()
        }
    }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording needed"
        case .accessibility: return "Accessibility needed"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: return "to list Ghostty windows"
        case .accessibility: return "to focus and dock windows"
        }
    }

    var settingsURL: URL {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

private struct PermissionWarningRow: View {
    let permission: SidebarPermission

    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(permission.settingsURL)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(permission.title)
                        .font(.caption.weight(.semibold))
                    Text(permission.detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.orange.opacity(0.15) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .help("Open System Settings → Privacy & Security")
        .onHover { hovering = $0 }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let window: GhosttyWindow
    let themeColors: ThemeColors?  // nil = theme unknown
    let since: Date?
    let highlight: Highlight
    let showsPrompt: Bool
    let onFocus: () -> Void

    enum Highlight {
        case none
        case focused      // this window has focus and Ghostty is frontmost
        case lastFocused  // last focused Ghostty window while another app is frontmost
    }

    @State private var hovering = false
    @State private var hoveringShell = false
    @State private var hoveringPrompt = false
    @State private var promptWidth: CGFloat = 220

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: 8) {
                // Mini terminal: theme background outlined in the theme's text color
                RoundedRectangle(cornerRadius: 2)
                    .fill(themeColors?.background ?? Color.gray.opacity(0.4))
                    .frame(width: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(themeColors?.foreground ?? Color.gray.opacity(0.3), lineWidth: 1.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(window.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        statusBadge
                    }
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if showsPrompt, let prompt = previewPrompt {
                        promptPreview(prompt)
                    }
                    if showsPrompt, let activity = runningActivity {
                        activityPreview(activity)
                    }
                    if let shell = window.claudeShellCommand {
                        shellLine(shell)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(highlight == .focused ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering = $0 }
    }

    private var backgroundColor: Color {
        switch highlight {
        case .focused: return Color.accentColor.opacity(0.25)
        case .lastFocused: return Color.accentColor.opacity(0.12)
        case .none: return hovering ? Color.primary.opacity(0.08) : Color.clear
        }
    }

    /// What Claude is asking, only while the session is actually asking
    private var askingPrompt: HookPrompt? {
        guard window.claudeState == .asking, let prompt = window.hookPrompt,
              prompt.kind == .question || prompt.kind == .permission else { return nil }
        return prompt
    }

    /// Claude's latest message and tool call while it works
    private var runningActivity: ClaudeActivity? {
        guard window.claudeState == .working || window.claudeState == .running,
              let activity = window.activity,
              activity.message != nil || activity.action != nil else { return nil }
        return activity
    }

    /// The question while asking, or the recap of Claude's reply while Ready
    private var previewPrompt: HookPrompt? {
        if let prompt = askingPrompt { return prompt }
        guard window.claudeState == .waiting, let prompt = window.hookPrompt,
              prompt.kind == .recap || prompt.kind == .summary else { return nil }
        return prompt
    }

    private var statusBadge: some View {
        let state = window.claudeState
        // A permission prompt gets its own label: it's a quick yes/no, not a question to think about
        let isPermission = askingPrompt?.kind == .permission
        return HStack(spacing: 3) {
            Image(systemName: isPermission ? "lock.circle" : state.icon)
            Text(isPermission ? "Allow?" : state == .notRunning ? "Shell" : state.label)
        }
        .font(.caption.weight(.semibold))
        .foregroundColor(statusColor(state))
    }

    private func statusColor(_ state: ClaudeState) -> Color {
        switch state {
        case .asking: return .orange
        case .waiting: return .yellow
        case .working: return .blue
        case .running: return .teal
        case .notRunning: return .secondary
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let cwd = window.shellCwd {
            parts.append((cwd as NSString).abbreviatingWithTildeInPath)
        }
        if let since = since {
            parts.append(Self.elapsed(since: since))
        }
        return parts.joined(separator: " · ")
    }

    /// Command Claude's Bash tool is still running, e.g. "▶ kubectl · 9m".
    /// Hovering expands it in place to list every shell (a .help tooltip won't show,
    /// because the non-activating panel's app is almost never active).
    private func shellLine(_ shell: ClaudeShellCommand) -> some View {
        var text = "\(shell.label) · \(Self.elapsed(since: shell.started))"
        if shell.otherCount > 0 {
            text += " +\(shell.otherCount)"
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8))
                Text(text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption.monospaced())
            .foregroundColor(.green)

            if hoveringShell {
                shellDetail(shell)
            }
        }
        // Hover covers the line and the detail, so moving into the detail keeps it open
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hoveringShell = hovering }
        }
    }

    /// The question, permission request or recap, 2 lines (options on one line) until hovered,
    /// then expanded in place like the shell line
    private func promptPreview(_ prompt: HookPrompt) -> some View {
        // A recap keeps its line breaks and shows its end (the outcome / next step); SwiftUI's
        // head truncation only works on one line, so pick the tail that fits ourselves.
        // Questions and permission requests read from the start.
        let isRecap = prompt.kind == .recap || prompt.kind == .summary
        let lines = hoveringPrompt ? 10 : 2
        let text = isRecap
            ? Self.tail(of: prompt.text, fittingLines: lines, width: promptWidth)
            : String(Self.oneLine(prompt.text).prefix(500))
        return VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(prompt.kind == .permission ? .caption.monospaced() : .caption)
                .foregroundColor(isRecap ? .secondary : .primary)
                .lineLimit(lines)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { geo in
                    Color.clear
                        .onAppear { promptWidth = geo.size.width }
                        .onChange(of: geo.size.width) { promptWidth = $0 }
                })

            if !prompt.options.isEmpty {
                if hoveringPrompt {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { _, option in
                        Text("○ \(option)")
                    }
                    .font(.caption)
                } else {
                    let shown = prompt.options.prefix(2).map { "○ \($0)" }.joined(separator: "  ")
                    let extra = prompt.options.count - 2
                    Text(extra > 0 ? "\(shown)  +\(extra)" : shown)
                        .font(.caption)
                        .lineLimit(1)
                }
            }

            if prompt.moreQuestions > 0 {
                Text("+\(prompt.moreQuestions) more question\(prompt.moreQuestions == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(statusColor(isRecap ? .waiting : .asking).opacity(0.12))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hoveringPrompt = hovering }
        }
    }

    /// Claude's latest message (its last two lines, more on hover) and, under it, the tool it's
    /// running. A Bash call is left out when the shell line below already shows it.
    private func activityPreview(_ activity: ClaudeActivity) -> some View {
        let lines = hoveringPrompt ? 10 : 2
        let showsAction = activity.action.map { !($0.hasPrefix("Bash") && window.claudeShellCommand != nil) } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            if let message = activity.message {
                Text(Self.tail(of: message, fittingLines: lines, width: promptWidth))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(lines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(GeometryReader { geo in
                        Color.clear
                            .onAppear { promptWidth = geo.size.width }
                            .onChange(of: geo.size.width) { promptWidth = $0 }
                    })
            }
            if showsAction, let action = activity.action {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                    Text(action)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption.monospaced())
                .foregroundColor(statusColor(.working))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(statusColor(.working).opacity(0.10))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { hoveringPrompt = hovering }
        }
    }

    /// Every running shell: label, age, and (shortened) command Claude ran
    private func shellDetail(_ shell: ClaudeShellCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(shell.shells.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 1) {
                    Text("▶ \(item.label) · \(Self.elapsed(since: item.started))")
                        .font(.caption.monospaced().weight(.semibold))
                        .foregroundColor(.green)
                    if let script = item.script {
                        Text(Self.oneLine(script))
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.06))
        )
        .transition(.opacity)
    }

    /// The longest ending of `text`, starting at a word, that fits in `lines` lines of caption text
    static func tail(of text: String, fittingLines lines: Int, width: CGFloat) -> String {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let maxHeight = ceil(NSLayoutManager().defaultLineHeight(for: font) * CGFloat(lines)) + 1
        func fits(_ candidate: String) -> Bool {
            let rect = (candidate as NSString).boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return rect.height <= maxHeight
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if fits(trimmed) { return trimmed }

        // Binary search over word starts for the earliest one whose tail still fits
        let starts = trimmed.indices.filter { i in
            i != trimmed.startIndex && trimmed[trimmed.index(before: i)].isWhitespace && !trimmed[i].isWhitespace
        }
        var low = 0, high = starts.count - 1, best: String?
        while low <= high {
            let mid = (low + high) / 2
            let candidate = "…" + trimmed[starts[mid]...]
            if fits(candidate) {
                best = candidate
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return best ?? "…" + trimmed.suffix(40)
    }

    private static func oneLine(_ script: String) -> String {
        script
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}
