import Network
import Testing
@testable import AnnotateMCPKit

@Test("a waiting Unix socket state fails the current connection attempt")
func waitingSocketStateFailsConnectionAttempt() {
    let error = SocketClient.connectionFailure(for: .waiting(.posix(POSIXErrorCode.ECONNREFUSED)))
    guard case .connectionFailed = error else {
        Issue.record("Expected waiting state to produce a connection failure")
        return
    }
}

@Test("a request retries only before its bytes have completed writing")
func requestRetryRequiresAnIncompleteWrite() {
    #expect(SocketClient.shouldRetry(writeCompleted: false, attempt: 0))
    #expect(!SocketClient.shouldRetry(writeCompleted: true, attempt: 0))
    #expect(!SocketClient.shouldRetry(writeCompleted: false, attempt: 1))
}
