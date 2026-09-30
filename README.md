# AFM Agent Harness (`afm-harness`)

An autonomous on-device Agent-in-Agent CLI harness built in Swift, powered by Apple's on-device **AFM 3 Core** model via the **FoundationModels** framework.

This project serves as the lightweight local "hands and feet" worker agent for higher-level orchestrators (such as Claude Code), executing shell tasks, file inspections, and edits directly on macOS with zero cloud API costs, complete privacy, and zero network calls.

---

## Important System Requirements & Constraints

> [!IMPORTANT]
> **macOS & Apple Silicon Only**: This project can **ONLY** be compiled and executed on an Apple Silicon Mac running macOS 26 (Tahoe) or later with Apple Intelligence / FoundationModels framework support.
>
> Development and Git tracking can be hosted on a central development machine or server, while compilation and runtime testing must be performed directly on an Apple Silicon Mac.

> [!NOTE]
> Apple Intelligence must be enabled on the Mac (System Settings, Apple Intelligence and Siri); otherwise runs fail with the error Apple Intelligence is not enabled.

---

## Architectural Comparison: Native On-Device vs. Cloud Python Harness

While `afm-agent-harness` mirrors the proven security and operational separation of concerns established in comparable cloud/local Python agent harnesses, it adapts the architecture to Apple's modern native AI stack:

| Dimension | Cloud/Local Python Harness | `afm-agent-harness` (This Project) |
| :--- | :--- | :--- |
| **Target Runtime** | Linux / macOS (Python 3.10+) | macOS only (Apple Silicon, Swift 6.0) |
| **Inference Engine** | Remote Cloud APIs or Local Ollama | Apple On-Device AFM 3 Core (`FoundationModels`) |
| **Network & Privacy** | Requires network for Cloud APIs | 100% offline, local-only, zero API bills |
| **Tool Calling Mechanism**| Hand-rolled JSON parsing & schema looping | Native typed `Tool` protocol conformance via `LanguageModelSession` |
| **Structured Output** | Prompt engineering + raw JSON parsing | Native `Generable` schema-guided decoding |
| **Safety Scoping** | Python approval gates + subprocess sandbox | Native Swift `Approval` + `Process` execution sandbox |

---

## Model Capabilities & Limitations

On Apple Silicon (M1, 16GB, macOS 27.0):

- **Tool Calling / Function Calling**: Executed reliably via the `Tool` protocol with sub-2s latency and zero hallucination for required inspection tools.
- **Structured Output (`Generable`)**: Schema-guided generation provides 100% typed integrity without JSON parsing exceptions.
- **Multi-turn Context Retention**: Successfully preserved multi-step context across multi-turn reasoning and tool-execution turns.
- **Safe Boundary Awareness**: Reliably declined real-time dynamic queries (e.g. current live weather) instead of hallucinating answers.
- **Pure Code Reasoning via `--no-tools`**:
  - *Single-function refactoring*: Accurately performed targeted refactorings (e.g. replacing `str.split()` with `shlex.split()` and adding imports) without touching unrelated code.
  - *Complex multi-part edits*: Struggles with compound instructions requiring logic removal/relaxation (e.g. removing `html.escape` across multiple call sites while retaining table-cell pipe escaping); the model demonstrates a strong bias toward preserving existing safety/robustness logic against explicit removal instructions.
- **Reflexive Tool-Calling**: When tools are registered in a session, the model reflexively invokes tools (like `read_file`) upon encountering file paths in prompt text, even under explicit negative instructions ("Do not use tools"). The `--no-tools` mode exists as an architectural separation to enable pure code-reasoning without tool interference.
- **Context Window Budget**: The safe full-file read limit scales with the detected on-device model tier -- approximately 3,000 characters on baseline hardware (~4096-token window) and up to ~7,000 characters on advanced-tier hardware. Reads exceeding the active budget, whether requested in full or via begin_line/end_line, are rejected with guidance to narrow the range or use search_files. Tool output across bash, read_file, and search_files is additionally capped by a cumulative per-turn budget, and on context overflow the session is reset and an actionable message is returned. Identical tool calls repeated three times, or more than 15 tool calls in one turn, abort the turn with an explanatory message.

---

## Model Tier Detection & Triage

`SystemLanguageModel.default` resolves to whichever capability tier (baseline 4096-token
context window or larger advanced window) the OS decides is appropriate for the current Mac's
hardware, and this harness never dispatches work to another machine.
On startup, `Agent` calls `ModelTier.detectLocalTier()` once to record which tier the local host
actually has (visible in the interactive banner and in `metrics.local_tier`).

Every call to `Agent.run(userInput:)` first runs a small schema-constrained triage classification
(`TriageDecision`, via a separate throwaway `LanguageModelSession` with no tools) asking whether the
request looks routine (`baseline`) or needs deep multi-step reasoning (`advanced`). The outcome only
changes behavior when the *local* tier is actually `advanced`: in that case generation runs with
lower temperature and a larger token budget (`Agent.advancedGenerationOptions`). On a baseline-only
host (e.g. an M1 Mac), an `advanced` triage verdict is logged (`metrics.advanced_requested_but_unavailable`)
and the request is still handled locally at baseline effort — there is no cross-host fallback.

---

## Project Structure

```
afm-agent-harness/
├── Package.swift               # Swift Package Manager manifest (executable target 'afm-harness')
├── README.md                   # Capabilities, architecture, and usage reference
└── Sources/
    └── afm-harness/
        ├── main.swift          # CLI argument parser, cleanup routines, execution runner
        ├── Agent.swift         # LanguageModelSession orchestrator, tool loop, forced synthesis
        ├── Executor.swift      # Sandboxed bash/read/write/edit implementations & brain logging
        ├── Approval.swift      # SAFE_PREFIXES auto-approval, shell operator inspection, scope gates
        ├── Tools.swift         # FoundationModels Tool protocol definitions for all built-in tools
        └── Triage.swift        # ModelTier detection and baseline/advanced triage classifier
```

---

## Core Security Posture

`afm-harness` implements comprehensive defense-in-depth:

1. **Auto-Approval (`SAFE_PREFIXES`)**: Read-only inspection commands (`ls`, `cat`, `grep`, `git status`, `git diff`, `df`, `free`, etc.) are approved immediately without prompting.
2. **Operator & Injection Suppression**: Chaining (`&&`, `||`, `;`), redirection (`>`, `>>`, `<`), command substitution (`$()`, `` ` ``), parameter expansion (`${}`), and ANSI-C quoting (`$'...'`) outside single quotes are detected, disabling auto-approval.
3. **Restricted Child Environment**: `Process` child environments are stripped of parent secrets, retaining only minimal standard variables (`PATH`, `HOME`, `TERM`, `USER`, `LANG`, `LC_ALL`).
4. **Symlink / TOCTOU Protection**: File operations employ `O_NOFOLLOW` and `stat` validation to prevent symlink traversal and FIFO hangs.
5. **Atomic Writes**: File writes and edits write to temporary files before atomically replacing target files, accompanied by `.bak` backup retention.
6. **Execution Limits**: Subprocess execution defaults to a 60-second timeout, kills process groups with `SIGKILL` on timeout, and truncates outputs exceeding 5MB.
7. **Brain Session Directory**: Logs and failure escalation reports are saved to `brain/<session-uuid>/` with restricted permissions (`0700` directory, `0600` files).

---

## Built-in Tools

afm-harness registers the following tools with the LanguageModelSession:

| Tool | Purpose | Key Arguments |
| :--- | :--- | :--- |
| `bash` | Execute a shell command under Approval gating | `command`, `description` |
| `read_file` | Read a file, optionally scoped to a line range | `path`, `begin_line`, `end_line` |
| `write_file` | Atomically create or overwrite a file | `path`, `content`, `dry_run` |
| `edit_file` | Replace a unique string in a file, atomically with backup | `path`, `old_string`, `new_string`, `dry_run` |
| `search_files` | Search inside file contents by regex or substring (does not match file names), with an optional filename glob, without spawning a shell | `pattern`, `path`, `glob` |
| `list_files` | List files and folders in a directory (shallow by default, optional recursion and glob), without spawning a shell | `path`, `glob`, `recursive` |
| `file_undo` | Revert a write_file or edit_file operation from earlier in the session | `operation_id`, `path` |
| `clarify` | Ask the user a clarifying question, optionally with discrete choices, when instructions are ambiguous | `question`, `options`, `allow_multiple` |

Passing `dry_run: true` to `write_file` or `edit_file` previews the change without touching disk.

---

## Command-Line Usage

### Building on macOS

The package builds against the macOS 26.x SDK as well as the macOS 27 SDK; model tier detection uses SystemLanguageModel.contextSize, which is available from macOS 26.0.

```bash
swift build -c release
```

### CLI Options
- `-p`, `--prompt <text>`: Single-shot prompt mode (non-interactive); if a tool call errors, the model's answer is still returned and an escalation report is logged to brain dir.
- `--scope <path>`: Restrict filesystem access and default working directory to `<path>`.
- `--read-only`: Mechanically block `write_file`, `edit_file`, and any non-read-only bash commands.
  - `write_file`, `edit_file`, and `file_undo` are not registered as tools in this mode, not just blocked at execution time.
- `--no-tools`: Run in pure reasoning mode without registering tools to avoid reflexive tool calling.
- `--json`: Output result as a JSON envelope containing answer, session UUID, brain path, metrics, and clarification status (if the clarify tool was invoked).
- `--brain-dir <path>`: Override the session log base directory (defaults to `./brain`).
- `--no-cleanup`: Skip automatic deletion of session directories older than 30 days.

### Examples
```bash
# Non-interactive single shot command
.build/release/afm-harness --prompt "Summarize recent commits" --scope ~/projects/my-app

# Gated read-only analysis with JSON output
.build/release/afm-harness --read-only --scope ~/projects/my-app --json -p "Audit dependencies"

# Interactive REPL mode
.build/release/afm-harness --scope ~/projects/my-app
```

---

## License

MIT License.
