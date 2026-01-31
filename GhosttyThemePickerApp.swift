import SwiftUI

@main
struct GhosttyThemePickerApp: App {
    @StateObject private var themeManager = ThemeManager()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(themeManager: themeManager)
        } label: {
            Label("Ghostty Theme Picker", systemImage: "terminal")
        }
    }
}

struct MenuContent: View {
    @ObservedObject var themeManager: ThemeManager
    @State private var showingThemeNotification = false

    var body: some View {
        VStack {
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

            // Show last selected theme if available
            if let lastTheme = themeManager.lastSelectedTheme {
                Text("Last: \(lastTheme)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Recent Themes Section
            if !themeManager.recentThemes.isEmpty {
                Text("Recent Themes")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(themeManager.recentThemes, id: \.self) { theme in
                    Button(theme) {
                        themeManager.launchGhostty(withTheme: theme)
                    }
                }

                Divider()
            }

            // Theme count info
            Text("\(themeManager.themes.count) themes available")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // Refresh themes
            Button {
                themeManager.fetchThemes()
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh Themes")
                }
            }

            // Quit Button
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
