import Foundation
import AppKit

/// Manages installation and updates of the Ghostty Claude Stream Deck plugin
class StreamDeckInstaller {
    static let shared = StreamDeckInstaller()

    private let fileManager = FileManager.default

    // Plugin identifiers
    private let pluginBundleId = "com.chfields.ghostty-claude"
    private let pluginFolderName = "com.chfields.ghostty-claude.sdPlugin"
    private let githubRepo = "chfields/GhostyThemeStreamDeck"

    // Paths
    private var pluginsDir: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.elgato.StreamDeck/Plugins")
    }

    private var installedPluginPath: URL {
        pluginsDir.appendingPathComponent(pluginFolderName)
    }

    private var downloadDir: URL {
        fileManager.temporaryDirectory.appendingPathComponent("GhosttyThemePickerDownloads")
    }

    // MARK: - Public Methods

    /// Check if the plugin is installed
    func isInstalled() -> Bool {
        fileManager.fileExists(atPath: installedPluginPath.path)
    }

    /// Get installed plugin version (from manifest.json)
    func installedVersion() -> String? {
        let manifestPath = installedPluginPath.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["Version"] as? String else {
            return nil
        }
        return version
    }

    /// Fetch latest release info from GitHub
    func fetchLatestRelease(completion: @escaping (Result<ReleaseInfo, Error>) -> Void) {
        let urlString = "https://api.github.com/repos/\(githubRepo)/releases/latest"
        guard let url = URL(string: urlString) else {
            completion(.failure(StreamDeckInstallerError.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }

            guard let data = data else {
                completion(.failure(StreamDeckInstallerError.noData))
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(StreamDeckInstallerError.invalidResponse))
                    return
                }

                // Extract version from tag_name (e.g., "v1.0.0" -> "1.0.0")
                guard let tagName = json["tag_name"] as? String else {
                    completion(.failure(StreamDeckInstallerError.invalidResponse))
                    return
                }
                let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName

                // Find the .streamDeckPlugin asset
                guard let assets = json["assets"] as? [[String: Any]] else {
                    completion(.failure(StreamDeckInstallerError.noAssets))
                    return
                }

                guard let pluginAsset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".streamDeckPlugin") == true }),
                      let downloadURL = pluginAsset["browser_download_url"] as? String else {
                    completion(.failure(StreamDeckInstallerError.noPluginAsset))
                    return
                }

                let releaseInfo = ReleaseInfo(
                    version: version,
                    downloadURL: downloadURL,
                    releaseNotes: json["body"] as? String
                )
                completion(.success(releaseInfo))

            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    /// Download and install the plugin
    func installPlugin(from downloadURL: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let url = URL(string: downloadURL) else {
            completion(.failure(StreamDeckInstallerError.invalidURL))
            return
        }

        // Create download directory
        try? fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true)

        let downloadTask = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            guard let self = self else { return }

            if let error = error {
                completion(.failure(error))
                return
            }

            guard let tempURL = tempURL else {
                completion(.failure(StreamDeckInstallerError.downloadFailed))
                return
            }

            do {
                // Move to our download directory with proper extension
                let pluginFile = self.downloadDir.appendingPathComponent("plugin.streamDeckPlugin")
                if self.fileManager.fileExists(atPath: pluginFile.path) {
                    try self.fileManager.removeItem(at: pluginFile)
                }
                try self.fileManager.moveItem(at: tempURL, to: pluginFile)

                // Open the file (triggers Stream Deck's installer)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(pluginFile)
                    completion(.success(()))
                }
            } catch {
                completion(.failure(error))
            }
        }
        downloadTask.resume()
    }

    /// Uninstall the plugin
    func uninstallPlugin() throws {
        guard isInstalled() else {
            throw StreamDeckInstallerError.notInstalled
        }

        try fileManager.removeItem(at: installedPluginPath)
    }

    /// Check if Stream Deck app is installed
    func isStreamDeckInstalled() -> Bool {
        let streamDeckAppPath = "/Applications/Elgato Stream Deck.app"
        return fileManager.fileExists(atPath: streamDeckAppPath)
    }

    /// Compare versions (returns true if latest > installed)
    func isUpdateAvailable(installed: String, latest: String) -> Bool {
        let installedParts = installed.split(separator: ".").compactMap { Int($0) }
        let latestParts = latest.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(installedParts.count, latestParts.count) {
            let installedPart = i < installedParts.count ? installedParts[i] : 0
            let latestPart = i < latestParts.count ? latestParts[i] : 0

            if latestPart > installedPart {
                return true
            } else if latestPart < installedPart {
                return false
            }
        }
        return false
    }
}

// MARK: - Data Types

struct ReleaseInfo {
    let version: String
    let downloadURL: String
    let releaseNotes: String?
}

// MARK: - Errors

enum StreamDeckInstallerError: LocalizedError {
    case invalidURL
    case noData
    case invalidResponse
    case noAssets
    case noPluginAsset
    case downloadFailed
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .noData:
            return "No data received from server"
        case .invalidResponse:
            return "Invalid response from GitHub API"
        case .noAssets:
            return "No release assets found"
        case .noPluginAsset:
            return "No .streamDeckPlugin file found in release"
        case .downloadFailed:
            return "Failed to download plugin"
        case .notInstalled:
            return "Plugin is not installed"
        }
    }
}
