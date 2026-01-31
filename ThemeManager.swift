import Foundation
import SwiftUI

// MARK: - Models

struct ThemeColors {
    let background: Color
    let foreground: Color
    let accent1: Color  // Usually red/pink (palette 1 or 5)
    let accent2: Color  // Usually green/cyan (palette 2 or 6)

    static let placeholder = ThemeColors(
        background: .gray,
        foreground: .white,
        accent1: .red,
        accent2: .green
    )
}

struct Workstream: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var theme: String
    var directory: String?
    var windowTitle: String?
    var command: String?
    var extraArgs: String?  // Additional Ghostty args like --font-size=14
    var autoLaunch: Bool = false  // Launch this workstream when app starts

    static func == (lhs: Workstream, rhs: Workstream) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - ThemeManager

class ThemeManager: ObservableObject {
    @Published var themes: [String] = []
    @Published var recentThemes: [String] = []
    @Published var favoriteThemes: [String] = []
    @Published var excludedThemes: [String] = []
    @Published var workstreams: [Workstream] = []
    @Published var lastSelectedTheme: String?

    private let maxRecentThemes = 5
    private let recentThemesKey = "RecentThemes"
    private let favoriteThemesKey = "FavoriteThemes"
    private let excludedThemesKey = "ExcludedThemes"
    private let workstreamsKey = "Workstreams"

    init() {
        loadRecentThemes()
        loadFavoriteThemes()
        loadExcludedThemes()
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

        // Exclude recent themes and excluded themes
        let recentSet = Set(recentThemes)
        let excludedSet = Set(excludedThemes)
        let availableThemes = themes.filter { !recentSet.contains($0) && !excludedSet.contains($0) }

        // If all themes have been used recently or excluded, fall back to non-excluded only
        let fallbackThemes = themes.filter { !excludedSet.contains($0) }
        let themesToChooseFrom = availableThemes.isEmpty ? fallbackThemes : availableThemes

        guard let theme = themesToChooseFrom.randomElement() else { return nil }

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

    // MARK: - Excluded Themes

    func isExcluded(_ theme: String) -> Bool {
        excludedThemes.contains(theme)
    }

    func toggleExcluded(_ theme: String) {
        if isExcluded(theme) {
            excludedThemes.removeAll { $0 == theme }
        } else {
            excludedThemes.append(theme)
        }
        saveExcludedThemes()
    }

    func excludeTheme(_ theme: String) {
        guard !isExcluded(theme) else { return }
        excludedThemes.append(theme)
        saveExcludedThemes()
    }

    func includeTheme(_ theme: String) {
        excludedThemes.removeAll { $0 == theme }
        saveExcludedThemes()
    }

    func clearExcludedThemes() {
        excludedThemes.removeAll()
        saveExcludedThemes()
    }

    private func loadExcludedThemes() {
        if let saved = UserDefaults.standard.stringArray(forKey: excludedThemesKey) {
            excludedThemes = saved
        }
    }

    private func saveExcludedThemes() {
        UserDefaults.standard.set(excludedThemes, forKey: excludedThemesKey)
    }

    // MARK: - Workstreams

    func addWorkstream(name: String, theme: String, directory: String?, windowTitle: String? = nil, command: String? = nil, autoLaunch: Bool = false, extraArgs: String? = nil) {
        let workstream = Workstream(
            name: name,
            theme: theme,
            directory: directory,
            windowTitle: windowTitle,
            command: command,
            extraArgs: extraArgs,
            autoLaunch: autoLaunch
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

    func launchAutoStartWorkstreams() {
        let autoLaunchWorkstreams = workstreams.filter { $0.autoLaunch }
        for workstream in autoLaunchWorkstreams {
            launchWorkstream(workstream)
        }
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

    func exportWorkstreams(_ selected: [Workstream]? = nil) -> Data? {
        let toExport = selected ?? workstreams
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(toExport)
    }

    func importWorkstreams(from data: Data, replace: Bool = false) -> Int {
        guard let imported = try? JSONDecoder().decode([Workstream].self, from: data) else {
            return 0
        }

        if replace {
            workstreams = imported
        } else {
            // Merge - add imported workstreams with new UUIDs to avoid conflicts
            for var workstream in imported {
                workstream.id = UUID()
                workstreams.append(workstream)
            }
        }

        saveWorkstreams()
        return imported.count
    }

    // MARK: - Theme Colors

    private var themeColorsCache: [String: ThemeColors] = [:]
    private let themesPath = "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"

    func getThemeColors(_ themeName: String) -> ThemeColors {
        if let cached = themeColorsCache[themeName] {
            return cached
        }

        let colors = parseThemeFile(themeName)
        themeColorsCache[themeName] = colors
        return colors
    }

    private func parseThemeFile(_ themeName: String) -> ThemeColors {
        let filePath = "\(themesPath)/\(themeName)"

        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return ThemeColors.placeholder
        }

        var background: Color = .black
        var foreground: Color = .white
        var palette1: Color = .red      // Red
        var palette2: Color = .green    // Green
        var palette5: Color = .pink     // Magenta/Pink
        var palette6: Color = .cyan     // Cyan

        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }

            let key = parts[0]
            let value = parts[1]

            if key == "background" {
                background = colorFromHex(value)
            } else if key == "foreground" {
                foreground = colorFromHex(value)
            } else if key == "palette" {
                // Format: "palette = N=#color" but we split on first =, so value is "N=#color"
                let paletteParts = value.split(separator: "=", maxSplits: 1)
                if paletteParts.count == 2,
                   let index = Int(paletteParts[0].trimmingCharacters(in: .whitespaces)) {
                    let colorHex = String(paletteParts[1]).trimmingCharacters(in: .whitespaces)
                    let color = colorFromHex(colorHex)
                    switch index {
                    case 1: palette1 = color
                    case 2: palette2 = color
                    case 5: palette5 = color
                    case 6: palette6 = color
                    default: break
                    }
                }
            }
        }

        return ThemeColors(
            background: background,
            foreground: foreground,
            accent1: palette5,  // Magenta/Pink - usually vibrant
            accent2: palette6   // Cyan - usually vibrant
        )
    }

    func isDarkTheme(_ themeName: String) -> Bool {
        let colors = getThemeColors(themeName)
        // Convert background color to brightness
        // Using the cached colors, extract RGB and calculate luminance
        let filePath = "\(themesPath)/\(themeName)"
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            return true // Default to dark
        }

        for line in content.components(separatedBy: .newlines) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "background" else { continue }

            var hex = parts[1].trimmingCharacters(in: .whitespaces)
            if hex.hasPrefix("#") { hex.removeFirst() }

            guard hex.count == 6, let rgb = UInt64(hex, radix: 16) else { return true }

            let r = Double((rgb >> 16) & 0xFF) / 255.0
            let g = Double((rgb >> 8) & 0xFF) / 255.0
            let b = Double(rgb & 0xFF) / 255.0

            // Calculate relative luminance
            let luminance = 0.299 * r + 0.587 * g + 0.114 * b
            return luminance < 0.5
        }
        return true
    }

    private func colorFromHex(_ hex: String) -> Color {
        var hexString = hex.trimmingCharacters(in: .whitespaces)
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }

        guard hexString.count == 6,
              let rgb = UInt64(hexString, radix: 16) else {
            return .gray
        }

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        return Color(red: r, green: g, blue: b)
    }
}
