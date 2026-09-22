import Foundation

// MARK: - Old Session Cleanup

func cleanupOldSessions(brainBase: String, days: Int = 30) {
    let defaultBrainBase = URL(fileURLWithPath: "brain").standardized.path
    let targetBrainBase = URL(fileURLWithPath: brainBase).standardized.path

    // Only clean inside the trusted default brain directory
    guard targetBrainBase == defaultBrainBase else { return }

    let cutoff = Date().timeIntervalSince1970 - Double(days * 86400)
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: targetBrainBase) else { return }

    for entry in entries {
        let entryPath = URL(fileURLWithPath: targetBrainBase).appendingPathComponent(entry).path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entryPath, isDirectory: &isDir), isDir.boolValue else {
            continue
        }
        // Must be UUID format to avoid deleting unrelated dirs
        guard UUID(uuidString: entry) != nil else {
            continue
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: entryPath),
           let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
           mtime < cutoff {
            FileHandle.standardError.write(Data("Cleanup: removing session dir older than \(days)d: \(entryPath)\n".utf8))
            try? FileManager.default.removeItem(atPath: entryPath)
        }
    }
}

// MARK: - CLI Argument Parsing

struct CLIOptions {
    var prompt: String? = nil
    var scope: String = FileManager.default.currentDirectoryPath
    var readOnly: Bool = false
    var jsonOutput: Bool = false
    var brainDir: String = "brain"
    var noCleanup: Bool = false
    var noTools: Bool = false
}

func parseCommandLine() -> CLIOptions {
    var options = CLIOptions()
    let args = CommandLine.arguments
    var i = 1

    while i < args.count {
        let arg = args[i]
        switch arg {
        case "-p", "--prompt":
            if i + 1 < args.count {
                options.prompt = args[i + 1]
                i += 1
            }
        case "--scope":
            if i + 1 < args.count {
                options.scope = args[i + 1]
                i += 1
            }
        case "--read-only":
            options.readOnly = true
        case "--no-tools":
            options.noTools = true
        case "--json":
            options.jsonOutput = true
        case "--brain-dir":
            if i + 1 < args.count {
                options.brainDir = args[i + 1]
                i += 1
            }
        case "--no-cleanup":
            options.noCleanup = true
        case "-h", "--help":
            print("""
            Usage: afm-harness [options]

            Options:
              -p, --prompt <text>   Execute a single prompt non-interactively and exit
              --scope <path>        Scope directory limit for tool operations
              --read-only           Block all file modifications and unsafe commands mechanically
              --no-tools            Run session without tools attached (pure reasoning mode)
              --json                Output final result as JSON envelope (--prompt mode only)
              --brain-dir <dir>     Base directory for session brain logs (default: brain)
              --no-cleanup          Skip automatic 30-day session directory cleanup on startup
              -h, --help            Show this help message
            """)
            exit(0)
        default:
            break
        }
        i += 1
    }
    return options
}

// MARK: - Main Execution

let options = parseCommandLine()
let sessionId = UUID().uuidString
let scopeDir = URL(fileURLWithPath: options.scope).standardized.path
let brainDir = URL(fileURLWithPath: options.brainDir).standardized.path

if !options.noCleanup && !options.readOnly {
    cleanupOldSessions(brainBase: brainDir)
}

let interactive = (options.prompt == nil)
let agent = Agent(
    sessionId: sessionId,
    scopeDir: scopeDir,
    readOnly: options.readOnly,
    interactive: interactive,
    brainDir: brainDir,
    noTools: options.noTools
)

let sessionBrainDir = URL(fileURLWithPath: brainDir).appendingPathComponent(sessionId).path

if let promptText = options.prompt {
    // Non-interactive mode
    let result = await agent.run(userInput: promptText)
    let isError = agent.lastError
    let metrics = agent.getMetrics()

    if options.jsonOutput {
        struct JSONEnvelope: Codable {
            let ok: Bool
            let answer: String
            let session: String
            let brain_dir: String
            let metrics: Agent.Metrics
        }
        let env = JSONEnvelope(
            ok: !isError,
            answer: result,
            session: sessionId,
            brain_dir: sessionBrainDir,
            metrics: metrics
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(env), let jsonStr = String(data: data, encoding: .utf8) {
            print(jsonStr)
        }
    } else {
        print(result)
    }

    if let metricsData = try? JSONEncoder().encode(metrics),
       let metricsStr = String(data: metricsData, encoding: .utf8) {
        FileHandle.standardError.write(Data("{\"metrics\": \(metricsStr)}\n".utf8))
    }

    exit(isError ? 1 : 0)
} else {
    // Interactive REPL mode
    print("Apple FoundationModels Agent (AFM 3 Core) | Session: \(sessionId)")
    print("Local tier: \(agent.localTier.rawValue)")
    print("Scope: \(scopeDir)")
    print("Brain: \(sessionBrainDir)")
    if options.readOnly {
        print("Mode:  READ-ONLY")
    }
    print("Type your instruction. Ctrl+C or Ctrl+D to exit.\n")

    while true {
        print("> ", terminator: "")
        fflush(stdout)
        guard let line = readLine() else {
            print("\nBye.")
            break
        }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { continue }

        let result = await agent.run(userInput: trimmed)
        print("\n\(result)\n")
    }

    let metrics = agent.getMetrics()
    if let metricsData = try? JSONEncoder().encode(metrics),
       let metricsStr = String(data: metricsData, encoding: .utf8) {
        FileHandle.standardError.write(Data("{\"metrics\": \(metricsStr)}\n".utf8))
    }
}
