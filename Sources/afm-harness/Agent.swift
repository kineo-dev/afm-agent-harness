import Foundation
import FoundationModels

public final class Agent: @unchecked Sendable {
    public let sessionId: String
    public let scopeDir: String?
    public let readOnly: Bool
    public let interactive: Bool
    public let brainDir: String
    public let noTools: Bool
    public let executor: Executor

    private let systemPrompt: String
    private var session: LanguageModelSession
    private let startTime: Date
    public private(set) var lastError: Bool = false

    public struct Metrics: Codable, Sendable {
        public var apiCalls: Int = 0
        public var toolCalls: Int = 0
        public var wallSeconds: Double = 0.0
        public var forcedSynthesis: Bool = false
        public var localTier: String = ModelTier.baseline.rawValue
        public var triageDecision: String? = nil
        public var routedToAdvanced: Bool = false
        public var advancedRequestedButUnavailable: Bool = false
        public var clarificationRequested: Bool = false
    }

    public private(set) var metrics = Metrics()

    public let localTier: ModelTier

    public static let maxIterations = 50
    public static let forceSynthesisAt = 20

    // Only meaningfully different from the default on hosts where localTier == .advanced,
    // since that's the only case where the underlying model is actually the bigger tier.
    public static let advancedGenerationOptions = GenerationOptions(temperature: 0.2, maximumResponseTokens: 4096)

    public static let systemPromptTemplate = """
    You are an autonomous agent executing tasks on a macOS system using Apple's on-device Foundation Models.

    TASK SCOPE: {scope_dir}
    Do not perform directory exploration or read files outside this scope unless explicitly instructed.
    Do not install packages or modify the environment unless the task explicitly requires it.

    GROUNDING RULES — these override everything else:
    1. Base every answer on actual tool output when tool use is necessary to complete the task.
       If the task already provides all the information needed to answer directly in the prompt itself,
       or if you are explicitly instructed not to use any tools, answer directly without calling tools —
       do not call a tool just because a filename or path is mentioned in the prompt text.
       Never use training knowledge to fill in, guess, or extrapolate results when executing tools.
    2. If a tool returns empty output or an error, report that verbatim. Do NOT invent results.
    3. When reporting findings, quote the relevant portion of the tool output.
    4. If a command returns a non-zero exit code, report the error text exactly and stop.
    5. Think step by step. For destructive operations, state what you will do before calling the tool.
    6. Do not re-verify the same conclusion with repeated near-identical tool calls. Once you have
       enough evidence to answer, stop calling tools and write your final answer.
    7. If the task asks for a conclusion, judgment, or report as its deliverable, write it to a file
       with write_file (or edit_file) rather than only stating it in a plain-text reply.
    8. When reading files, prefer begin_line/end_line for anything that might be large (source code,
       logs, documents). Do not read_file a whole file speculatively; use search_files or grep to locate relevant sections first.
    9. To find TEXT inside files, use search_files (it searches file contents only, never file names). To read a file whose path you know, use read_file directly. To list files, use bash with ls or find.
    10. For edit_file and write_file, you may specify dry_run: true to preview diffs before applying.
    11. If a previous file modification was erroneous, call file_undo to restore the prior state.
    12. If instructions are ambiguous or critical choices must be made, call clarify with
        a concrete question and discrete options instead of guessing.
    """

    public static let readOnlyNotice = """

    READ-ONLY MODE: write_file and edit_file are disabled, and any bash command that is not a
    plain read-only command (ls/cat/grep/git status/etc.) will be blocked before execution.
    This is enforced mechanically, not just by instruction — do not attempt writes, edits, package
    installs, or state-changing commands; they will be rejected automatically.
    Rule 7 (write your conclusion to a file) does not apply in this mode since write_file and edit_file are not available in read-only sessions; state your conclusion directly in your final reply instead.
    """

    public init(
        sessionId: String? = nil,
        scopeDir: String? = nil,
        readOnly: Bool = false,
        interactive: Bool = true,
        brainDir: String? = nil,
        noTools: Bool = false
    ) {
        let sid = sessionId ?? UUID().uuidString
        self.sessionId = sid
        self.scopeDir = scopeDir
        self.readOnly = readOnly
        self.interactive = interactive
        self.brainDir = brainDir ?? "brain"
        self.noTools = noTools
        self.startTime = Date()
        self.localTier = ModelTier.detectLocalTier()
        self.metrics.localTier = self.localTier.rawValue

        let contextBudget = Executor.detectContextCharBudget()
        let exec = Executor(
            sessionId: sid,
            brainBaseDir: brainDir,
            scopeDir: scopeDir,
            readOnly: readOnly,
            interactive: interactive,
            contextCharBudget: contextBudget
        )
        self.executor = exec

        let prompt = Self.buildSystemPrompt(scopeDir: scopeDir ?? FileManager.default.currentDirectoryPath, readOnly: readOnly)
        self.systemPrompt = prompt
        self.session = LanguageModelSession(tools: [], instructions: prompt)
        self.session = makeSession()
    }

    private func makeSession() -> LanguageModelSession {
        if noTools {
            return LanguageModelSession(
                tools: [],
                instructions: systemPrompt
            )
        } else {
            let bash = BashTool(executor: executor)
            let readFile = ReadFileTool(executor: executor)
            let searchFiles = SearchFilesTool(executor: executor)
            let clarify = ClarifyTool(executor: executor)

            var tools: [any Tool] = [bash, readFile, searchFiles, clarify]
            if !readOnly {
                tools.append(WriteFileTool(executor: executor))
                tools.append(EditFileTool(executor: executor))
                tools.append(FileUndoTool(executor: executor))
            }

            return LanguageModelSession(
                tools: tools,
                instructions: systemPrompt
            )
        }
    }

    private func resetSession() {
        session = makeSession()
        executor.resetTurnBudget()
        executor.resetToolCallTracking()
    }

    private static func isContextOverflow(_ error: Error) -> Bool {
        if let genError = error as? LanguageModelSession.GenerationError {
            switch genError {
            case .exceededContextWindowSize:
                return true
            default:
                break
            }
        }
        let desc = error.localizedDescription.lowercased()
        return desc.contains("context window") || (desc.contains("maximum allowed is") && desc.contains("tokens"))
    }

    public static func buildSystemPrompt(scopeDir: String, readOnly: Bool) -> String {
        var prompt = systemPromptTemplate.replacingOccurrences(of: "{scope_dir}", with: scopeDir)
        if readOnly {
            prompt += readOnlyNotice
        }
        return prompt
    }

    public func getMetrics() -> Metrics {
        var m = self.metrics
        m.wallSeconds = round(Date().timeIntervalSince(startTime) * 100) / 100
        return m
    }

    private static let triageInstructions = """
    You are a routing classifier, not a task executor. Read the request below and classify how
    much reasoning effort it needs. Do not attempt the task itself, do not explain your reasoning.
    - "baseline": a routine, single-step, or narrowly-scoped request
    - "advanced": requires deep multi-step reasoning, large code/context synthesis, or open-ended judgment
    """

    private func triage(userInput: String) async -> ModelTier {
        let triageSession = LanguageModelSession(tools: [], instructions: Self.triageInstructions)
        do {
            let result = try await triageSession.respond(
                to: userInput,
                generating: TriageDecision.self,
                options: GenerationOptions(maximumResponseTokens: 16)
            )
            return result.content.resolvedTier
        } catch {
            // Triage is an optimization, never a gate — any failure here falls back to baseline.
            return .baseline
        }
    }

    public func run(userInput: String) async -> String {
        lastError = false
        executor.resetTurnBudget()
        executor.resetToolCallTracking()
        var currentPrompt = userInput
        var iterationCount = 0

        let triageTier = await triage(userInput: userInput)
        metrics.triageDecision = triageTier.rawValue
        var useAdvancedOptions = false
        if triageTier == .advanced {
            if localTier == .advanced {
                useAdvancedOptions = true
                metrics.routedToAdvanced = true
            } else {
                metrics.advancedRequestedButUnavailable = true
                FileHandle.standardError.write(Data("[triage: advanced handling requested, but this host only has '\(localTier.rawValue)' capability locally — continuing with baseline]\n".utf8))
            }
        }
        let responseOptions = useAdvancedOptions ? Self.advancedGenerationOptions : GenerationOptions()

        while iterationCount < Self.maxIterations {
            iterationCount += 1
            metrics.apiCalls += 1

            if iterationCount >= Self.forceSynthesisAt && !metrics.forcedSynthesis {
                metrics.forcedSynthesis = true
                FileHandle.standardError.write(Data("[forced synthesis: \(iterationCount) rounds reached — requesting final answer without tools]\n".utf8))
                currentPrompt = "STOP calling tools now. You have gathered enough information. Write your final answer based only on what you have already found."
            }

            do {
                let response = try await session.respond(to: currentPrompt, options: responseOptions)
                let text = response.content

                if executor.clarificationRequested {
                    metrics.clarificationRequested = true
                }

                // Check if any error occurred during tool execution within this turn
                if executor.lastWasError {
                    lastError = true
                    if !interactive {
                        executor.writeEscalation(
                            situation: "Tool error in non-interactive mode — stopping immediately.",
                            attempted: "Session turn with prompt: \(currentPrompt.prefix(100))",
                            error: "A tool execution returned an error condition during this step."
                        )
                    }
                }

                return text
            } catch {
                lastError = true
                let errStr = error.localizedDescription
                executor.writeEscalation(
                    situation: "LanguageModelSession error during respond()",
                    attempted: currentPrompt,
                    error: errStr
                )
                if let reason = executor.loopAbortReason {
                    resetSession()
                    FileHandle.standardError.write(Data("[tool loop aborted: \(reason) — session reset]\n".utf8))
                    return "Stopped: \(reason). The turn was aborted and the session was reset (conversation history cleared). File changes already applied are NOT rolled back (file_undo history is kept) — check file state before retrying. Retry with a narrower, more specific request; do not repeat the same tool call."
                }
                if Self.isContextOverflow(error) {
                    resetSession()
                    FileHandle.standardError.write(Data("[context overflow: session reset — conversation history cleared]\n".utf8))
                    return "Context window exceeded; the session was reset and prior conversation history is cleared. File changes already applied are NOT rolled back (file_undo history is kept) — check file state before retrying. Retry with a narrower request: smaller begin_line/end_line ranges and more specific search patterns."
                }
                return "Model session error: \(errStr)"
            }
        }

        lastError = true
        let limitMsg = "Iteration limit (\(Self.maxIterations)) reached. Stopping."
        executor.writeEscalation(situation: "Loop limit reached", attempted: userInput, error: limitMsg)
        return limitMsg
    }
}
