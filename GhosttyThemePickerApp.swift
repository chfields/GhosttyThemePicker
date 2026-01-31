import SwiftUI

@main
struct GhosttyThemePickerApp: App {
    @StateObject private var themeManager = ThemeManager()
    @State private var showingWorkstreams = false

    var body: some Scene {
        MenuBarExtra {
            MenuContent(themeManager: themeManager, showingWorkstreams: $showingWorkstreams)
        } label: {
            Label("Ghostty Theme Picker", systemImage: "terminal")
        }

        Window("Manage Workstreams", id: "workstreams") {
            SettingsView(themeManager: themeManager)
        }
        .windowResizability(.contentSize)
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
                            Text(theme)
                                .tag(theme)
                        }
                        .frame(height: 100)
                        .border(Color.gray.opacity(0.3))

                        if !selectedTheme.isEmpty {
                            Text("Selected: \(selectedTheme)")
                                .font(.caption)
                                .foregroundColor(.blue)
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
            themeManager.updateWorkstream(updated)
        } else {
            themeManager.addWorkstream(
                name: trimmedName,
                theme: selectedTheme,
                directory: trimmedDir.isEmpty ? nil : trimmedDir,
                windowTitle: trimmedTitle.isEmpty ? nil : trimmedTitle,
                command: trimmedCmd.isEmpty ? nil : trimmedCmd,
                extraArgs: trimmedArgs.isEmpty ? nil : trimmedArgs
            )
        }
        onDismiss()
    }
}
