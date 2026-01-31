import SwiftUI
import Carbon

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
    private var hotkeyRef: EventHotKeyRef?
    private static var instance: HotkeyManager?

    func registerHotkey() {
        HotkeyManager.instance = self

        // Register Control+Option+G using Carbon API
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4754504B) // "GTPK" - GhosttyThemePickerKey
        hotKeyID.id = 1

        // G = keycode 5, Control+Option = controlKey + optionKey
        let modifiers: UInt32 = UInt32(controlKey | optionKey)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            HotkeyManager.instance?.handleHotkey()
            return noErr
        }, 1, &eventType, nil, nil)

        let status = RegisterEventHotKey(5, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotkeyRef)

        if status == noErr {
            print("Global hotkey registered: ⌃⌥G (Carbon)")
        } else {
            print("Failed to register hotkey: \(status)")
        }
    }

    private func handleHotkey() {
        DispatchQueue.main.async {
            QuickLaunchPanel.shared.show(themeManager: self.themeManager)
        }
    }

    deinit {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
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
                }
            }

            Divider()
        }

        // Theme count
        Text("\(themeManager.themes.count) themes available")
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
    @State private var editingWorkstream: Workstream?

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

    var filteredThemes: [String] {
        if themeSearchText.isEmpty {
            return themeManager.themes
        }
        return themeManager.themes.filter { $0.localizedCaseInsensitiveContains(themeSearchText) }
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
                        TextField("Search themes...", text: $themeSearchText)
                            .textFieldStyle(.roundedBorder)

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
