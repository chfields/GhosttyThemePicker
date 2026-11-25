import Foundation

/// Manages installation and configuration of Claude Code hooks for "asking" state detection
class HookInstaller {
    static let shared = HookInstaller()

    private let fileManager = FileManager.default

    // Paths
    private var claudeDir: URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    private var hooksDir: URL {
        claudeDir.appendingPathComponent("hooks")
    }

    private var settingsPath: URL {
        claudeDir.appendingPathComponent("settings.json")
    }

    // Hook filenames
    private let stateHookFilename = "claude-state-hook.sh"
    private let permissionHookFilename = "permission-hook.sh"

    // Follow-up skill: the script lives with the hooks; SKILL.md goes into every Claude config dir
    private let followUpScriptFilename = "followup.sh"
    private let followUpSkillBundleName = "followup-SKILL.md"
    private let followUpSkillName = "followup"

    /// Claude config dirs to install the skill into: ~/.claude, plus any ~/.claude-<name> that has a
    /// settings.json (profiles run with CLAUDE_CONFIG_DIR, which a GUI app can't read from the shell)
    private var claudeConfigDirs: [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        let profiles = ((try? fileManager.contentsOfDirectory(atPath: home.path)) ?? [])
            .filter { $0.hasPrefix(".claude-") }
            .map { home.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.appendingPathComponent("settings.json").path) }
        return [claudeDir] + profiles.sorted { $0.path < $1.path }
    }

    private func followUpSkillPath(in configDir: URL) -> URL {
        configDir.appendingPathComponent("skills/\(followUpSkillName)/SKILL.md")
    }

    /// Comment marker to identify our hooks in settings.json
    private let hookMarker = "GhosttyThemePicker"

    /// PreToolUse matcher for the AskUserQuestion tool (treated as "asking", same as a permission prompt)
    private let askQuestionMatcher = "AskUserQuestion"

    // MARK: - Public Methods

    /// Check if hooks are installed and configured
    func areHooksInstalled() -> Bool {
        // Check if both script files exist
        let stateHookExists = fileManager.fileExists(atPath: hooksDir.appendingPathComponent(stateHookFilename).path)
        let permissionHookExists = fileManager.fileExists(atPath: hooksDir.appendingPathComponent(permissionHookFilename).path)

        guard stateHookExists && permissionHookExists else {
            return false
        }

        // Check if hooks are configured in settings.json
        guard let settings = loadSettings() else {
            return false
        }

        return settingsContainHooks(settings)
    }

    /// Installed but older than the files bundled with this app (e.g. hooks that don't record prompts
    /// yet, or no follow-up skill)
    func hooksNeedUpdate() -> Bool {
        guard areHooksInstalled() else { return false }
        var installedCopies: [(bundled: String, installed: URL)] = [stateHookFilename, permissionHookFilename, followUpScriptFilename].map {
            ($0, hooksDir.appendingPathComponent($0))
        }
        installedCopies += claudeConfigDirs.map { (followUpSkillBundleName, followUpSkillPath(in: $0)) }
        return installedCopies.contains { copy in
            guard let bundlePath = bundledPath(copy.bundled) else { return false }
            let installed = try? Data(contentsOf: copy.installed)
            let bundled = try? Data(contentsOf: URL(fileURLWithPath: bundlePath))
            return installed != bundled
        }
    }

    private func bundledPath(_ filename: String) -> String? {
        Bundle.main.path(forResource: filename, ofType: nil, inDirectory: "hooks")
            ?? Bundle.main.path(forResource: filename, ofType: nil)
    }

    /// Install hooks and configure settings.json
    func installHooks() throws {
        // Create directories if needed
        try fileManager.createDirectory(at: hooksDir, withIntermediateDirectories: true)

        // Copy hook scripts from app bundle
        try installHookScript(named: stateHookFilename)
        try installHookScript(named: permissionHookFilename)
        try installHookScript(named: followUpScriptFilename)
        try installFollowUpSkill()

        // Update settings.json
        try configureSettings()

        print("Claude Code hooks installed successfully")
    }

    /// Remove hooks and clean up settings.json
    func uninstallHooks() throws {
        // Remove hook scripts
        let stateHookPath = hooksDir.appendingPathComponent(stateHookFilename)
        let permissionHookPath = hooksDir.appendingPathComponent(permissionHookFilename)

        if fileManager.fileExists(atPath: stateHookPath.path) {
            try fileManager.removeItem(at: stateHookPath)
        }

        if fileManager.fileExists(atPath: permissionHookPath.path) {
            try fileManager.removeItem(at: permissionHookPath)
        }

        let followUpScriptPath = hooksDir.appendingPathComponent(followUpScriptFilename)
        if fileManager.fileExists(atPath: followUpScriptPath.path) {
            try fileManager.removeItem(at: followUpScriptPath)
        }
        for configDir in claudeConfigDirs {
            let skillDir = followUpSkillPath(in: configDir).deletingLastPathComponent()
            if fileManager.fileExists(atPath: skillDir.path) {
                try fileManager.removeItem(at: skillDir)
            }
        }

        // Remove hooks from settings.json
        try removeHooksFromSettings()

        // Clean up state files
        cleanupStateFiles()

        print("Claude Code hooks uninstalled successfully")
    }

    // MARK: - Private Methods

    private func installHookScript(named filename: String) throws {
        // Get script from app bundle
        guard let bundlePath = Bundle.main.path(forResource: filename, ofType: nil, inDirectory: "hooks") else {
            // Try without directory (in case hooks are at root of bundle)
            guard let bundlePath = Bundle.main.path(forResource: filename, ofType: nil) else {
                throw HookInstallerError.scriptNotFoundInBundle(filename)
            }
            try installScript(from: bundlePath, filename: filename)
            return
        }

        try installScript(from: bundlePath, filename: filename)
    }

    private func installFollowUpSkill() throws {
        guard let bundlePath = bundledPath(followUpSkillBundleName) else {
            throw HookInstallerError.scriptNotFoundInBundle(followUpSkillBundleName)
        }
        for configDir in claudeConfigDirs {
            let dest = followUpSkillPath(in: configDir)
            try fileManager.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.copyItem(atPath: bundlePath, toPath: dest.path)
        }
    }

    private func installScript(from bundlePath: String, filename: String) throws {
        let destPath = hooksDir.appendingPathComponent(filename)

        // Remove existing file if present
        if fileManager.fileExists(atPath: destPath.path) {
            try fileManager.removeItem(at: destPath)
        }

        // Copy from bundle
        try fileManager.copyItem(atPath: bundlePath, toPath: destPath.path)

        // Make executable (chmod 755)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destPath.path
        )
    }

    private func loadSettings() -> [String: Any]? {
        guard fileManager.fileExists(atPath: settingsPath.path),
              let data = try? Data(contentsOf: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func saveSettings(_ settings: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsPath)
    }

    private func settingsContainHooks(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else {
            return false
        }

        // Check for Stop hook with our marker
        if let stopHooks = hooks["Stop"] as? [[String: Any]] {
            let hasStateHook = stopHooks.contains { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(stateHookFilename) == true
                }
            }
            if !hasStateHook { return false }
        } else {
            return false
        }

        // Check for Notification hook with our marker
        if let notificationHooks = hooks["Notification"] as? [[String: Any]] {
            let hasPermissionHook = notificationHooks.contains { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(permissionHookFilename) == true
                }
            }
            if !hasPermissionHook { return false }
        } else {
            return false
        }

        // Check for PreToolUse hook (AskUserQuestion) with our marker
        if let preToolUseHooks = hooks["PreToolUse"] as? [[String: Any]] {
            let hasAskQuestionHook = preToolUseHooks.contains { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return (hook["matcher"] as? String) == askQuestionMatcher &&
                    hookList.contains { h in
                        (h["command"] as? String)?.contains(permissionHookFilename) == true
                    }
            }
            if !hasAskQuestionHook { return false }
        } else {
            return false
        }

        // Check for UserPromptSubmit hook with our marker
        if let userPromptHooks = hooks["UserPromptSubmit"] as? [[String: Any]] {
            let hasStateHook = userPromptHooks.contains { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(stateHookFilename) == true
                }
            }
            if !hasStateHook { return false }
        } else {
            return false
        }

        return true
    }

    private func configureSettings() throws {
        // Create ~/.claude directory if needed
        try fileManager.createDirectory(at: claudeDir, withIntermediateDirectories: true)

        // Load existing settings or create empty
        var settings = loadSettings() ?? [:]

        // Get or create hooks dictionary
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Configure Stop hook
        let stateHookPath = "~/.claude/hooks/\(stateHookFilename)"
        let stateHookConfig: [String: Any] = [
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": stateHookPath,
                    "async": true
                ]
            ]
        ]

        // Add or update Stop hooks
        if var stopHooks = hooks["Stop"] as? [[String: Any]] {
            // Remove any existing hooks with our script
            stopHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(stateHookFilename) == true
                }
            }
            stopHooks.append(stateHookConfig)
            hooks["Stop"] = stopHooks
        } else {
            hooks["Stop"] = [stateHookConfig]
        }

        // Configure Notification hook (permission_prompt)
        let permissionHookPath = "~/.claude/hooks/\(permissionHookFilename)"
        let permissionHookConfig: [String: Any] = [
            "matcher": "permission_prompt",
            "hooks": [
                [
                    "type": "command",
                    "command": permissionHookPath,
                    "async": true
                ]
            ]
        ]

        // Add or update Notification hooks
        if var notificationHooks = hooks["Notification"] as? [[String: Any]] {
            // Remove any existing hooks with our script
            notificationHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(permissionHookFilename) == true
                }
            }
            notificationHooks.append(permissionHookConfig)
            hooks["Notification"] = notificationHooks
        } else {
            hooks["Notification"] = [permissionHookConfig]
        }

        // Configure PreToolUse hook (AskUserQuestion) - a pending question is also "asking",
        // so it reuses the same permission-hook.sh script.
        let askQuestionHookConfig: [String: Any] = [
            "matcher": askQuestionMatcher,
            "hooks": [
                [
                    "type": "command",
                    "command": permissionHookPath,
                    "async": true
                ]
            ]
        ]

        // Add or update PreToolUse hooks (preserving any unrelated PreToolUse hooks already there)
        if var preToolUseHooks = hooks["PreToolUse"] as? [[String: Any]] {
            preToolUseHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return (hook["matcher"] as? String) == askQuestionMatcher &&
                    hookList.contains { h in
                        (h["command"] as? String)?.contains(permissionHookFilename) == true
                    }
            }
            preToolUseHooks.append(askQuestionHookConfig)
            hooks["PreToolUse"] = preToolUseHooks
        } else {
            hooks["PreToolUse"] = [askQuestionHookConfig]
        }

        // Configure UserPromptSubmit hook - a backstop that clears a stuck "asking"/"waiting"
        // state when Stop doesn't fire for a given session (e.g. some Desktop-app-driven
        // sessions). Submitting a new prompt proves whatever was pending got resolved.
        let userPromptHookConfig: [String: Any] = [
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": stateHookPath,
                    "async": true
                ]
            ]
        ]

        if var userPromptHooks = hooks["UserPromptSubmit"] as? [[String: Any]] {
            userPromptHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(stateHookFilename) == true
                }
            }
            userPromptHooks.append(userPromptHookConfig)
            hooks["UserPromptSubmit"] = userPromptHooks
        } else {
            hooks["UserPromptSubmit"] = [userPromptHookConfig]
        }

        settings["hooks"] = hooks
        try saveSettings(settings)
    }

    private func removeHooksFromSettings() throws {
        guard var settings = loadSettings() else {
            return // No settings file, nothing to remove
        }

        guard var hooks = settings["hooks"] as? [String: Any] else {
            return // No hooks configured
        }

        // Remove our Stop hook
        if var stopHooks = hooks["Stop"] as? [[String: Any]] {
            stopHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(stateHookFilename) == true
                }
            }
            if stopHooks.isEmpty {
                hooks.removeValue(forKey: "Stop")
            } else {
                hooks["Stop"] = stopHooks
            }
        }

        // Remove our Notification hook
        if var notificationHooks = hooks["Notification"] as? [[String: Any]] {
            notificationHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(permissionHookFilename) == true
                }
            }
            if notificationHooks.isEmpty {
                hooks.removeValue(forKey: "Notification")
            } else {
                hooks["Notification"] = notificationHooks
            }
        }

        // Remove our PreToolUse hook (AskUserQuestion), preserving any unrelated PreToolUse hooks
        if var preToolUseHooks = hooks["PreToolUse"] as? [[String: Any]] {
            preToolUseHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return (hook["matcher"] as? String) == askQuestionMatcher &&
                    hookList.contains { h in
                        (h["command"] as? String)?.contains(permissionHookFilename) == true
                    }
            }
            if preToolUseHooks.isEmpty {
                hooks.removeValue(forKey: "PreToolUse")
            } else {
                hooks["PreToolUse"] = preToolUseHooks
            }
        }

        // Remove our UserPromptSubmit hook
        if var userPromptHooks = hooks["UserPromptSubmit"] as? [[String: Any]] {
            userPromptHooks.removeAll { hook in
                guard let hookList = hook["hooks"] as? [[String: Any]] else { return false }
                return hookList.contains { h in
                    (h["command"] as? String)?.contains(stateHookFilename) == true
                }
            }
            if userPromptHooks.isEmpty {
                hooks.removeValue(forKey: "UserPromptSubmit")
            } else {
                hooks["UserPromptSubmit"] = userPromptHooks
            }
        }

        // Update or remove hooks section
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        try saveSettings(settings)
    }

    private func cleanupStateFiles() {
        let stateDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude-states")

        guard fileManager.fileExists(atPath: stateDir.path) else {
            return
        }

        // Remove all state files
        if let files = try? fileManager.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent.hasPrefix("state-") {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

// MARK: - Error Types

enum HookInstallerError: LocalizedError {
    case scriptNotFoundInBundle(String)
    case failedToCreateDirectory(String)
    case failedToCopyScript(String)

    var errorDescription: String? {
        switch self {
        case .scriptNotFoundInBundle(let name):
            return "Hook script '\(name)' not found in app bundle"
        case .failedToCreateDirectory(let path):
            return "Failed to create directory: \(path)"
        case .failedToCopyScript(let name):
            return "Failed to copy hook script: \(name)"
        }
    }
}
