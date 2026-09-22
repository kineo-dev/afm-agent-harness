import Foundation
import FoundationModels

// MARK: - Internal Helpers for GeneratedContent Extraction

extension Dictionary where Key == String, Value == GeneratedContent {
    func string(for key: String) -> String? {
        guard let item = self[key] else { return nil }
        if case .string(let s) = item.kind { return s }
        return nil
    }

    func int(for key: String) -> Int? {
        guard let item = self[key] else { return nil }
        if case .number(let n) = item.kind { return Int(n) }
        return nil
    }

    func bool(for key: String) -> Bool? {
        guard let item = self[key] else { return nil }
        if case .bool(let b) = item.kind { return b }
        return nil
    }

    func stringArray(for key: String) -> [String]? {
        guard let item = self[key] else { return nil }
        if case .array(let elements) = item.kind {
            return elements.compactMap { el in
                if case .string(let s) = el.kind { return s }
                return nil
            }
        }
        return nil
    }
}

// MARK: - BashTool

public struct BashTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// The shell command to execute
        public let command: String
        /// Brief human-readable description of what this command does
        public let description: String

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for bash command execution",
                properties: [
                    GenerationSchema.Property(name: "command", description: "The shell command to execute", type: String.self),
                    GenerationSchema.Property(name: "description", description: "Brief human-readable description of what this command does", type: String.self)
                ]
            )
        }

        public init(command: String, description: String) {
            self.command = command
            self.description = description
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "BashTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.command = props.string(for: "command") ?? ""
            self.description = props.string(for: "description") ?? ""
        }

        public var generatedContent: GeneratedContent {
            GeneratedContent(kind: .structure(properties: [
                "command": GeneratedContent(kind: .string(command)),
                "description": GeneratedContent(kind: .string(description))
            ], orderedKeys: ["command", "description"]))
        }
    }

    public typealias Output = String

    public let name: String = "bash"
    public let description: String = "Execute a bash shell command on the macOS system"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.runBash(command: arguments.command, description: arguments.description)
    }
}

// MARK: - ReadFileTool

public struct ReadFileTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// Absolute or relative path to the file
        public let path: String
        /// Optional 1-indexed line number to start reading from (inclusive)
        public let begin_line: Int?
        /// Optional 1-indexed line number to stop reading at (inclusive)
        public let end_line: Int?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for reading a file",
                properties: [
                    GenerationSchema.Property(name: "path", description: "Absolute or relative path to the file", type: String.self),
                    GenerationSchema.Property(name: "begin_line", description: "Optional 1-indexed line number to start reading from (inclusive)", type: Int?.self),
                    GenerationSchema.Property(name: "end_line", description: "Optional 1-indexed line number to stop reading at (inclusive)", type: Int?.self)
                ]
            )
        }

        public init(path: String, begin_line: Int? = nil, end_line: Int? = nil) {
            self.path = path
            self.begin_line = begin_line
            self.end_line = end_line
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "ReadFileTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.path = props.string(for: "path") ?? ""
            self.begin_line = props.int(for: "begin_line")
            self.end_line = props.int(for: "end_line")
        }

        public var generatedContent: GeneratedContent {
            var props: [String: GeneratedContent] = [
                "path": GeneratedContent(kind: .string(path))
            ]
            var keys = ["path"]
            if let begin = begin_line {
                props["begin_line"] = GeneratedContent(kind: .number(Double(begin)))
                keys.append("begin_line")
            }
            if let end = end_line {
                props["end_line"] = GeneratedContent(kind: .number(Double(end)))
                keys.append("end_line")
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        }
    }

    public typealias Output = String

    public let name: String = "read_file"
    public let description: String = "Read the contents of a file, optionally limited to a line range"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.readFile(path: arguments.path, beginLine: arguments.begin_line, endLine: arguments.end_line)
    }
}

// MARK: - WriteFileTool

public struct WriteFileTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// Absolute or relative path to the file
        public let path: String
        /// Content to write to the file
        public let content: String
        /// Optional boolean: if true, preview write without modifying the file
        public let dry_run: Bool?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for writing a file",
                properties: [
                    GenerationSchema.Property(name: "path", description: "Absolute or relative path to the file", type: String.self),
                    GenerationSchema.Property(name: "content", description: "Content to write to the file", type: String.self),
                    GenerationSchema.Property(name: "dry_run", description: "Optional boolean: if true, preview write without modifying the file", type: Bool?.self)
                ]
            )
        }

        public init(path: String, content: String, dry_run: Bool? = nil) {
            self.path = path
            self.content = content
            self.dry_run = dry_run
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "WriteFileTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.path = props.string(for: "path") ?? ""
            self.content = props.string(for: "content") ?? ""
            self.dry_run = props.bool(for: "dry_run")
        }

        public var generatedContent: GeneratedContent {
            var props: [String: GeneratedContent] = [
                "path": GeneratedContent(kind: .string(path)),
                "content": GeneratedContent(kind: .string(content))
            ]
            var keys = ["path", "content"]
            if let dryRun = dry_run {
                props["dry_run"] = GeneratedContent(kind: .bool(dryRun))
                keys.append("dry_run")
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        }
    }

    public typealias Output = String

    public let name: String = "write_file"
    public let description: String = "Write content to a file (creates or atomically overwrites, supports dry_run preview)"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.writeFile(path: arguments.path, content: arguments.content, dryRun: arguments.dry_run ?? false)
    }
}

// MARK: - EditFileTool

public struct EditFileTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// Absolute or relative path to the file to edit
        public let path: String
        /// Exact string to find and replace (must exist uniquely in the file)
        public let old_string: String
        /// Replacement string
        public let new_string: String
        /// Optional boolean: if true, preview replacement diff without modifying the file
        public let dry_run: Bool?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for editing a file",
                properties: [
                    GenerationSchema.Property(name: "path", description: "Absolute or relative path to the file to edit", type: String.self),
                    GenerationSchema.Property(name: "old_string", description: "Exact string to find and replace", type: String.self),
                    GenerationSchema.Property(name: "new_string", description: "Replacement string", type: String.self),
                    GenerationSchema.Property(name: "dry_run", description: "Optional boolean: if true, preview replacement diff without modifying the file", type: Bool?.self)
                ]
            )
        }

        public init(path: String, old_string: String, new_string: String, dry_run: Bool? = nil) {
            self.path = path
            self.old_string = old_string
            self.new_string = new_string
            self.dry_run = dry_run
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "EditFileTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.path = props.string(for: "path") ?? ""
            self.old_string = props.string(for: "old_string") ?? ""
            self.new_string = props.string(for: "new_string") ?? ""
            self.dry_run = props.bool(for: "dry_run")
        }

        public var generatedContent: GeneratedContent {
            var props: [String: GeneratedContent] = [
                "path": GeneratedContent(kind: .string(path)),
                "old_string": GeneratedContent(kind: .string(old_string)),
                "new_string": GeneratedContent(kind: .string(new_string))
            ]
            var keys = ["path", "old_string", "new_string"]
            if let dryRun = dry_run {
                props["dry_run"] = GeneratedContent(kind: .bool(dryRun))
                keys.append("dry_run")
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        }
    }

    public typealias Output = String

    public let name: String = "edit_file"
    public let description: String = "Edit an existing file by replacing an exact unique string atomically with backup (supports dry_run preview)"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.editFile(path: arguments.path, oldString: arguments.old_string, newString: arguments.new_string, dryRun: arguments.dry_run ?? false)
    }
}

// MARK: - FileUndoTool

public struct FileUndoTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// Optional operation ID to revert
        public let operation_id: String?
        /// Optional file path to revert the most recent operation on
        public let path: String?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for reverting a previous file edit or write",
                properties: [
                    GenerationSchema.Property(name: "operation_id", description: "Optional specific operation ID to revert", type: String?.self),
                    GenerationSchema.Property(name: "path", description: "Optional file path to revert the most recent operation on", type: String?.self)
                ]
            )
        }

        public init(operation_id: String? = nil, path: String? = nil) {
            self.operation_id = operation_id
            self.path = path
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "FileUndoTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.operation_id = props.string(for: "operation_id")
            self.path = props.string(for: "path")
        }

        public var generatedContent: GeneratedContent {
            var props: [String: GeneratedContent] = [:]
            var keys: [String] = []
            if let opId = operation_id {
                props["operation_id"] = GeneratedContent(kind: .string(opId))
                keys.append("operation_id")
            }
            if let p = path {
                props["path"] = GeneratedContent(kind: .string(p))
                keys.append("path")
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        }
    }

    public typealias Output = String

    public let name: String = "file_undo"
    public let description: String = "Revert a recent file write or edit from this session to restore previous content"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.undoFile(operationId: arguments.operation_id, path: arguments.path)
    }
}

// MARK: - SearchFilesTool

public struct SearchFilesTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// Search pattern or regex to find in file contents
        public let pattern: String
        /// Optional directory or file path to search within
        public let path: String?
        /// Optional filename glob pattern (e.g. *.swift, *.md)
        public let glob: String?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for searching file contents across the workspace",
                properties: [
                    GenerationSchema.Property(name: "pattern", description: "Search pattern or regex to find in file contents", type: String.self),
                    GenerationSchema.Property(name: "path", description: "Optional directory or file path to search within (defaults to workspace scope)", type: String?.self),
                    GenerationSchema.Property(name: "glob", description: "Optional filename pattern filter (e.g. *.swift, *.md)", type: String?.self)
                ]
            )
        }

        public init(pattern: String, path: String? = nil, glob: String? = nil) {
            self.pattern = pattern
            self.path = path
            self.glob = glob
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "SearchFilesTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.pattern = props.string(for: "pattern") ?? ""
            self.path = props.string(for: "path")
            self.glob = props.string(for: "glob")
        }

        public var generatedContent: GeneratedContent {
            var props: [String: GeneratedContent] = [
                "pattern": GeneratedContent(kind: .string(pattern))
            ]
            var keys = ["pattern"]
            if let p = path {
                props["path"] = GeneratedContent(kind: .string(p))
                keys.append("path")
            }
            if let g = glob {
                props["glob"] = GeneratedContent(kind: .string(g))
                keys.append("glob")
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        }
    }

    public typealias Output = String

    public let name: String = "search_files"
    public let description: String = "Search file contents across the workspace using regex or substring match with optional filename glob filter"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.searchFiles(pattern: arguments.pattern, path: arguments.path, glob: arguments.glob)
    }
}

// MARK: - ClarifyTool

public struct ClarifyTool: Tool, Sendable {
    public struct Arguments: Generable, Codable, Sendable {
        /// The specific clarifying question to ask the user
        public let question: String
        /// Optional list of discrete answer choices
        public let options: [String]?
        /// Optional boolean: whether multiple choices can be selected
        public let allow_multiple: Bool?

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for asking a clarifying question when requirements are ambiguous",
                properties: [
                    GenerationSchema.Property(name: "question", description: "The specific clarifying question to ask the user", type: String.self),
                    GenerationSchema.Property(name: "options", description: "Optional list of discrete answer choices", type: [String]?.self),
                    GenerationSchema.Property(name: "allow_multiple", description: "Optional boolean: whether multiple choices can be selected", type: Bool?.self)
                ]
            )
        }

        public init(question: String, options: [String]? = nil, allow_multiple: Bool? = nil) {
            self.question = question
            self.options = options
            self.allow_multiple = allow_multiple
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "ClarifyTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.question = props.string(for: "question") ?? ""
            self.options = props.stringArray(for: "options")
            self.allow_multiple = props.bool(for: "allow_multiple")
        }

        public var generatedContent: GeneratedContent {
            var props: [String: GeneratedContent] = [
                "question": GeneratedContent(kind: .string(question))
            ]
            var keys = ["question"]
            if let opts = options {
                let arrayElements = opts.map { GeneratedContent(kind: .string($0)) }
                props["options"] = GeneratedContent(kind: .array(arrayElements))
                keys.append("options")
            }
            if let allowMult = allow_multiple {
                props["allow_multiple"] = GeneratedContent(kind: .bool(allowMult))
                keys.append("allow_multiple")
            }
            return GeneratedContent(kind: .structure(properties: props, orderedKeys: keys))
        }
    }

    public typealias Output = String

    public let name: String = "clarify"
    public let description: String = "Ask the user a clarifying question with optional discrete answer choices when instructions are ambiguous"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.clarify(question: arguments.question, options: arguments.options, allowMultiple: arguments.allow_multiple)
    }
}
