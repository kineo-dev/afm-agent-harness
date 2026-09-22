import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class Executor: @unchecked Sendable {
    public let sessionId: String
    public let brainDir: String
    public let scopeDir: String?
    public let readOnly: Bool
    public let interactive: Bool
    public let approval: Approval

    public private(set) var lastWasError: Bool = false

    public static let bashTimeout: TimeInterval = 60.0
    public static let maxBashOutputBytes: Int = 5 * 1024 * 1024 // 5MB
    public static let maxReadFileBytes: off_t = 50 * 1024 * 1024 // 50MB
    public static let readFileMaxLines: Int = 500
    public static let maxFullReadFileChars: Int = 3000

    public static let blockedPathPrefixes: [String] = [
        "/etc/", "/sys/", "/proc/", "/boot/", "/dev/",
        "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/",
        "/lib/", "/lib64/", "/usr/lib/"
    ]

    public init(sessionId: String? = nil, brainBaseDir: String? = nil, scopeDir: String? = nil, readOnly: Bool = false, interactive: Bool = true) {
        self.sessionId = sessionId ?? UUID().uuidString
        let base = brainBaseDir ?? "brain"
        self.brainDir = URL(fileURLWithPath: base).appendingPathComponent(self.sessionId).path
        self.scopeDir = scopeDir.flatMap { dir in
            (try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? URL(fileURLWithPath: dir).standardized.path
        }
        self.readOnly = readOnly
        self.interactive = interactive
        self.approval = Approval(scopeDir: self.scopeDir, interactive: interactive)

        ensureDirectoryPermissions(self.brainDir, mode: 0o700)
    }

    private func ensureDirectoryPermissions(_ path: String, mode: mode_t) {
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        chmod(path, mode)
    }

    public func writeEscalation(situation: String, attempted: String, error: String) {
        ensureDirectoryPermissions(brainDir, mode: 0o700)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: brainDir)) ?? []
        var maxNum = 0
        for file in files {
            if file.hasPrefix("escalation_report_") && file.hasSuffix(".md") {
                let numPart = file.dropFirst("escalation_report_".count).dropLast(".md".count)
                if let num = Int(numPart), num > maxNum {
                    maxNum = num
                }
            }
        }
        let nextNum = maxNum + 1
        let reportFilename = String(format: "escalation_report_%03d.md", nextNum)
        let reportPath = URL(fileURLWithPath: brainDir).appendingPathComponent(reportFilename).path

        let isoDate = ISO8601DateFormatter().string(from: Date())
        let content = """
        # Escalation Report

        **Timestamp**: \(isoDate)

        ## Situation
        \(situation)

        ## Attempted
        \(attempted)

        ## Error
        \(error)

        """

        try? content.write(toFile: reportPath, atomically: true, encoding: .utf8)
        chmod(reportPath, 0o600)
        FileHandle.standardError.write(Data("\n⚠️ Escalation: \(reportPath)\n".utf8))
    }

    public func appendResultLog(toolName: String, label: String, output: String) {
        ensureDirectoryPermissions(brainDir, mode: 0o700)
        let logPath = URL(fileURLWithPath: brainDir).appendingPathComponent("results.log").path
        let isoDate = ISO8601DateFormatter().string(from: Date())
        let entry = """
        ---
        [\(isoDate)] \(toolName): \(label)
        \(output)

        """

        if !FileManager.default.fileExists(atPath: logPath) {
            try? entry.write(toFile: logPath, atomically: true, encoding: .utf8)
            chmod(logPath, 0o600)
        } else if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            try? handle.close()
        }
    }

    public func validatePath(_ path: String) -> (valid: Bool, resolvedPath: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (false, "Path is empty.")
        }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let baseUrl = URL(fileURLWithPath: scopeDir ?? FileManager.default.currentDirectoryPath)
        let resolvedUrl = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : baseUrl.appendingPathComponent(expanded)
        let standardized = resolvedUrl.standardized
        let canonical = (try? standardized.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? standardized.path

        for prefix in Self.blockedPathPrefixes {
            let prefixUrl = URL(fileURLWithPath: prefix).standardized
            let resolvedPrefix = (try? prefixUrl.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? prefixUrl.path
            if canonical == resolvedPrefix || canonical.hasPrefix(resolvedPrefix.hasSuffix("/") ? resolvedPrefix : resolvedPrefix + "/") {
                return (false, "Path blocked: \(canonical) is under system directory \(prefix)")
            }
        }
        return (true, canonical)
    }

    private func truncateOutput(_ text: String, head: Int = 20, tail: Int = 10) -> String {
        let lines = text.components(separatedBy: "\n")
        if lines.count <= head + tail {
            return text
        }
        let omitted = lines.count - head - tail
        let keptHead = lines.prefix(head)
        let keptTail = lines.suffix(tail)
        return (keptHead + ["... [\(omitted) lines omitted] ..."] + keptTail).joined(separator: "\n")
    }

    private func isInformationalExit(command: String, returnCode: Int32) -> Bool {
        let stripped = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let chainOps = ["&&", "||", ";", "|", "\n", "\r", "&"]
        if chainOps.contains(where: { stripped.contains($0) }) {
            return false
        }
        let parts = stripped.split { $0.isWhitespace }.map(String.init)
        guard var firstWord = parts.first?.split(separator: "/").last.map(String.init) else {
            return false
        }
        if firstWord == "env" && parts.count > 1 {
            firstWord = parts[1].split(separator: "/").last.map(String.init) ?? ""
        }

        if ["grep", "egrep", "fgrep", "diff", "cmp"].contains(firstWord) {
            return returnCode == 1
        }
        if firstWord == "test" || stripped.hasPrefix("[") {
            return returnCode == 0 || returnCode == 1
        }
        return false
    }

    // MARK: - Tool: bash

    public func runBash(command: String, description: String) -> String {
        lastWasError = false

        if readOnly && !approval.isDefinitelySafe(command) {
            lastWasError = true
            let msg = "Command blocked: agent is running in --read-only mode. This command was blocked. Use a safe read-only alternative like ls/find/rg/git status, or explain to the user why elevated access is needed."
            appendResultLog(toolName: "bash", label: command, output: msg)
            return msg
        }

        if !approval.prompt(command: command, description: description) {
            lastWasError = true
            let msg = "Command denied. This command was blocked. Use a safe read-only alternative like ls/find/rg/git status, or explain to the user why elevated access is needed."
            appendResultLog(toolName: "bash", label: command, output: msg)
            return msg
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", command]

        if let cwd = scopeDir, FileManager.default.fileExists(atPath: cwd) {
            proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        // Minimal safe environment variables
        let allowedEnv = ["PATH", "HOME", "TERM", "USER", "LANG", "LC_ALL"]
        var env: [String: String] = [:]
        for key in allowedEnv {
            if let val = ProcessInfo.processInfo.environment[key] {
                env[key] = val
            }
        }
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            lastWasError = true
            let errStr = "Failed to spawn bash process: \(error.localizedDescription)"
            writeEscalation(situation: "Bash spawn failed", attempted: command, error: errStr)
            appendResultLog(toolName: "bash", label: command, output: errStr)
            return errStr
        }

        // Timeout enforcement
        let pid = proc.processIdentifier
        let timer = DispatchSource.makeTimerSource()
        var timedOut = false
        timer.schedule(deadline: .now() + Self.bashTimeout)
        timer.setEventHandler {
            timedOut = true
            kill(pid, SIGKILL)
        }
        timer.resume()

        proc.waitUntilExit()
        timer.cancel()

        if timedOut {
            lastWasError = true
            let out = "Command timed out after \(Int(Self.bashTimeout)) seconds."
            writeEscalation(situation: "Bash command timed out", attempted: command, error: out)
            appendResultLog(toolName: "bash", label: command, output: out)
            return out
        }

        var outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        var errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        if outData.count > Self.maxBashOutputBytes {
            outData = outData.prefix(Self.maxBashOutputBytes)
        }
        if errData.count > Self.maxBashOutputBytes {
            errData = errData.prefix(Self.maxBashOutputBytes)
        }

        var stdoutStr = String(decoding: outData, as: UTF8.self)
        let stderrStr = String(decoding: errData, as: UTF8.self)

        if !stderrStr.isEmpty {
            stdoutStr += "\nSTDERR: \(stderrStr)"
        }

        let exitCode = proc.terminationStatus
        if exitCode != 0 {
            stdoutStr += "\nExit code: \(exitCode)"
            if !isInformationalExit(command: command, returnCode: exitCode) {
                lastWasError = true
            }
        }

        let fullOutput = stdoutStr.isEmpty ? "(no output)" : stdoutStr
        appendResultLog(toolName: "bash", label: command, output: fullOutput)
        return truncateOutput(fullOutput)
    }

    // MARK: - Tool: read_file

    public func readFile(path: String, beginLine: Int? = nil, endLine: Int? = nil) -> String {
        lastWasError = false
        let (valid, resolved) = validatePath(path)
        if !valid {
            lastWasError = true
            let out = "Read blocked: \(resolved)"
            appendResultLog(toolName: "read_file", label: path, output: out)
            return out
        }

        let desc = "read from \(resolved)"
        if !approval.prompt(command: "read_file \(resolved)", description: desc, alwaysAllowKey: "read_file \(resolved)") {
            lastWasError = true
            let out = "Read denied by user."
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }

        let flags = O_RDONLY | O_NONBLOCK | O_NOFOLLOW
        let fd = open(resolved, flags)
        if fd < 0 {
            lastWasError = true
            let err = String(cString: strerror(errno))
            let out = "Read blocked: cannot open \(resolved): \(err)"
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }
        defer { close(fd) }

        var st = stat()
        if fstat(fd, &st) != 0 {
            lastWasError = true
            let out = "Read blocked: fstat failed on \(resolved)"
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }

        if (st.st_mode & S_IFMT) != S_IFREG {
            lastWasError = true
            let out = "Read blocked: \(resolved) is not a regular file."
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }

        if st.st_size > Self.maxReadFileBytes {
            lastWasError = true
            let out = "Read blocked: \(resolved) exceeds maximum size limit (\(st.st_size) bytes > \(Self.maxReadFileBytes) bytes)."
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = handle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            lastWasError = true
            let out = "Error reading file: \(resolved) is not valid UTF-8."
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }

        let lines = content.components(separatedBy: "\n")
        let total = lines.count

        // Pre-check: guard against context overflow on 4k models when no line range is specified
        if beginLine == nil && endLine == nil && content.count > Self.maxFullReadFileChars {
            lastWasError = true
            let out = "File too large (\(content.count) chars, \(total) lines) to read in full — retry with begin_line/end_line to read a smaller slice, or use grep to find the relevant section first."
            appendResultLog(toolName: "read_file", label: resolved, output: out)
            return out
        }

        let finalResult: String
        if let b = beginLine, let e = endLine {
            let start = max(1, b)
            let stop = min(total, e)
            if start > stop {
                lastWasError = true
                let out = "Read failed: begin_line (\(start)) is after end_line (\(stop)). File has \(total) lines."
                appendResultLog(toolName: "read_file", label: resolved, output: out)
                return out
            }
            let slice = lines[(start - 1)..<stop]
            finalResult = "[lines \(start)-\(stop) of \(total) total]\n" + slice.joined(separator: "\n")
        } else if total > Self.readFileMaxLines {
            let head = lines.prefix(Self.readFileMaxLines)
            finalResult = "[showing first \(Self.readFileMaxLines) of \(total) lines; pass begin_line and end_line to view remaining content]\n" + head.joined(separator: "\n")
        } else {
            finalResult = content
        }

        appendResultLog(toolName: "read_file", label: resolved, output: "[ok: \(finalResult.count) chars]")
        return finalResult
    }

    // MARK: - Tool: write_file

    public func writeFile(path: String, content: String) -> String {
        lastWasError = false
        if readOnly {
            lastWasError = true
            let out = "write_file blocked: agent is running in --read-only mode."
            appendResultLog(toolName: "write_file", label: path, output: out)
            return out
        }

        let (valid, resolved) = validatePath(path)
        if !valid {
            lastWasError = true
            let out = "Write blocked: \(resolved)"
            appendResultLog(toolName: "write_file", label: path, output: out)
            return out
        }

        let desc = "write to \(resolved) (\(content.count) chars)"
        if !approval.prompt(command: "write_file \(resolved)", description: desc) {
            lastWasError = true
            let out = "Write denied by user."
            appendResultLog(toolName: "write_file", label: resolved, output: out)
            return out
        }

        let parentDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        ensureDirectoryPermissions(parentDir, mode: 0o755)

        // Atomic write via temporary file
        let tempUrl = URL(fileURLWithPath: parentDir).appendingPathComponent(".tmp_\(UUID().uuidString)")
        do {
            try content.write(to: tempUrl, atomically: true, encoding: .utf8)
            let flags = O_WRONLY | O_NOFOLLOW
            let fd = open(tempUrl.path, flags)
            if fd >= 0 {
                close(fd)
            }
            if FileManager.default.fileExists(atPath: resolved) {
                try FileManager.default.removeItem(atPath: resolved)
            }
            try FileManager.default.moveItem(atPath: tempUrl.path, toPath: resolved)
        } catch {
            try? FileManager.default.removeItem(atPath: tempUrl.path)
            lastWasError = true
            let out = "Error writing file: \(error.localizedDescription)"
            appendResultLog(toolName: "write_file", label: resolved, output: out)
            return out
        }

        let out = "Successfully wrote \(content.count) chars to \(resolved)"
        appendResultLog(toolName: "write_file", label: resolved, output: out)
        return out
    }

    // MARK: - Tool: edit_file

    public func editFile(path: String, oldString: String, newString: String) -> String {
        lastWasError = false
        if readOnly {
            lastWasError = true
            let out = "edit_file blocked: agent is running in --read-only mode."
            appendResultLog(toolName: "edit_file", label: path, output: out)
            return out
        }

        if oldString.isEmpty {
            lastWasError = true
            let out = "Edit rejected: old_string cannot be empty."
            appendResultLog(toolName: "edit_file", label: path, output: out)
            return out
        }

        let (valid, resolved) = validatePath(path)
        if !valid {
            lastWasError = true
            let out = "Edit blocked: \(resolved)"
            appendResultLog(toolName: "edit_file", label: path, output: out)
            return out
        }

        let desc = "edit \(resolved): replace '\(oldString.prefix(40))' with '\(newString.prefix(40))'"
        if !approval.prompt(command: "edit_file \(resolved)", description: desc) {
            lastWasError = true
            let out = "Edit denied by user."
            appendResultLog(toolName: "edit_file", label: resolved, output: out)
            return out
        }

        guard let existingData = FileManager.default.contents(atPath: resolved),
              let existingContent = String(data: existingData, encoding: .utf8) else {
            lastWasError = true
            let out = "Error editing file: cannot read \(resolved) as UTF-8."
            appendResultLog(toolName: "edit_file", label: resolved, output: out)
            return out
        }

        if !existingContent.contains(oldString) {
            lastWasError = true
            let out = "Edit failed: old_string was not found in \(resolved)."
            appendResultLog(toolName: "edit_file", label: resolved, output: out)
            return out
        }

        let occurrences = existingContent.components(separatedBy: oldString).count - 1
        if occurrences > 1 {
            lastWasError = true
            let out = "Edit failed: old_string matches multiple locations (\(occurrences) occurrences). Must be unique."
            appendResultLog(toolName: "edit_file", label: resolved, output: out)
            return out
        }

        // Backup existing file to .bak
        let backupPath = resolved + ".bak"
        try? FileManager.default.copyItem(atPath: resolved, toPath: backupPath)

        let updatedContent = existingContent.replacingOccurrences(of: oldString, with: newString)

        let parentDir = URL(fileURLWithPath: resolved).deletingLastPathComponent().path
        let tempUrl = URL(fileURLWithPath: parentDir).appendingPathComponent(".tmp_edit_\(UUID().uuidString)")
        do {
            try updatedContent.write(to: tempUrl, atomically: true, encoding: .utf8)
            try FileManager.default.removeItem(atPath: resolved)
            try FileManager.default.moveItem(atPath: tempUrl.path, toPath: resolved)
        } catch {
            try? FileManager.default.removeItem(atPath: tempUrl.path)
            lastWasError = true
            let out = "Error writing edit: \(error.localizedDescription)"
            appendResultLog(toolName: "edit_file", label: resolved, output: out)
            return out
        }

        let out = "Successfully edited \(resolved) (backup kept at \(backupPath))"
        appendResultLog(toolName: "edit_file", label: resolved, output: out)
        return out
    }
}
