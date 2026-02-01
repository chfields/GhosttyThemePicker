import SwiftUI
import Carbon
import ApplicationServices

@main
struct GhosttyThemePickerApp: App {
    @StateObject private var themeManager = ThemeManager()
    @State private var showingWorkstreams = false
    @State private var hasLaunchedAutoStart = false
    @StateObject private var hotkeyManager = HotkeyManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(themeManager: themeManager, showingWorkstreams: $showingWorkstreams)
                .onAppear {
                    hotkeyManager.themeManager = themeManager
                    hotkeyManager.registerHotkey()

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

        Window("Manage Workstreams", id: "workstreams") {
            SettingsView(themeManager: themeManager)
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

// MARK: - Hotkey Manager (Carbon-based)

class HotkeyManager: ObservableObject {
    var themeManager: ThemeManager?
    private var hotkeyRefG: EventHotKeyRef?
    private var hotkeyRefP: EventHotKeyRef?
    static var instance: HotkeyManager?

    func registerHotkey() {
        HotkeyManager.instance = self

        let modifiers: UInt32 = UInt32(controlKey | optionKey)

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

        // Register Control+Option+G (Quick Launch)
        var hotKeyIDG = EventHotKeyID()
        hotKeyIDG.signature = OSType(0x4754504B) // "GTPK"
        hotKeyIDG.id = 1
        let statusG = RegisterEventHotKey(5, modifiers, hotKeyIDG, GetApplicationEventTarget(), 0, &hotkeyRefG) // G = keycode 5

        // Register Control+Option+P (Window Switcher)
        var hotKeyIDP = EventHotKeyID()
        hotKeyIDP.signature = OSType(0x4754504B) // "GTPK"
        hotKeyIDP.id = 2
        let statusP = RegisterEventHotKey(35, modifiers, hotKeyIDP, GetApplicationEventTarget(), 0, &hotkeyRefP) // P = keycode 35

        if statusG == noErr {
            print("Global hotkey registered: ⌃⌥G (Quick Launch)")
        }
        if statusP == noErr {
            print("Global hotkey registered: ⌃⌥P (Window Switcher)")
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
        if let ref = hotkeyRefG {
            UnregisterEventHotKey(ref)
        }
        if let ref = hotkeyRefP {
            UnregisterEventHotKey(ref)
        }
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

struct GhosttyWindow: Identifiable {
    let id: Int
    let name: String
    let axIndex: Int  // Index for AppleScript (1-based, per-process)
    let pid: pid_t    // Process ID this window belongs to
}

class WindowSwitcherViewModel: ObservableObject {
    @Published var windows: [GhosttyWindow] = []
    @Published var searchText: String = ""
    @Published var selectedIndex: Int = 0
    @Published var hasScreenRecordingPermission: Bool = false

    var filteredWindows: [GhosttyWindow] {
        if searchText.isEmpty {
            return windows
        }
        return windows.filter { window in
            window.name.localizedCaseInsensitiveContains(searchText)
        }
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

    // Find workstream name that matches a window title
    func workstreamName(for windowTitle: String) -> String? {
        guard let manager = themeManager else { return nil }
        return manager.workstreams.first { ws in
            ws.windowTitle == windowTitle
        }?.name
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
                                Button {
                                    viewModel.focusWindow(axIndex: window.axIndex, pid: window.pid)
                                    onDismiss?()
                                } label: {
                                    HStack {
                                        Image(systemName: "terminal")
                                            .foregroundColor(.accentColor)
                                        if let wsName = workstreamName(for: window.name) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(wsName)
                                                    .fontWeight(.medium)
                                                Text(window.name)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                        } else {
                                            Text(window.name)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        index == viewModel.selectedIndex
                                            ? Color.accentColor.opacity(0.2)
                                            : Color(NSColor.controlBackgroundColor).opacity(0.5)
                                    )
                                    .cornerRadius(6)
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
            checkPermissions()
            if viewModel.hasScreenRecordingPermission {
                loadWindows()
            } else {
                // Request permission (will show system dialog)
                CGRequestScreenCaptureAccess()
            }

            // Set up key handler on panel
            panel?.keyHandler = { [weak viewModel, onDismiss] event in
                viewModel?.handleKeyDown(event, onDismiss: onDismiss) ?? false
            }
        }
        .onDisappear {
            panel?.keyHandler = nil
        }
        .onChange(of: viewModel.searchText) { _ in
            viewModel.selectedIndex = 0
        }
        .onExitCommand {
            onDismiss?()
        }
    }

    private func loadWindows() {
        // Try to load windows using Accessibility API first (correct order for AppleScript)
        if loadWindowsViaAccessibilityAPI() {
            return
        }

        // Fall back to CGWindowList API if Accessibility fails
        print("Falling back to CGWindowList API")
        loadWindowsViaCGWindowList()
    }

    private func loadWindowsViaAccessibilityAPI() -> Bool {
        // Get ALL Ghostty processes (not just the first one)
        let runningApps = NSWorkspace.shared.runningApplications
        let ghosttyApps = runningApps.filter { $0.localizedName?.lowercased() == "ghostty" }

        guard !ghosttyApps.isEmpty else {
            print("No Ghostty processes found")
            return false
        }

        print("Found \(ghosttyApps.count) Ghostty process(es)")

        // Debug logging to file
        let logPath = "/tmp/ghostty_picker_debug.log"
        let timestamp = Date()
        try? "[\(timestamp)] Found \(ghosttyApps.count) Ghostty process(es)\n".write(toFile: logPath, atomically: false, encoding: .utf8)

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
                try? "  PID \(pid): FAILED (error: \(result.rawValue))\n".appendToFile(atPath: logPath)
                continue  // Skip this process, try others
            }

            print("Process PID \(pid) returned \(windows.count) window(s)")
            try? "  PID \(pid): \(windows.count) window(s)\n".appendToFile(atPath: logPath)

            // Enumerate windows from this process (1-based index per process)
            for (perProcessIndex, windowElement) in windows.enumerated() {
                // Get window title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(windowElement, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? "Window \(ghosttyWindows.count + 1)"

                // Use a unique ID based on current count, but axIndex is per-process (1-based)
                let id = ghosttyWindows.count + 1
                ghosttyWindows.append(GhosttyWindow(id: id, name: title, axIndex: perProcessIndex + 1, pid: pid))
            }
        }

        print("Extracted \(ghosttyWindows.count) total Ghostty windows from Accessibility API")
        try? "  TOTAL: \(ghosttyWindows.count) windows\n".appendToFile(atPath: logPath)

        // Only return true if we actually found windows
        guard !ghosttyWindows.isEmpty else {
            print("Accessibility API returned empty window list - using CGWindowList fallback")
            return false
        }

        viewModel.windows = ghosttyWindows

        // Reset selection if out of bounds
        if viewModel.selectedIndex >= ghosttyWindows.count {
            viewModel.selectedIndex = 0
        }

        print("Successfully loaded \(ghosttyWindows.count) windows via Accessibility API")
        return true
    }

    private func loadWindowsViaCGWindowList() {
        // Use CGWindowList API to get Ghostty windows (fallback method)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        var ghosttyWindows: [GhosttyWindow] = []
        var perProcessIndices: [pid_t: Int] = [:]  // Track per-process window indices

        for window in windowList {
            guard let ownerName = window["kCGWindowOwnerName"] as? String,
                  ownerName.lowercased() == "ghostty",
                  let ownerPID = window["kCGWindowOwnerPID"] as? Int else {
                continue
            }

            let pid = pid_t(ownerPID)
            let name = window["kCGWindowName"] as? String ?? "Window \(ghosttyWindows.count + 1)"
            let windowNumber = window["kCGWindowNumber"] as? Int ?? ghosttyWindows.count + 1

            // Track per-process window index (1-based)
            let perProcessIndex = (perProcessIndices[pid] ?? 0) + 1
            perProcessIndices[pid] = perProcessIndex

            ghosttyWindows.append(GhosttyWindow(id: windowNumber, name: name, axIndex: perProcessIndex, pid: pid))
        }

        viewModel.windows = ghosttyWindows

        // Reset selection if out of bounds
        if viewModel.selectedIndex >= ghosttyWindows.count {
            viewModel.selectedIndex = 0
        }
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
                    // Random Theme
                    Button {
                        if let theme = themeManager.pickRandomTheme() {
                            themeManager.launchGhostty(withTheme: theme)
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
                                themeManager.launchGhostty(withTheme: theme)
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
                                themeManager.launchGhostty(withTheme: theme)
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
        // Workstreams Section
        if !themeManager.workstreams.isEmpty {
            Text("Workstreams")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(themeManager.workstreams) { workstream in
                Button {
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
                Text("Manage Workstreams...")
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

// MARK: - Settings View

struct SettingsView: View {
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
        .frame(width: 500, height: 350)
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
