import AnnotateMCPKit
import Darwin

@main
struct AnnotateMCPCommand {
    static func main() async {
        do {
            try await AnnotateMCPServer().run()
        } catch {
            MCPStderr.write("annotate-mcp failed: \(error.localizedDescription)")
            exit(EXIT_FAILURE)
        }
    }
}
