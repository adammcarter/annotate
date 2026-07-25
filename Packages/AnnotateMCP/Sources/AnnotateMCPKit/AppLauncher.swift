import AppKit
import Foundation

public enum AppLauncherError: Error, LocalizedError, Equatable, Sendable {
    case autoLaunchDisabled
    case appUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .autoLaunchDisabled:
            "Annotate.app is not running and ANNOTATE_NO_AUTOLAUNCH=1 disables auto-launch. Launch Annotate.app, then retry."
        case .appUnavailable(let socketPath):
            "Annotate.app could not be reached at \(socketPath). Install or launch com.adammcarter.Annotate, then retry."
        }
    }
}

public struct AppLauncher: Sendable {
    public static let bundleIdentifier = "com.adammcarter.Annotate"

    public let socketPath: String
    private let autoLaunchEnabled: Bool

    public init(
        socketPath: String = SocketPath.resolve(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.socketPath = socketPath
        self.autoLaunchEnabled = environment["ANNOTATE_NO_AUTOLAUNCH"] != "1"
    }

    public func connectedClient() async throws -> SocketClient {
        let client = SocketClient(socketPath: socketPath)
        do {
            try await client.connect()
            return client
        } catch {
            await client.close()
        }

        guard autoLaunchEnabled else {
            throw AppLauncherError.autoLaunchDisabled
        }
        try await launchApp()

        for _ in 0..<50 {
            let retry = SocketClient(socketPath: socketPath)
            do {
                try await retry.connect()
                return retry
            } catch {
                await retry.close()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw AppLauncherError.appUnavailable(socketPath)
    }

    private func launchApp() async throws {
        do {
            try launchWithOpen()
        } catch {
            try await launchWithWorkspace()
        }
    }

    private func launchWithOpen() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", Self.bundleIdentifier, "--background"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppLauncherError.appUnavailable(socketPath)
        }
    }

    @MainActor
    private func launchWithWorkspace() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) else {
            throw AppLauncherError.appUnavailable(socketPath)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
