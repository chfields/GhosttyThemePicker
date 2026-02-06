import Foundation
import Network

// MARK: - API Response Types

struct WindowResponse: Codable {
    let id: String
    let pid: Int32
    let axIndex: Int
    let title: String
    let claudeState: String
    let displayName: String
    let workstreamName: String?
    let hasClaudeProcess: Bool
}

struct WindowsResponse: Codable {
    let windows: [WindowResponse]
}

struct HealthResponse: Codable {
    let status: String
    let version: String
}

struct ErrorResponse: Codable {
    let error: String
}

// MARK: - API Server

class APIServer {
    static let shared = APIServer()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private let portFilePath = NSHomeDirectory() + "/.ghostty-api-port"
    private let basePort: UInt16 = 49876
    private let maxPortAttempts = 10

    // Reference to get window data - set by the app
    var windowDataProvider: (() -> [GhosttyWindow])?
    var focusWindowHandler: ((Int, pid_t) -> Void)?

    private init() {}

    func start() {
        // Try ports starting from basePort
        for offset in 0..<maxPortAttempts {
            let tryPort = basePort + UInt16(offset)
            if startListener(on: tryPort) {
                port = tryPort
                writePortFile()
                print("API Server started on port \(port)")
                return
            }
        }
        print("Failed to start API server - no available ports")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        removePortFile()
        print("API Server stopped")
    }

    private func startListener(on port: UInt16) -> Bool {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)

            listener?.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("API Server listening on port \(port)")
                case .failed(let error):
                    print("API Server failed: \(error)")
                    self?.listener = nil
                case .cancelled:
                    print("API Server cancelled")
                default:
                    break
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener?.start(queue: .main)

            // Give it a moment to fail if port is in use
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

            return listener?.state == .ready
        } catch {
            print("Failed to create listener on port \(port): \(error)")
            return false
        }
    }

    private func writePortFile() {
        do {
            try String(port).write(toFile: portFilePath, atomically: true, encoding: .utf8)
            print("Wrote port file: \(portFilePath)")
        } catch {
            print("Failed to write port file: \(error)")
        }
    }

    private func removePortFile() {
        try? FileManager.default.removeItem(atPath: portFilePath)
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveRequest(connection)
            case .failed(let error):
                print("Connection failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func receiveRequest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let data = data, !data.isEmpty {
                if let request = String(data: data, encoding: .utf8) {
                    self.handleHTTPRequest(request, connection: connection)
                }
            }

            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func handleHTTPRequest(_ request: String, connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection, status: 400, body: ErrorResponse(error: "Invalid request"))
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection, status: 400, body: ErrorResponse(error: "Invalid request line"))
            return
        }

        let method = parts[0]
        let path = parts[1]

        // Route the request
        switch (method, path) {
        case ("GET", "/api/health"):
            handleHealth(connection)

        case ("GET", "/api/windows"):
            handleGetWindows(connection)

        case ("POST", _) where path.hasPrefix("/api/windows/") && path.hasSuffix("/focus"):
            let windowId = extractWindowId(from: path)
            handleFocusWindow(connection, windowId: windowId)

        case ("OPTIONS", _):
            // Handle CORS preflight
            sendCORSResponse(connection)

        default:
            sendResponse(connection, status: 404, body: ErrorResponse(error: "Not found"))
        }
    }

    private func extractWindowId(from path: String) -> String {
        // /api/windows/{id}/focus -> extract {id}
        let components = path.components(separatedBy: "/")
        if components.count >= 4 {
            return components[3]
        }
        return ""
    }

    private func handleHealth(_ connection: NWConnection) {
        let response = HealthResponse(status: "ok", version: "1.0.0")
        sendResponse(connection, status: 200, body: response)
    }

    private func handleGetWindows(_ connection: NWConnection) {
        guard let provider = windowDataProvider else {
            sendResponse(connection, status: 503, body: ErrorResponse(error: "Window data not available"))
            return
        }

        let windows = provider()
        let windowResponses = windows.map { window -> WindowResponse in
            WindowResponse(
                id: "\(window.pid)-\(window.axIndex)",
                pid: window.pid,
                axIndex: window.axIndex,
                title: window.name,
                claudeState: claudeStateString(window.claudeState),
                displayName: window.displayName,
                workstreamName: window.workstreamName,
                hasClaudeProcess: window.hasClaudeProcess
            )
        }

        let response = WindowsResponse(windows: windowResponses)
        sendResponse(connection, status: 200, body: response)
    }

    private func claudeStateString(_ state: ClaudeState) -> String {
        switch state {
        case .waiting: return "waiting"
        case .working: return "working"
        case .running: return "running"
        case .notRunning: return "notRunning"
        }
    }

    private func handleFocusWindow(_ connection: NWConnection, windowId: String) {
        // Parse window ID (format: "pid-axIndex")
        let parts = windowId.components(separatedBy: "-")
        guard parts.count == 2,
              let pid = pid_t(parts[0]),
              let axIndex = Int(parts[1]) else {
            sendResponse(connection, status: 400, body: ErrorResponse(error: "Invalid window ID"))
            return
        }

        if let handler = focusWindowHandler {
            handler(axIndex, pid)
            sendResponse(connection, status: 200, body: ["success": true])
        } else {
            sendResponse(connection, status: 503, body: ErrorResponse(error: "Focus handler not available"))
        }
    }

    private func sendResponse<T: Encodable>(_ connection: NWConnection, status: Int, body: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted

        guard let jsonData = try? encoder.encode(body),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            connection.cancel()
            return
        }

        let statusText = httpStatusText(status)
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(jsonData.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Connection: close\r
        \r
        \(jsonString)
        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendCORSResponse(_ connection: NWConnection) {
        let response = """
        HTTP/1.1 204 No Content\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Connection: close\r
        \r

        """

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func httpStatusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}
