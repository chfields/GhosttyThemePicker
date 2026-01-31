import Foundation

// MARK: - Models

struct Workstream: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var theme: String
    var directory: String?
    var windowTitle: String?
    var command: String?
    var extraArgs: String?  // Additional Ghostty args like --font-size=14

    static func == (lhs: Workstream, rhs: Workstream) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ThemeManager

class ThemeManager: ObservableObject {
    @Published var themes: [String] = []
    @Published var recentThemes: [String] = []
    @Published var favoriteThemes: [String] = []
    @Published var workstreams: [Workstream] = []
    @Published var lastSelectedTheme: String?

    private let maxRecentThemes = 5
    private let recentThemesKey = "RecentThemes"
    private let favoriteThemesKey = "FavoriteThemes"
    private let workstreamsKey = "Workstreams"

    init() {
        loadRecentThemes()
        loadFavoriteThemes()
        loadWorkstreams()
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
        let lines = output.components(separatedBy: .newlines)
        var parsedThemes: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

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

        // Exclude recent themes to ensure distinct selections
        let recentSet = Set(recentThemes)
        let availableThemes = themes.filter { !recentSet.contains($0) }

        // If all themes have been used recently, fall back to full list
        let theme = (availableThemes.isEmpty ? themes : availableThemes).randomElement()!

        addToRecentThemes(theme)
        lastSelectedTheme = theme
        return theme
    }

    // MARK: - Launch Ghostty

    func launchGhostty(withTheme theme: String, inDirectory directory: String? = nil) {
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")

        var args = ["--theme=\(theme)"]
        if let dir = directory, !dir.isEmpty {
            args.append("--working-directory=\(dir)")
        }
        process.arguments = args

        do {
            try process.run()
            addToRecentThemes(theme)
            lastSelectedTheme = theme
        } catch {
            print("Failed to launch Ghostty: \(error)")
        }
    }

    func launchWorkstream(_ workstream: Workstream) {
        var args = ["--theme=\(workstream.theme)"]

        if let dir = workstream.directory, !dir.isEmpty {
            args.append("--working-directory=\(dir)")
        }

        if let title = workstream.windowTitle, !title.isEmpty {
            args.append("--title=\(title)")
        }

        if let cmd = workstream.command, !cmd.isEmpty {
            args.append("-e")
            args.append(cmd)
        }

        if let extra = workstream.extraArgs, !extra.isEmpty {
            // Parse extra args (space-separated)
            let extraParts = extra.components(separatedBy: " ").filter { !$0.isEmpty }
            args.append(contentsOf: extraParts)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Ghostty.app/Contents/MacOS/ghostty")
        process.arguments = args

        do {
            try process.run()
            addToRecentThemes(workstream.theme)
            lastSelectedTheme = workstream.theme
        } catch {
            print("Failed to launch Ghostty: \(error)")
        }
    }

    // MARK: - Recent Themes

    private func addToRecentThemes(_ theme: String) {
        DispatchQueue.main.async {
            self.recentThemes.removeAll { $0 == theme }
            self.recentThemes.insert(theme, at: 0)

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

    // MARK: - Favorite Themes

    func isFavorite(_ theme: String) -> Bool {
        favoriteThemes.contains(theme)
    }

    func toggleFavorite(_ theme: String) {
        if isFavorite(theme) {
            favoriteThemes.removeAll { $0 == theme }
        } else {
            favoriteThemes.append(theme)
        }
        saveFavoriteThemes()
    }

    func addFavorite(_ theme: String) {
        guard !isFavorite(theme) else { return }
        favoriteThemes.append(theme)
        saveFavoriteThemes()
    }

    func removeFavorite(_ theme: String) {
        favoriteThemes.removeAll { $0 == theme }
        saveFavoriteThemes()
    }

    private func loadFavoriteThemes() {
        if let saved = UserDefaults.standard.stringArray(forKey: favoriteThemesKey) {
            favoriteThemes = saved
        }
    }

    private func saveFavoriteThemes() {
        UserDefaults.standard.set(favoriteThemes, forKey: favoriteThemesKey)
    }

    // MARK: - Workstreams

    func addWorkstream(name: String, theme: String, directory: String?, windowTitle: String? = nil, command: String? = nil, extraArgs: String? = nil) {
        let workstream = Workstream(
            name: name,
            theme: theme,
            directory: directory,
            windowTitle: windowTitle,
            command: command,
            extraArgs: extraArgs
        )
        workstreams.append(workstream)
        saveWorkstreams()
    }

    func updateWorkstream(_ workstream: Workstream) {
        if let index = workstreams.firstIndex(where: { $0.id == workstream.id }) {
            workstreams[index] = workstream
            saveWorkstreams()
        }
    }

    func deleteWorkstream(_ workstream: Workstream) {
        workstreams.removeAll { $0.id == workstream.id }
        saveWorkstreams()
    }

    private func loadWorkstreams() {
        if let data = UserDefaults.standard.data(forKey: workstreamsKey),
           let decoded = try? JSONDecoder().decode([Workstream].self, from: data) {
            workstreams = decoded
        }
    }

    private func saveWorkstreams() {
        if let encoded = try? JSONEncoder().encode(workstreams) {
            UserDefaults.standard.set(encoded, forKey: workstreamsKey)
        }
    }
}
