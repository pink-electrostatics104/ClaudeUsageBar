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

    /// Applies a usage update. Nil fields are left unchanged.
    func update(label: String?, detail: String?, reset: String?) {
        queue.sync {
            if let label = label { labelValue = label }
            if let detail = detail { detailValue = detail }
            if let reset = reset { resetText = reset }
            lastUpdate = Date()
        }
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
    let body: Data
}

// MARK: - App delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = UsageState()
    private let port: NWEndpoint.Port = 8787
    private let netQueue = DispatchQueue(label: "com.claudeusagebar.http")

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

            if let request = self.parse(buffer) {
                self.handle(request, on: connection)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    /// Splits on the \r\n\r\n boundary, parses the request line and headers, and
    /// returns nil until the body reaches Content-Length.
    private func parse(_ data: Data) -> HTTPRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: data.startIndex..<separator.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = separator.upperBound
        let available = data.endIndex - bodyStart
        if available < contentLength { return nil } // body not complete yet
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return HTTPRequest(method: method, path: path, body: body)
    }

    /// Routes the request and writes a response. Every response carries permissive
    /// CORS headers so the extension can reach it from the claude.ai origin.
    private func handle(_ request: HTTPRequest, on connection: NWConnection) {
        var status = "404 Not Found"
        var body = ""

        switch (request.method, request.path) {
        case ("OPTIONS", _):
            status = "204 No Content"
        case ("GET", "/health"):
            status = "200 OK"
            body = "ok"
        case ("POST", "/usage"):
            if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
                state.update(
                    label: json["label"] as? String,
                    detail: json["detail"] as? String,
                    reset: json["reset"] as? String
                )
                DispatchQueue.main.async { [weak self] in self?.render() }
            }
            status = "200 OK"
            body = "ok"
        default:
            break
        }

        let bodyData = Data(body.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Access-Control-Allow-Origin: *\r
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
