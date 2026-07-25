import AnnotateCore
import Foundation
@preconcurrency import Network

public enum SocketClientError: Error, LocalizedError, Equatable, Sendable {
    case connectionFailed(String)
    case connectionClosed
    case sendFailed(String)
    case replyTimedOut
    case frameTooLarge

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message): "Could not connect to Annotate.app: \(message)"
        case .connectionClosed: "Annotate.app closed the socket before replying."
        case .sendFailed(let message): "Could not send the command to Annotate.app: \(message)"
        case .replyTimedOut: "Annotate.app did not reply within 5 seconds."
        case .frameTooLarge: "Annotate.app sent a protocol line larger than 8 KB."
        }
    }
}

public enum SocketPath {
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let override = environment["ANNOTATE_SOCKET"], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Annotate/annotate.sock")
            .path
    }
}

struct LineBuffer: Sendable {
    private let maximumLineLength: Int
    private var pending = Data()

    init(maximumLineLength: Int = ProtocolCodec.maximumLineLength) {
        self.maximumLineLength = maximumLineLength
    }

    mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in data {
            if byte == 10 {
                lines.append(pending)
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(byte)
                guard pending.count <= maximumLineLength else {
                    throw SocketClientError.frameTooLarge
                }
            }
        }
        return lines
    }
}

public actor SocketClient {
    private static let networkQueue = DispatchQueue(label: "com.adammcarter.annotate-mcp.socket")

    public let socketPath: String
    private var connection: NWConnection?
    private var lineBuffer = LineBuffer()

    public init(socketPath: String = SocketPath.resolve()) {
        self.socketPath = socketPath
    }

    nonisolated static func connectionFailure(for state: NWConnection.State) -> SocketClientError? {
        switch state {
        case .waiting(let error), .failed(let error):
            .connectionFailed(error.debugDescription)
        case .cancelled:
            .connectionClosed
        default:
            nil
        }
    }

    nonisolated static func shouldRetry(writeCompleted: Bool, attempt: Int) -> Bool {
        attempt == 0 && !writeCompleted
    }

    public func connect() async throws {
        guard connection == nil else { return }
        let candidate = NWConnection(to: .unix(path: socketPath), using: .tcp)
        try await waitUntilReady(candidate)
        connection = candidate
    }

    public func close() {
        connection?.cancel()
        connection = nil
        lineBuffer = LineBuffer()
    }

    public func send(_ requestLine: Data) async throws -> Data {
        for attempt in 0..<2 {
            var writeCompleted = false
            do {
                try await connect()
                try await write(requestLine)
                writeCompleted = true
                return try await readReplyWithTimeout()
            } catch {
                close()
                if Self.shouldRetry(writeCompleted: writeCompleted, attempt: attempt) { continue }
                throw error
            }
        }
        throw SocketClientError.connectionClosed
    }

    private func waitUntilReady(_ candidate: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            candidate.stateUpdateHandler = { state in
                if case .ready = state {
                    candidate.stateUpdateHandler = nil
                    continuation.resume()
                } else if let error = Self.connectionFailure(for: state) {
                    candidate.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            candidate.start(queue: Self.networkQueue)
        }
    }

    private func write(_ line: Data) async throws {
        guard let connection else { throw SocketClientError.connectionClosed }
        var framed = line
        if framed.last != 10 { framed.append(10) }
        guard framed.count <= ProtocolCodec.maximumLineLength + 1 else {
            throw SocketClientError.frameTooLarge
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: SocketClientError.sendFailed(error.debugDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func readReplyWithTimeout() async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.readReply() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw SocketClientError.replyTimedOut
            }
            defer { group.cancelAll() }
            do {
                guard let reply = try await group.next() else {
                    throw SocketClientError.connectionClosed
                }
                return reply
            } catch {
                close()
                throw error
            }
        }
    }

    private func readReply() async throws -> Data {
        while true {
            let data = try await readChunk()
            let lines = try lineBuffer.append(data)
            if let line = lines.first {
                return line
            }
        }
    }

    private func readChunk() async throws -> Data {
        guard let connection else { throw SocketClientError.connectionClosed }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: ProtocolCodec.maximumLineLength + 1) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: SocketClientError.connectionFailed(error.debugDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: SocketClientError.connectionClosed)
                } else {
                    continuation.resume(throwing: SocketClientError.connectionClosed)
                }
            }
        }
    }
}
