import Foundation

class ThemeManager: ObservableObject {
    @Published var themes: [String] = []
    @Published var recentThemes: [String] = []
    @Published var lastSelectedTheme: String?

    private let maxRecentThemes = 5
    private let recentThemesKey = "RecentThemes"

    init() {
        loadRecentThemes()
        fetchThemes()
    }

    // MARK: - Theme Fetching

    func fetchThemes() {
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        process.arguments = ["+list-themes"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                parseThemes(from: output)
            }
        } catch {
            print("Failed to fetch themes: \(error)")
        }
    }

    private func parseThemes(from output: String) {
        // Theme format: "Theme Name (source)" or just "Theme Name"
        let lines = output.components(separatedBy: .newlines)
        var parsedThemes: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Remove the source indicator in parentheses if present
            var themeName = trimmed
            if let parenRange = trimmed.range(of: " (", options: .backwards) {
                themeName = String(trimmed[..<parenRange.lowerBound])
            }

            parsedThemes.append(themeName)
        }

        DispatchQueue.main.async {
            self.themes = parsedThemes
        }
    }

    // MARK: - Theme Selection

    func pickRandomTheme() -> String? {
        guard !themes.isEmpty else { return nil }
        let theme = themes.randomElement()!
        addToRecentThemes(theme)
        lastSelectedTheme = theme
        return theme
    }

    // MARK: - Launch Ghostty

    func launchGhostty(withTheme theme: String) {
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        process.arguments = ["--theme=\(theme)"]

        do {
            try process.run()
            addToRecentThemes(theme)
            lastSelectedTheme = theme
        } catch {
            print("Failed to launch Ghostty: \(error)")
        }
    }

    // MARK: - Recent Themes

    private func addToRecentThemes(_ theme: String) {
        DispatchQueue.main.async {
            // Remove if already exists to move it to front
            self.recentThemes.removeAll { $0 == theme }

            // Add to front
            self.recentThemes.insert(theme, at: 0)

            // Keep only the most recent themes
            if self.recentThemes.count > self.maxRecentThemes {
                self.recentThemes = Array(self.recentThemes.prefix(self.maxRecentThemes))
            }

            self.saveRecentThemes()
        }
    }

    private func loadRecentThemes() {
        if let saved = UserDefaults.standard.stringArray(forKey: recentThemesKey) {
            recentThemes = saved
        }
    }

    private func saveRecentThemes() {
        UserDefaults.standard.set(recentThemes, forKey: recentThemesKey)
    }
}
