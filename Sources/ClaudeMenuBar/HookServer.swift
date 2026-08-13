import Foundation
import Network

/// Minimal loopback HTTP/1.1 server. One request per connection, then close.
final class HookServer: @unchecked Sendable {
    typealias Handler = @Sendable (_ path: String, _ body: Data) async -> Data

    let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "claude-menubar.hook-server")
    private var listener: NWListener?

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)

        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if let request = Self.parse(buffer) {
                let work = Task {
                    let body = await self.handler(request.path, request.body)
                    guard !Task.isCancelled else { return }
                    self.respond(connection, body: body)
                }
                self.watchForHangup(connection, cancelling: work)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    /// A session can die while we hold its request open. Without this the card lingers and answering it goes nowhere.
    private func watchForHangup(_ connection: NWConnection, cancelling work: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            guard isComplete || error != nil else { return }
            work.cancel()
            connection.cancel()
        }
    }

    private func respond(_ connection: NWConnection, body: Data) {
        let head = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private struct ParsedRequest {
        let path: String
        let body: Data
    }

    private static func parse(_ buffer: Data) -> ParsedRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8) else { return nil }

        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let path = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
        }

        let bodyStart = range.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= contentLength else { return nil }
        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        return ParsedRequest(path: path, body: buffer[bodyStart..<bodyEnd])
    }
}
