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
            self.scopeDir = Self.canonicalPath(URL(fileURLWithPath: dir))
        } else {
            self.scopeDir = nil
        }
        self.interactive = interactive
    }

    /// Pseudo-commands the file tools pass to `prompt`/`isDefinitelySafe` (e.g. "read_file /abs/path").
    /// They are not shell commands and must never reach bash.
    public static let internalCommands: [String] = ["read_file", "write_file", "edit_file"]

    /// Splits an internal pseudo-command. The path is everything after the first space, so
    /// paths containing spaces stay intact.
    public static func parseInternalCommand(_ command: String) -> (name: String, path: String)? {
        for name in internalCommands where command.hasPrefix(name + " ") {
            return (name, String(command.dropFirst(name.count + 1)))
        }
        return nil
    }

    /// Resolves symlinks in the longest existing ancestor and re-appends the not-yet-existing tail,
    /// so a path to a new file under a symlinked directory is judged by where it really lands.
    public static func canonicalPath(_ url: URL) -> String {
        var existing = url.standardized
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var base = (try? existing.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? existing.path
        for component in tail {
            base = (base as NSString).appendingPathComponent(component)
        }
        return base
    }

    /// Whitespace-split words with shell quoting/escaping removed, so `'-exec'` and `-\exec`
    /// are compared as the program will see them (`-exec`).
    private static func shellWords(_ command: String) -> [String] {
        command.split { $0.isWhitespace }.map { word in
            String(word.filter { $0 != "'" && $0 != "\"" && $0 != "\\" })
        }
    }

    private static func isShortFlagBundle(_ token: String, containingAnyOf letters: String) -> Bool {
        token.hasPrefix("-") && !token.hasPrefix("--") && token.dropFirst().contains { letters.contains($0) }
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

    /// Some safe-prefix commands can still write a file: `sort -o FILE` / `--output=FILE`,
    /// `git log/diff/show --output=FILE`, and `uniq IN OUT` (second positional is an output file).
    public static func hasHiddenWriteFlag(_ command: String) -> Bool {
        let tokens = shellWords(command)
        guard let first = tokens.first else { return false }
        let cmd = first.split(separator: "/").last.map(String.init) ?? first
        let args = Array(tokens.dropFirst())
        switch cmd {
        case "sort":
            return args.contains { tok in
                if tok == "--output" || tok.hasPrefix("--output=") { return true }
                // --compress-program runs an arbitrary program
                if tok.hasPrefix("--compress-program") { return true }
                // short flag or bundle containing 'o' (e.g. -o, -ro, -oFILE)
                return isShortFlagBundle(tok, containingAnyOf: "o")
            }
        case "git":
            guard let sub = args.first, ["log", "diff", "show"].contains(sub) else { return false }
            return args.dropFirst().contains { $0 == "--output" || $0.hasPrefix("--output=") }
        case "uniq":
            return args.filter { !$0.hasPrefix("-") }.count >= 2
        case "tree":
            // tree -o FILE writes the listing to FILE
            return args.contains { isShortFlagBundle($0, containingAnyOf: "o") }
        case "file":
            // file -C compiles a magic file next to the input
            return args.contains { $0 == "--compile" || isShortFlagBundle($0, containingAnyOf: "C") }
        default:
            return false
        }
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

    private func isOutOfScope(path token: String) -> Bool {
        guard let scope = self.scopeDir, !scope.isEmpty else { return false }
        let scopeUrl = URL(fileURLWithPath: scope).standardized
        let scopeCanonical = Self.canonicalPath(scopeUrl)
        let scopePrefix = scopeCanonical.hasSuffix("/") ? scopeCanonical : scopeCanonical + "/"

        let expanded = NSString(string: token).expandingTildeInPath
        let candidateUrl = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : scopeUrl.appendingPathComponent(expanded)
        let candidateCanonical = Self.canonicalPath(candidateUrl)
        return candidateCanonical != scopeCanonical && !candidateCanonical.hasPrefix(scopePrefix)
    }

    public func hasOutOfScopePath(_ command: String) -> Bool {
        guard let scope = self.scopeDir, !scope.isEmpty else { return false }
        // Internal pseudo-commands carry exactly one path, possibly containing spaces.
        if let internalCommand = Self.parseInternalCommand(command) {
            return isOutOfScope(path: internalCommand.path)
        }
        return Self.tokenizeForPaths(command).contains { isOutOfScope(path: $0) }
    }

    public func isDefinitelySafe(_ command: String) -> Bool {
        // Internal read_file pseudo-command: safe iff the path is non-sensitive and in scope.
        // (Never reaches bash: Executor.runBash rejects these names.)
        if let internalCommand = Self.parseInternalCommand(command) {
            return internalCommand.name == "read_file"
                && !Self.isSensitive(internalCommand.path)
                && !hasOutOfScopePath(command)
        }

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
        if Self.hasHiddenWriteFlag(stripped) { return false }
        if Self.isDestructive(stripped) { return false }
        if Self.isSensitive(stripped) { return false }
        if Self.isInstall(stripped) { return false }
        if hasOutOfScopePath(stripped) { return false }

        let words = Self.shellWords(stripped)

        // Mutating git operations are not safe
        if words.first == "git", words.count >= 2 {
            let sub = words[1]
            let gitArgs = Array(words.dropFirst(2))
            let positional = gitArgs.filter { !$0.hasPrefix("-") }
            switch sub {
            case "branch":
                let listing = ["--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
                let mutating = ["--delete", "--move", "--copy", "--force", "--set-upstream-to", "--unset-upstream", "--edit-description"]
                if gitArgs.contains(where: { mutating.contains($0) || $0.hasPrefix("--set-upstream-to=") || Self.isShortFlagBundle($0, containingAnyOf: "dDmMcCuf") }) {
                    return false
                }
                // `git branch NAME` creates a branch
                if !positional.isEmpty && !gitArgs.contains(where: { listing.contains($0) }) { return false }
            case "tag":
                let listing = ["--list", "-l", "--contains", "--no-contains", "--merged", "--no-merged", "--points-at"]
                let mutating = ["--delete", "--annotate", "--sign", "--local-user", "--force", "--message", "--file"]
                if gitArgs.contains(where: { mutating.contains($0) || Self.isShortFlagBundle($0, containingAnyOf: "dasufmF") }) {
                    return false
                }
                // `git tag NAME` creates a tag
                if !positional.isEmpty && !gitArgs.contains(where: { listing.contains($0) || ($0.hasPrefix("-l")) }) { return false }
            case "remote":
                // only `git remote [-v]`, `show` and `get-url` are read-only (add/remove/rename/set-url/update/prune are not)
                if let remoteSub = positional.first, !["show", "get-url"].contains(remoteSub) { return false }
            case "config":
                let mutating = ["--add", "--unset", "--unset-all", "--replace-all", "--edit", "-e", "--rename-section", "--remove-section"]
                if !stripped.hasPrefix("git config --get") || gitArgs.contains(where: { mutating.contains($0) }) { return false }
            default:
                break
            }
        }

        // Guard find against destructive flags (-delete, -exec, -execdir, -ok, -okdir, -fprint*)
        if words.first == "find" {
            let unsafeFind = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fls", "-fprintf"]
            if words.contains(where: { unsafeFind.contains($0) }) {
                return false
            }
        }

        // Guard rg against flags that run programs (--pre, --hostname-bin) or rewrite output
        if words.first == "rg" {
            let unsafeRg = ["--replace", "-r", "--passthru", "--search-zip"]
            if words.contains(where: { unsafeRg.contains($0) || $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") || $0.hasPrefix("--replace=") }) {
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
        if let internalCommand = Self.parseInternalCommand(command), internalCommand.name != "read_file" {
            let isUnsafe = Self.isDestructive(internalCommand.path) || Self.isSensitive(internalCommand.path) || hasOutOfScopePath(command)
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
