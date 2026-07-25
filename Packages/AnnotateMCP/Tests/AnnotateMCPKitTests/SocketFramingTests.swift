import Foundation
import Testing
@testable import AnnotateMCPKit

@Test("line buffer keeps partial socket frames until their newline arrives")
func lineBufferHandlesFragmentedNDJSON() throws {
    var buffer = LineBuffer(maximumLineLength: 32)
    #expect(try buffer.append(Data(#"{"id":1"#.utf8)).isEmpty)
    #expect(try buffer.append(Data("}\n{\"id\":2}\n".utf8)) == [Data(#"{"id":1}"#.utf8), Data(#"{"id":2}"#.utf8)])
}

@Test("line buffer rejects a socket frame beyond the protocol limit")
func lineBufferRejectsOversizedFrame() {
    var buffer = LineBuffer(maximumLineLength: 8)
    #expect(throws: SocketClientError.frameTooLarge) {
        _ = try buffer.append(Data("123456789".utf8))
    }
}

@Test("the test socket override wins over the application-support default")
func socketPathUsesEnvironmentOverride() {
    #expect(SocketPath.resolve(environment: ["ANNOTATE_SOCKET": "/tmp/annotate-test.sock"]) == "/tmp/annotate-test.sock")
}
