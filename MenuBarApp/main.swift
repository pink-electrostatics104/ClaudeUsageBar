// ClaudeUsageBar menu bar app.
//
// An NSStatusItem agent (no Dock icon) that runs a minimal HTTP server bound to
// 127.0.0.1:8787 only. A browser extension POSTs the current Claude.ai usage
// figure to /usage and the app renders it in the menu bar. The server is never
// reachable off the loopback interface.

import Cocoa
import Network

// MARK: - Shared state

/// Holds the latest usage figures. All access is serialized so the network
/// callbacks and the main thread never race.
final class UsageState {
    private let queue = DispatchQueue(label: "com.claudeusagebar.state")
    private var labelValue = "Claude --"
    private var detailValue = ""
    private var resetText = ""
    private var lastUpdate = Date() // launch time, so the app goes stale 600s after launch with no data

    /// Applies a usage update. Nil fields are left unchanged. Values are treated
    /// as untrusted: control characters are stripped and length is capped before
    /// they ever reach the menu bar.
    func update(label: String?, detail: String?, reset: String?) {
        queue.sync {
            if let label = label { labelValue = UsageState.sanitize(label) }
            if let detail = detail { detailValue = UsageState.sanitize(detail) }
            if let reset = reset { resetText = UsageState.sanitize(reset) }
            lastUpdate = Date()
        }
    }

    private static func sanitize(_ s: String) -> String {
        let scalars = s.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.prefix(120)
        return String(String.UnicodeScalarView(scalars))
    }

    /// A consistent snapshot for rendering. `stale` is true if no update in 600s.
    var snapshot: (label: String, detail: String, reset: String, stale: Bool) {
        queue.sync {
            let stale = Date().timeIntervalSince(lastUpdate) > 600
            return (labelValue, detailValue, resetText, stale)
        }
    }
}

// MARK: - HTTP request

private struct HTTPRequest {
    let method: String
    let path: String
    let host: String
    let body: Data
}

private enum ParseResult {
    case incomplete       // need more bytes
    case ready(HTTPRequest)
    case bad              // malformed or out of bounds, close with 400
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = UsageState()
    private let port: NWEndpoint.Port = 8787
    private let netQueue = DispatchQueue(label: "com.claudeusagebar.http")

    // Hardening limits and allow lists.
    private let maxBodyBytes = 65536
    private let maxRequestBytes = 65536 + 8192 // body cap plus header slack
    private let allowedHosts: Set<String> = ["127.0.0.1:8787", "localhost:8787"]
    private let allowedOrigin = "https://claude.ai"

    private var statusItem: NSStatusItem!
    private var detailItem: NSMenuItem!
    private var resetItem: NSMenuItem!
    private var listener: NWListener?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        render()
        startServer()

        // Re-render every 30s so the stale state appears even without new data.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.render()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open claude.ai", action: #selector(openClaude), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        // Display-only lines. Passing action: nil leaves them auto-disabled.
        detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(detailItem)
        resetItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func render() {
        let s = state.snapshot
        statusItem.button?.title = s.stale ? "Claude (stale)" : s.label
        detailItem.title = s.detail.isEmpty ? "No usage data yet" : s.detail
        resetItem.title = s.reset.isEmpty ? "Reset: unknown" : "Resets \(s.reset)"
    }

    @objc private func openClaude() {
        if let url = URL(string: "https://claude.ai") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: HTTP server

    private func startServer() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Force the bind to loopback only. The socket is never exposed off 127.0.0.1.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

        guard let listener = try? NWListener(using: params) else {
            NSLog("ClaudeUsageBar: failed to bind 127.0.0.1:\(port)")
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else { return }
            connection.start(queue: self.netQueue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: netQueue)
    }

    /// Reads from a connection until a complete request is buffered, then handles it.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var buffer = buffer
            if let data = data { buffer.append(data) }

            switch self.parse(buffer) {
            case .ready(let request):
                self.handle(request, on: connection)
            case .bad:
                self.send(status: "400 Bad Request", body: "bad request", on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Splits on the \r\n\r\n boundary, parses the request line and headers, and
    /// returns .incomplete until the body reaches Content-Length. Rejects
    /// malformed requests, oversized requests, and out of range Content-Length.
    private func parse(_ data: Data) -> ParseResult {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxRequestBytes ? .bad : .incomplete
        }
        let headerData = data.subdata(in: data.startIndex..<separator.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return .bad }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .bad }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return .bad }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        var host = ""
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].lowercased()
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if key == "content-length" {
                // Reject negative or oversized lengths to avoid a crash or unbounded buffering.
                guard let n = Int(value), n >= 0, n <= maxBodyBytes else { return .bad }
                contentLength = n
            } else if key == "host" {
                host = value
            }
        }

        let bodyStart = separator.upperBound
        let available = data.endIndex - bodyStart
        if available < contentLength { return .incomplete } // body not complete yet
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return .ready(HTTPRequest(method: method, path: path, host: host, body: body))
    }

    /// Routes the request and writes a response. Requests with an unexpected Host
    /// header are rejected to block DNS rebinding from other origins.
    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        guard allowedHosts.contains(request.host.lowercased()) else {
            send(status: "403 Forbidden", body: "forbidden", on: connection)
            return
        }

        switch (request.method, request.path) {
        case ("OPTIONS", _):
            send(status: "204 No Content", body: "", on: connection)
        case ("GET", "/health"):
            send(status: "200 OK", body: "ok", on: connection)
        case ("POST", "/usage"):
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                state.update(
                    label: json["label"] as? String,
                    detail: json["detail"] as? String,
                    reset: json["reset"] as? String
                )
                DispatchQueue.main.async { [weak self] in self?.render() }
            }
            send(status: "200 OK", body: "ok", on: connection)
        default:
            send(status: "404 Not Found", body: "", on: connection)
        }
    }

    /// Writes a response and closes the connection. CORS is locked to the claude.ai
    /// origin so other web origins cannot drive the local server from a page.
    private func send(status: String, body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Access-Control-Allow-Origin: \(allowedOrigin)\r
        Access-Control-Allow-Methods: POST, GET, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Content-Type: text/plain\r
        Content-Length: \(bodyData.count)\r
        Connection: close\r
        \r

        """
        var response = Data(head.utf8)
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar agent, no Dock icon
app.run()
