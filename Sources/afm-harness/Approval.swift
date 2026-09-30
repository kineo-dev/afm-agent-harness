import Foundation

public final class Approval: @unchecked Sendable {
    public static let terminalLock = NSLock()
    private let keysLock = NSLock()
    public let scopeDir: String?
    public let interactive: Bool
    private var alwaysAllowedKeys: Set<String> = []

    public static let safePrefixes: [String] = [
        "ls", "ll", "la", "cat ", "head ", "tail ", "stat ", "file ",
        "wc ", "du ", "df ", "grep ", "cut ", "sort ",
        "uniq ", "echo ", "pwd", "which ", "whoami", "id",
        "uname", "uname -a", "hostname", "date", "uptime", "free",
        "sw_vers", "pgrep",
        "find ", "tree", "rg ",
        "lsof", "git status", "git log", "git diff", "git show",
        "git branch", "git remote", "git config --get", "git rev-parse", "git tag",
        "docker ps", "docker images", "docker stats",
        "read_file "
    ]

    public static let destructivePatterns: [String] = [
        "rm -rf", "rm -r /",
        "dd if=", "dd of=",
        "mkfs", "fdisk", "parted", "wipefs",
        "reboot", "shutdown", "poweroff", "halt",
        "> /dev/",
        "sed -i"
    ]

    public static let sensitivePathPatterns: [String] = [
        ".ssh", ".aws", ".gnupg", ".claude", "credential", "secret", ".pem", "id_rsa", ".env",
        ".netrc", ".kube/config", ".docker/config.json", ".npmrc",
        "/etc/shadow", "/etc/sudoers", "id_ed25519", "id_ecdsa", ".htpasswd", ".kdbx", ".vault-token",
        ".config/gcloud", ".config/gh"
    ]

    public static let installPatterns: [String] = [
        "sudo ", "brew install", "brew reinstall",
        "pip install", "pip3 install", "npm install -g", "npm i -g", "yarn global add",
        "apt install", "apt-get install", "snap install"
    ]

    private static let chainOpsAndBrace: [String] = ["&&", "||", "|", ";", "\n", "\r", "&", ">>", ">", ">&", "<", "{"]
    private static let injectionOps: [String] = ["`", "$(", "${", "$'"]

    public init(scopeDir: String? = nil, interactive: Bool = true) {
        if let dir = scopeDir, !dir.isEmpty {
            self.scopeDir = (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? URL(fileURLWithPath: dir).standardized.path
        } else {
            self.scopeDir = nil
        }
        self.interactive = interactive
    }

    public static func sanitizeForTerminal(_ text: String) -> String {
        // Strip ANSI CSI escape sequences (\u{1B}[...) and OSC sequences (\u{1B}]...)
        var result = text.replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\x1B\].*?(\x07|\x1B\\)"#, with: "", options: .regularExpression)
        // Strip non-printable C0/C1 control characters except \n and \t
        return result.unicodeScalars.filter { scalar in
            let v = scalar.value
            return (v >= 0x20 && v <= 0x7E) || v == 0x0A || v == 0x09 || v >= 0xA0
        }.map { String($0) }.joined()
    }

    public static func hasUnsafeOperators(_ command: String) -> Bool {
        var inSq = false
        var inDq = false
        let chars = Array(command)
        let n = chars.count
        var i = 0

        while i < n {
            let ch = chars[i]
            var escaped = false

            if ch == "'" || ch == "\"" {
                if inSq {
                    escaped = false
                } else {
                    var backslashCount = 0
                    var j = i - 1
                    while j >= 0 && chars[j] == "\\" {
                        backslashCount += 1
                        j -= 1
                    }
                    escaped = (backslashCount % 2 == 1)
                }
            }

            if ch == "'" && !inDq && !escaped {
                inSq.toggle()
            } else if ch == "\"" && !inSq && !escaped {
                inDq.toggle()
            } else {
                let tail = String(chars[i...])
                if !inSq {
                    for op in injectionOps {
                        if tail.hasPrefix(op) {
                            return true
                        }
                    }
                }
                if !inSq && !inDq {
                    for op in chainOpsAndBrace {
                        if tail.hasPrefix(op) {
                            return true
                        }
                    }
                }
            }
            i += 1
        }
        return false
    }

    public static func isDestructive(_ command: String) -> Bool {
        destructivePatterns.contains { command.contains($0) }
    }

    public static func isSensitive(_ command: String) -> Bool {
        let lower = command.lowercased()
        return sensitivePathPatterns.contains { lower.contains($0.lowercased()) }
    }

    public static func isInstall(_ command: String) -> Bool {
        let lower = command.lowercased()
        return installPatterns.contains { lower.contains($0.lowercased()) }
    }

    public static func tokenizeForPaths(_ command: String) -> [String] {
        let parts = command.split { $0.isWhitespace }.map(String.init)
        var paths: [String] = []
        for raw in parts {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            if token.hasPrefix("-") {
                let candidate: String
                if let eqIndex = token.firstIndex(of: "=") {
                    candidate = String(token[token.index(after: eqIndex)...])
                } else {
                    candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                }
                if candidate.contains("/") || candidate.hasPrefix("~") || candidate.hasPrefix(".") {
                    paths.append(candidate)
                }
            } else if !token.isEmpty {
                paths.append(token)
            }
        }
        return paths
    }

    public func hasOutOfScopePath(_ command: String) -> Bool {
        guard let scope = self.scopeDir, !scope.isEmpty else { return false }
        let scopeUrl = URL(fileURLWithPath: scope).standardized
        let scopeCanonical = (try? scopeUrl.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? scopeUrl.path
        let scopePrefix = scopeCanonical.hasSuffix("/") ? scopeCanonical : scopeCanonical + "/"

        let tokens = Self.tokenizeForPaths(command)
        for token in tokens {
            let expanded = NSString(string: token).expandingTildeInPath
            let candidateUrl = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : scopeUrl.appendingPathComponent(expanded)
            let standardized = candidateUrl.standardized
            let candidateCanonical = (try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? standardized.path

            if candidateCanonical != scopeCanonical && !candidateCanonical.hasPrefix(scopePrefix) {
                return true
            }
        }
        return false
    }

    public func isDefinitelySafe(_ command: String) -> Bool {
        let stripped = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return false }

        // Must match a safe prefix
        let isSafePrefix = Self.safePrefixes.contains { prefix in
            if prefix.hasSuffix(" ") {
                return stripped.hasPrefix(prefix)
            } else {
                if stripped == prefix {
                    return true
                }
                if stripped.hasPrefix(prefix) {
                    let nextIndex = stripped.index(stripped.startIndex, offsetBy: prefix.count)
                    return stripped[nextIndex].isWhitespace
                }
                return false
            }
        }
        if !isSafePrefix { return false }

        if Self.hasUnsafeOperators(stripped) { return false }
        if Self.isDestructive(stripped) { return false }
        if Self.isSensitive(stripped) { return false }
        if Self.isInstall(stripped) { return false }
        if hasOutOfScopePath(stripped) { return false }

        // Mutating git operations are not safe
        if stripped.hasPrefix("git branch") {
            let tokens = stripped.split(separator: " ").map(String.init)
            if tokens.contains("-d") || tokens.contains("-D") || tokens.contains("-m") || tokens.contains("-M") || tokens.contains("--delete") || tokens.contains("--move") {
                return false
            }
        }
        if stripped.hasPrefix("git remote") {
            let tokens = stripped.split(separator: " ").map(String.init)
            if tokens.contains("add") || tokens.contains("remove") || tokens.contains("rm") || tokens.contains("set-url") || tokens.contains("rename") {
                return false
            }
        }
        if stripped.hasPrefix("git config") && !stripped.hasPrefix("git config --get") {
            return false
        }
        if stripped.hasPrefix("git tag") {
            let tokens = stripped.split(separator: " ").map(String.init)
            if tokens.contains("-d") || tokens.contains("--delete") || tokens.contains("-a") {
                return false
            }
        }

        // Guard find against destructive flags (-delete, -exec, -execdir, -ok, -okdir)
        if stripped.hasPrefix("find ") || stripped == "find" {
            let tokens = stripped.split(separator: " ").map(String.init)
            let unsafeFind = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fls", "-fprintf"]
            if tokens.contains(where: { unsafeFind.contains($0) }) {
                return false
            }
        }

        // Guard rg against mutating or unsafe flags
        if stripped.hasPrefix("rg ") || stripped == "rg" {
            let tokens = stripped.split(separator: " ").map(String.init)
            let unsafeRg = ["--replace", "-r", "--passthru", "--pre", "--search-zip"]
            if tokens.contains(where: { unsafeRg.contains($0) }) {
                return false
            }
        }

        // Verify resolved binary exists under system trusted dirs
        let binaryName = stripped.split(separator: " ").first.map(String.init) ?? ""
        if !binaryName.isEmpty && binaryName != "read_file" && binaryName != "write_file" && binaryName != "edit_file" {
            let trustedDirs = ["/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/"]
            if let whichPath = resolveWhich(binaryName) {
                if !trustedDirs.contains(where: { whichPath.hasPrefix($0) }) {
                    return false
                }
            }
        }

        return true
    }

    private func resolveWhich(_ binary: String) -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [binary]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            return nil
        }
        return nil
    }

    public func prompt(command: String, description: String, alwaysAllowKey: String? = nil) -> Bool {
        if isDefinitelySafe(command) {
            return true
        }

        if let key = alwaysAllowKey {
            let isAllowed = keysLock.withLock { alwaysAllowedKeys.contains(key) }
            if isAllowed {
                return true
            }
        }

        // In non-interactive mode, write_file and edit_file within scope that are neither
        // destructive nor sensitive are allowed by default (actual mutations are mechanically gated
        // by the --read-only flag in Executor).
        if command.hasPrefix("write_file ") || command.hasPrefix("edit_file ") {
            let isUnsafe = Self.isDestructive(command) || Self.isSensitive(command) || hasOutOfScopePath(command)
            if !isUnsafe && !interactive {
                return true
            }
        }

        // Non-interactive mode cannot prompt human
        if !interactive {
            return false
        }

        return Self.terminalLock.withLock {
            let cleanCmd = Self.sanitizeForTerminal(command)
            let cleanDesc = Self.sanitizeForTerminal(description)

            FileHandle.standardError.write(Data("\n⚠️ APPROVAL REQUIRED:\n".utf8))
            FileHandle.standardError.write(Data("  Description: \(cleanDesc)\n".utf8))
            FileHandle.standardError.write(Data("  Command:     \(cleanCmd)\n".utf8))

            if Self.isDestructive(command) {
                FileHandle.standardError.write(Data("  🚨 WARNING: Contains destructive operation pattern!\n".utf8))
            }
            if Self.isSensitive(command) {
                FileHandle.standardError.write(Data("  🔒 WARNING: Accesses sensitive/credential file path!\n".utf8))
            }
            if Self.isInstall(command) {
                FileHandle.standardError.write(Data("  ⚙️ WARNING: Modifies environment or installs packages!\n".utf8))
            }
            if hasOutOfScopePath(command) {
                FileHandle.standardError.write(Data("  🌐 WARNING: Accesses path outside designated scope!\n".utf8))
            }

            FileHandle.standardError.write(Data("[y] Allow once, [a] Always allow this tool/path, [n] Deny: ".utf8))

            guard let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }

            if line == "y" || line == "yes" {
                return true
            } else if line == "a" || line == "always" {
                if let key = alwaysAllowKey {
                    keysLock.withLock {
                        _ = alwaysAllowedKeys.insert(key)
                    }
                }
                return true
            }
            return false
        }
    }
}
