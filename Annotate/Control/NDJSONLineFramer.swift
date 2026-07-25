import AnnotateCore
import Foundation

/// Reassembles a byte stream into newline-delimited JSON lines. A socket read
/// boundary lands wherever the kernel put it, so a request can arrive split
/// across chunks or several can arrive in one: the framer buffers the partial
/// tail and emits only complete lines.
///
/// The length cap is the first line of defence on an unauthenticated local
/// socket — a peer that never sends a newline must not be able to grow this
/// buffer without bound.
struct NDJSONLineFramer {
    private let maximumLineLength: Int
    private var buffer = Data()

    init(maximumLineLength: Int = ProtocolCodec.maximumLineLength) {
        self.maximumLineLength = maximumLineLength
    }

    mutating func append(_ data: Data) throws -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 0x0A {
                lines.append(String(decoding: buffer, as: UTF8.self))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
                guard buffer.count <= maximumLineLength else { throw NDJSONLineFramerError.lineTooLarge }
            }
        }
        return lines
    }
}

enum NDJSONLineFramerError: Error, Equatable {
    case lineTooLarge
}

/// The per-connection queue of framed-but-not-yet-answered request lines. The
/// second line of defence: replies are strictly serialised, so a client that
/// pipelines faster than the app can answer would otherwise queue without bound.
struct BoundedRequestBacklog {
    private let maximumCount: Int
    private var lines: [String] = []

    init(maximumCount: Int = 64) {
        self.maximumCount = maximumCount
    }

    var isEmpty: Bool { lines.isEmpty }

    mutating func append(_ incoming: [String]) throws {
        guard lines.count + incoming.count <= maximumCount else { throw RequestBacklogError.overflow }
        lines.append(contentsOf: incoming)
    }

    mutating func removeFirst() -> String {
        lines.removeFirst()
    }
}

enum RequestBacklogError: Error, Equatable {
    case overflow
}
