import Foundation

/// Manages first-run TLS setup: mkcert CA installation and certificate generation.
/// Certs are stored in ~/Library/Application Support/AirplaneMode/.
public struct SetupManager {
    public static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("AirplaneMode", isDirectory: true)
    }()

    public static var certPath: String { supportDir.appendingPathComponent("localhost.pem").path }
    public static var keyPath: String { supportDir.appendingPathComponent("localhost-key.pem").path }

    /// Returns (cert, key) file paths.
    public static func certPaths() -> (cert: String, key: String) {
        (cert: certPath, key: keyPath)
    }

    /// Checks if mkcert certs already exist.
    public static func isSetupComplete() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: certPath) && fm.fileExists(atPath: keyPath)
    }

    /// Runs the full mkcert setup:
    /// 1. Creates the support directory
    /// 2. Installs the mkcert CA (may prompt for admin password)
    /// 3. Generates localhost certs for the relay hostname
    public static func runSetup() async throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: supportDir.path) {
            try fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
        }

        let hostname = ProfileGenerator.localHostname()

        try await runProcess(
            executable: findMkcert(),
            arguments: ["-install"]
        )

        try await runProcess(
            executable: findMkcert(),
            arguments: [
                "-cert-file", certPath,
                "-key-file", keyPath,
                "localhost",
                "\(hostname).local",
                "127.0.0.1",
                "::1",
            ]
        )
    }

    /// Locates the mkcert binary. Checks common Homebrew paths.
    public static func findMkcert() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/mkcert",
            "/usr/local/bin/mkcert",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["mkcert"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        try whichProcess.run()
        whichProcess.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if path.isEmpty {
            throw SetupError.mkcertNotFound
        }
        return path
    }

    private static func runProcess(executable: String, arguments: [String]) async throws {
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                if finished.terminationStatus != 0 {
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
                    continuation.resume(throwing: SetupError.commandFailed(executable, errMsg))
                } else {
                    continuation.resume()
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

public enum SetupError: Error, LocalizedError, Sendable {
    case mkcertNotFound
    case commandFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .mkcertNotFound:
            "mkcert not found. Install it with: brew install mkcert"
        case .commandFailed(let cmd, let msg):
            "\(cmd) failed: \(msg)"
        }
    }
}
