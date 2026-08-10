import Foundation

/// A one-shot loopback HTTP listener that catches the OAuth redirect, so the
/// browser hands the code back directly and there is nothing to copy.
///
/// Pasting was the weakest step of the flow: the code is single-use and
/// short-lived, so a slow paste, a partial selection or a second attempt all
/// fail in ways indistinguishable from a broken endpoint. `claude` avoids this
/// the same way — it runs a local callback server, and only falls back to
/// pasting when the browser cannot reach it.
///
/// Built on POSIX sockets rather than Network.framework: this needs one blocking
/// accept on loopback and nothing more, and NWListener refused a portless bind
/// here with EINVAL.
public final class CallbackListener: @unchecked Sendable {
    public let port: UInt16
    /// `localhost` rather than the literal address: that is the form checked
    /// against the authorize endpoint, and browsers resolve it to the loopback
    /// address the socket is bound to.
    public var redirectURI: String { "http://localhost:\(port)/callback" }

    private let socketFD: Int32
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(code: String, state: String?), Error>?
    private var delivered: Result<(code: String, state: String?), Error>?
    private var closed = false

    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CCError("로컬 콜백 소켓을 만들지 못했습니다.") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Loopback only, and port 0 so the kernel assigns a free one.
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            let code = errno
            close(fd)
            throw CCError("로컬 콜백 서버를 열지 못했습니다 (errno \(code)).")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0, assigned.sin_port != 0 else {
            close(fd)
            throw CCError("콜백 포트를 확인하지 못했습니다.")
        }

        socketFD = fd
        port = UInt16(bigEndian: assigned.sin_port)
        startAccepting()
    }

    public func waitForCode(timeout: TimeInterval = 300) async throws -> (code: String, state: String?) {
        try await withThrowingTaskGroup(of: (code: String, state: String?).self) { group in
            group.addTask { try await self.nextCallback() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw CCError("브라우저 승인을 기다리다 시간이 초과되었습니다.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CCError("콜백을 받지 못했습니다.")
            }
            return result
        }
    }

    public func stop() {
        lock.lock()
        let alreadyClosed = closed
        closed = true
        lock.unlock()
        if !alreadyClosed { close(socketFD) }
    }

    // MARK: - Accept loop

    private func startAccepting() {
        Thread.detachNewThread { [self] in
            let client = accept(socketFD, nil, nil)
            guard client >= 0 else {
                deliver(.failure(CCError("콜백 연결을 받지 못했습니다.")))
                return
            }
            defer { close(client) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(client, &buffer, buffer.count)
            let request = count > 0 ? String(decoding: buffer[0 ..< count], as: UTF8.self) : ""
            let parsed = Self.parse(requestLine: request)

            let body = Self.page(success: parsed != nil)
            let response = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(body.utf8.count)\r\n"
                + "Connection: close\r\n\r\n"
                + body
            _ = Array(response.utf8).withUnsafeBufferPointer {
                write(client, $0.baseAddress, $0.count)
            }

            if let parsed {
                deliver(.success(parsed))
            } else {
                // A refused consent comes back on this same redirect, so it has
                // to surface as a refusal rather than as a hang.
                deliver(.failure(CCError("승인이 완료되지 않았습니다. 다시 시도하십시오.")))
            }
        }
    }

    /// The callback can land before or after the caller starts waiting, so the
    /// result is held until there is someone to hand it to.
    private func deliver(_ result: Result<(code: String, state: String?), Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        if waiting == nil { delivered = result }
        lock.unlock()
        waiting?.resume(with: result)
    }

    private func nextCallback() async throws -> (code: String, state: String?) {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let ready = delivered {
                delivered = nil
                lock.unlock()
                cont.resume(with: ready)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    // MARK: - Parsing

    static func parse(requestLine raw: String) -> (code: String, state: String?)? {
        guard let line = raw.split(whereSeparator: \.isNewline).first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)"),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              !code.isEmpty else { return nil }
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value
        return (code, state)
    }

    static func page(success: Bool) -> String {
        let title = success ? "승인이 완료되었습니다" : "승인이 완료되지 않았습니다"
        let detail = success ? "이 창을 닫고 CCQuota로 돌아가십시오." : "CCQuota에서 다시 시도하십시오."
        return """
        <!doctype html><html lang="ko"><head><meta charset="utf-8">
        <title>CCQuota</title><style>
        body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;
        place-items:center;height:100vh;margin:0;background:#f6f6f5;color:#1a1a19}
        @media(prefers-color-scheme:dark){body{background:#1a1a19;color:#f6f6f5}}
        div{text-align:center}p{opacity:.65;margin-top:.6em}
        </style></head><body><div><h2>\(title)</h2><p>\(detail)</p></div></body></html>
        """
    }
}
