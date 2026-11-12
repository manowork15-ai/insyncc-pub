import Foundation
import Network

/// A one-shot HTTP server on 127.0.0.1 that catches Google's OAuth redirect
/// (the loopback flow Google recommends for desktop apps).
final class LoopbackServer: @unchecked Sendable { // all state is confined to `queue`
    private let queue = DispatchQueue(label: "VideoDiary.oauth.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?

    /// Starts listening on a random free port and returns it.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue, once.claim() {
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    if once.claim() { cont.resume(throwing: error) }
                    self?.finish(.failure(error))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        }
    }

    /// Waits for the browser to hit the redirect URL.
    func waitForCallback() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                if let result = self.result {
                    cont.resume(with: result)
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    // Always called on `queue`.
    private func finish(_ result: Result<URL, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
        queue.asyncAfter(deadline: .now() + 1) { [listener] in listener?.cancel() }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let url = URL(string: "http://127.0.0.1\(parts[1])") else {
                self.respond(connection, status: "400 Bad Request", body: "Bad request")
                return
            }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.contains(where: { $0.name == "code" || $0.name == "error" }) else {
                self.respond(connection, status: "404 Not Found", body: "Not found")
                return
            }
            let ok = items.contains { $0.name == "code" }
            self.respond(connection, status: "200 OK", body: Self.page(success: ok))
            self.finish(.success(url))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func page(success: Bool) -> String {
        let title = success ? "You're connected" : "Sign-in was cancelled"
        let message = success
            ? "Video Diary can now save entries to your Google Drive. You can close this tab."
            : "No changes were made. You can close this tab and try again from Video Diary."
        return """
        <!doctype html><html><head><meta charset="utf-8"><title>Video Diary</title>
        <style>body{font:16px -apple-system,system-ui;display:grid;place-items:center;height:100vh;margin:0;background:#f5f5f7;color:#1d1d1f}
        .card{background:#fff;padding:40px 48px;border-radius:18px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;max-width:420px}
        h1{font-size:22px;margin:0 0 8px}p{color:#6e6e73;margin:0}</style></head>
        <body><div class="card"><h1>\(title)</h1><p>\(message)</p></div></body></html>
        """
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
