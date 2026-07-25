//: @use-case:annotate.mcp.bridge
import AnnotateCore
import Foundation
import MCP

public enum MCPStderr {
    public static func write(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

public struct AnnotateMCPServer: Sendable {
    public init() {}

    public func run() async throws {
        let server = Server(
            name: "Annotate",
            version: AnnotateVersion.current,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let launcher = AppLauncher()

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            do {
                let requestLine = try CommandTranslator.requestLine(
                    toolName: parameters.name,
                    arguments: parameters.arguments,
                    requestID: UUID().uuidString
                )
                let client = try await launcher.connectedClient()
                defer { Task { await client.close() } }
                let replyLine = try await client.send(requestLine)
                let reply = try CommandTranslator.toolReply(replyLine: replyLine)
                return .init(content: [.text(text: reply.text, annotations: nil, _meta: nil)], isError: reply.isError)
            } catch {
                let message = error.localizedDescription
                MCPStderr.write("annotate-mcp: \(message)")
                return .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
//: @use-case:end annotate.mcp.bridge
