import DeployCore
import Foundation

enum GitHubCLI {
    // Finder-launched apps do not inherit the user's interactive shell PATH.
    static func token(for login: String? = nil) async throws -> String {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/opt/local/bin/gh"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw ServiceError.message("Install GitHub CLI with Homebrew or MacPorts, or choose Personal token.")
        }
        return try await Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = ["auth", "token", "--hostname", "github.com"] + (login.map { ["--user", $0] } ?? [])
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "GH_TOKEN")
            environment.removeValue(forKey: "GITHUB_TOKEN")
            environment["GH_PROMPT_DISABLED"] = "1"
            task.environment = environment
            task.standardInput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            task.standardOutput = pipe
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0, let text = String(data: data, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ServiceError.message("GitHub CLI could not read the saved login. Run gh auth login --hostname github.com --web, or choose Personal token.")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
