import SwiftUI
import AppKit
import ApplicationServices

// MARK: - Session Sidebar Panel

/// Always-visible panel docked to the left screen edge listing Ghostty sessions by status.
/// Spike: reads from WindowTracker.shared (already refreshing every second) — no extra polling.
class SessionSidebarPanel: ObservableObject {
    static let shared = SessionSidebarPanel()

    @Published private(set) var isVisible = false
    /// "pid-axIndex" of the most recently focused Ghostty window (kept while another app is frontmost)
    @Published private(set) var activeWindowKey: String?
    @Published private(set) var ghosttyIsFrontmost = false

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
        if !AXIsProcessTrustedWithOptions(options) {
            debugLog("Sidebar: Accessibility not trusted, prompted user")
        }
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
        UserDefaults.standard.set(false, forKey: visibleKey)
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

    /// Focus a session and tile its window into the space right of the sidebar
    func focusAndDock(_ window: GhosttyWindow) {
        // Resolve the AX element before focusing: raising a window reorders the per-process AX list
        let element = WindowTracker.shared.axWindow(axIndex: window.axIndex, pid: window.pid)
        WindowTracker.shared.focusWindow(axIndex: window.axIndex, pid: window.pid)

        guard let element = element else {
            debugLog("Sidebar dock: no AX window for pid \(window.pid) index \(window.axIndex)")
            return
        }
        guard let panel = panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let target = NSRect(
            x: panel.frame.maxX,
            y: visible.minY,
            width: visible.maxX - panel.frame.maxX,
            height: visible.height
        )
        WindowTracker.shared.setFrame(target, of: element)
    }
}

extension WindowTracker {
    func axWindow(axIndex: Int, pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard error == .success,
              let windows = windowsRef as? [AXUIElement],
              axIndex > 0 && axIndex <= windows.count else {
            let count = (windowsRef as? [AXUIElement])?.count ?? -1
            debugLog("Sidebar dock: AX lookup failed pid=\(pid) index=\(axIndex) error=\(error.rawValue) axWindows=\(count) trusted=\(AXIsProcessTrusted())")
            return nil
        }
        return windows[axIndex - 1]
    }

    /// Move/resize a window via Accessibility. `frame` is in Cocoa screen coordinates.
    func setFrame(_ frame: NSRect, of windowElement: AXUIElement) {
        // AX uses a top-left origin relative to the primary screen; Cocoa uses bottom-left
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = CGPoint(x: frame.minX, y: primaryHeight - frame.maxY)
        var size = CGSize(width: frame.width, height: frame.height)

        // Position first so the resize isn't clamped by the old location, then size, then position again
        // in case the window refused part of the size change (e.g. cell-size snapping)
        var results: [AXError] = []
        if let position = AXValueCreate(.cgPoint, &origin) {
            results.append(AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, position))
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            results.append(AXUIElementSetAttributeValue(windowElement, kAXSizeAttribute as CFString, sizeValue))
        }
        if let position = AXValueCreate(.cgPoint, &origin) {
            results.append(AXUIElementSetAttributeValue(windowElement, kAXPositionAttribute as CFString, position))
        }
        debugLog("Sidebar dock: target origin=\(origin) size=\(size) results=\(results.map { $0.rawValue }) now=\(currentFrame(of: windowElement))")
    }

    private func currentFrame(of element: AXUIElement) -> String {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let posRef = posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
        if let sizeRef = sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }
        return "origin=\(pos) size=\(size)"
    }
}

// MARK: - Session Sidebar View

/// Sidebar grouping: status matters more than the exact Claude state
private enum SessionGroup: Int, CaseIterable {
    case needsYou, running, idle

    var title: String {
        switch self {
        case .needsYou: return "NEEDS YOU"
        case .running: return "RUNNING"
        case .idle: return "IDLE"
        }
    }

    static func of(_ state: ClaudeState) -> SessionGroup {
        switch state {
        case .asking, .waiting: return .needsYou
        case .working, .running: return .running
        case .notRunning: return .idle
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
                            Text(group.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)

                            ForEach(items, id: \.id) { window in
                                SessionRow(
                                    window: window,
                                    themeColors: themeColors(for: window),
                                    since: stateSince[key(for: window)]?.since,
                                    highlight: highlight(for: window)
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
    let onFocus: () -> Void

    enum Highlight {
        case none
        case focused      // this window has focus and Ghostty is frontmost
        case lastFocused  // last focused Ghostty window while another app is frontmost
    }

    @State private var hovering = false

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

    private var statusBadge: some View {
        let state = window.claudeState
        return HStack(spacing: 3) {
            Image(systemName: state.icon)
            Text(state == .notRunning ? "Idle" : state.label)
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

    private static func elapsed(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }
}
