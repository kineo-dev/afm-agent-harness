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

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for writing a file",
                properties: [
                    GenerationSchema.Property(name: "path", description: "Absolute or relative path to the file", type: String.self),
                    GenerationSchema.Property(name: "content", description: "Content to write to the file", type: String.self)
                ]
            )
        }

        public init(path: String, content: String) {
            self.path = path
            self.content = content
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "WriteFileTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.path = props.string(for: "path") ?? ""
            self.content = props.string(for: "content") ?? ""
        }

        public var generatedContent: GeneratedContent {
            GeneratedContent(kind: .structure(properties: [
                "path": GeneratedContent(kind: .string(path)),
                "content": GeneratedContent(kind: .string(content))
            ], orderedKeys: ["path", "content"]))
        }
    }

    public typealias Output = String

    public let name: String = "write_file"
    public let description: String = "Write content to a file (creates or atomically overwrites)"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.writeFile(path: arguments.path, content: arguments.content)
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

        public static var generationSchema: GenerationSchema {
            GenerationSchema(
                type: Arguments.self,
                description: "Arguments for editing a file",
                properties: [
                    GenerationSchema.Property(name: "path", description: "Absolute or relative path to the file to edit", type: String.self),
                    GenerationSchema.Property(name: "old_string", description: "Exact string to find and replace", type: String.self),
                    GenerationSchema.Property(name: "new_string", description: "Replacement string", type: String.self)
                ]
            )
        }

        public init(path: String, old_string: String, new_string: String) {
            self.path = path
            self.old_string = old_string
            self.new_string = new_string
        }

        public init(_ content: GeneratedContent) throws {
            guard case .structure(let props, _) = content.kind else {
                throw NSError(domain: "EditFileTool.Arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected structure"])
            }
            self.path = props.string(for: "path") ?? ""
            self.old_string = props.string(for: "old_string") ?? ""
            self.new_string = props.string(for: "new_string") ?? ""
        }

        public var generatedContent: GeneratedContent {
            GeneratedContent(kind: .structure(properties: [
                "path": GeneratedContent(kind: .string(path)),
                "old_string": GeneratedContent(kind: .string(old_string)),
                "new_string": GeneratedContent(kind: .string(new_string))
            ], orderedKeys: ["path", "old_string", "new_string"]))
        }
    }

    public typealias Output = String

    public let name: String = "edit_file"
    public let description: String = "Edit an existing file by replacing an exact unique string atomically with backup (.bak)"
    public var parameters: GenerationSchema { Arguments.generationSchema }
    public let executor: Executor

    public init(executor: Executor) {
        self.executor = executor
    }

    public func call(arguments: Arguments) async throws -> String {
        return executor.editFile(path: arguments.path, oldString: arguments.old_string, newString: arguments.new_string)
    }
}
