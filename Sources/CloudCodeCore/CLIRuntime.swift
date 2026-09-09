import Foundation

public struct CLICommandCapabilitySnapshot: Codable, Equatable, Sendable {
    public var runtimeAvailable: Bool
    public var commands: [String]
    public var detail: String

    public init(runtimeAvailable: Bool, commands: [String] = [], detail: String) {
        self.runtimeAvailable = runtimeAvailable
        self.commands = Array(Set(commands)).sorted()
        self.detail = detail
    }
}

public struct CLICommandExecutionRequest: Equatable, Sendable {
    public var command: String
    public var sessionID: UUID
    public var workspaceRoot: URL
    public var workingDirectory: URL
    public var timeoutMilliseconds: Int

    public init(command: String, sessionID: UUID, workspaceRoot: URL, workingDirectory: URL, timeoutMilliseconds: Int) {
        self.command = command
        self.sessionID = sessionID
        self.workspaceRoot = workspaceRoot
        self.workingDirectory = workingDirectory
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public struct CLICommandExecutionResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var cancelled: Bool
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool
    public var binaryOutputSuppressed: Bool
    public var workingDirectory: String
    public var durationMilliseconds: Int

    public init(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false,
        cancelled: Bool = false,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        binaryOutputSuppressed: Bool = false,
        workingDirectory: String = "",
        durationMilliseconds: Int = 0
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.binaryOutputSuppressed = binaryOutputSuppressed
        self.workingDirectory = workingDirectory
        self.durationMilliseconds = max(0, durationMilliseconds)
    }

    public var truncated: Bool { stdoutTruncated || stderrTruncated }
}

public protocol CLICommandCapabilityProviding: Sendable {
    func cliCommandCapability() async -> CLICommandCapabilitySnapshot
}

public protocol CLICommandRuntime: CLICommandCapabilityProviding {
    func executeCLI(_ request: CLICommandExecutionRequest) async -> CLICommandExecutionResult
}

public enum CLICommandCatalog {
    /// The intentionally small command set packaged in the first ios_system integration.
    /// Native JSON/SQLite/network tools remain preferred and are not duplicated here.
    public static let packagedP0: Set<String> = [
        "pwd", "echo", "ls", "cat", "cp", "mv", "mkdir", "rm", "stat", "find",
        "grep", "head", "tail", "wc", "sort", "uniq"
    ]

    /// Commands safe enough for the read-only semantic CLI surface when used under the
    /// additional syntax/flag restrictions in CLICommandAnalyzer.
    public static let readOnly: Set<String> = [
        "pwd", "echo", "ls", "cat", "stat", "find", "grep", "head", "tail", "wc", "sort", "uniq"
    ]

    /// Desired structured-data command. It is deliberately not claimed as packaged until a
    /// pinned, auditable iOS jq framework is actually linked and validated.
    public static let desiredStructuredData: Set<String> = ["jq"]
}

public enum CLICommandValidationError: Error, Equatable, CustomStringConvertible, Sendable {
    case empty
    case tooLong
    case unterminatedQuote
    case commandSubstitutionNotAllowed
    case groupingNotAllowed
    case backgroundExecutionNotAllowed
    case unsupportedSyntax(String)
    case missingCommand
    case commandPathNotAllowed(String)
    case commandUnavailable(String)
    case readOnlyCommandRequired(String)
    case readOnlyMutationNotAllowed(String)
    case cwdRequiresAllowedRoot
    case cwdEscapesAllowedRoot

    public var description: String {
        switch self {
        case .empty: return "CLI command is empty"
        case .tooLong: return "CLI command exceeds the bounded command length"
        case .unterminatedQuote: return "CLI command contains an unterminated quote"
        case .commandSubstitutionNotAllowed: return "CLI command substitution/backticks are not allowed"
        case .groupingNotAllowed: return "CLI command grouping/subshell syntax is not allowed"
        case .backgroundExecutionNotAllowed: return "Background CLI execution is not allowed"
        case .unsupportedSyntax(let token): return "Unsupported CLI syntax: \(token)"
        case .missingCommand: return "CLI command segment has no executable"
        case .commandPathNotAllowed(let command): return "CLI executable paths/scripts are not allowed: \(command)"
        case .commandUnavailable(let command): return "CLI command is not present in the verified packaged catalog: \(command)"
        case .readOnlyCommandRequired(let command): return "Read-only CLI surface cannot execute mutating command: \(command)"
        case .readOnlyMutationNotAllowed(let token): return "Read-only CLI surface rejected mutating syntax/flag: \(token)"
        case .cwdRequiresAllowedRoot: return "An explicit CLI cwd requires an allowed workspace root"
        case .cwdEscapesAllowedRoot: return "CLI cwd escapes the allowed workspace root"
        }
    }
}

public struct CLICommandAnalysis: Equatable, Sendable {
    public var commands: [String]
    public var separators: [String]
    public var tokens: [String]

    public init(commands: [String], separators: [String], tokens: [String]) {
        self.commands = commands
        self.separators = separators
        self.tokens = tokens
    }
}

public enum CLICommandAnalyzer {
    private static let maximumCommandCharacters = 8_192

    public static func analyze(_ command: String, readOnly: Bool) throws -> CLICommandAnalysis {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CLICommandValidationError.empty }
        guard trimmed.count <= maximumCommandCharacters else { throw CLICommandValidationError.tooLong }
        if trimmed.contains("\n") || trimmed.contains("\r") {
            throw CLICommandValidationError.unsupportedSyntax("newline")
        }
        if trimmed.contains("`") || trimmed.contains("$(") || trimmed.contains("<(") || trimmed.contains(">(") {
            throw CLICommandValidationError.commandSubstitutionNotAllowed
        }

        var tokens: [String] = []
        var separators: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var index = trimmed.startIndex

        func flushToken() {
            if !current.isEmpty {
                tokens.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        while index < trimmed.endIndex {
            let ch = trimmed[index]
            if escaping {
                current.append(ch)
                escaping = false
                index = trimmed.index(after: index)
                continue
            }
            if ch == "\\" {
                escaping = true
                current.append(ch)
                index = trimmed.index(after: index)
                continue
            }
            if let activeQuote = quote {
                current.append(ch)
                if ch == activeQuote { quote = nil }
                index = trimmed.index(after: index)
                continue
            }
            if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
                index = trimmed.index(after: index)
                continue
            }
            if ch == "(" || ch == ")" || ch == "{" || ch == "}" {
                throw CLICommandValidationError.groupingNotAllowed
            }
            // Redirection is deliberately unavailable on both CLI surfaces. Read-only commands
            // must not write through `>`/`2>`, and the advanced escape hatch should use an
            // explicit catalogued mutating command (cp/mv/mkdir/rm) so the requested operation
            // remains visible to policy/audit rather than being hidden in shell syntax.
            if ch == ">" || ch == "<" {
                throw CLICommandValidationError.unsupportedSyntax(String(ch))
            }
            if ch.isWhitespace {
                flushToken()
                index = trimmed.index(after: index)
                continue
            }
            if ch == "|" || ch == "&" || ch == ";" {
                flushToken()
                let next = trimmed.index(after: index)
                var separator = String(ch)
                if next < trimmed.endIndex, trimmed[next] == ch, ch != ";" {
                    separator.append(ch)
                    index = trimmed.index(after: next)
                } else {
                    index = next
                }
                if separator == "&" { throw CLICommandValidationError.backgroundExecutionNotAllowed }
                if readOnly && separator != "|" {
                    throw CLICommandValidationError.readOnlyMutationNotAllowed(separator)
                }
                separators.append(separator)
                tokens.append(separator)
                continue
            }
            current.append(ch)
            index = trimmed.index(after: index)
        }
        if quote != nil { throw CLICommandValidationError.unterminatedQuote }
        if escaping { throw CLICommandValidationError.unsupportedSyntax("trailing escape") }
        flushToken()

        var commands: [String] = []
        var expectCommand = true
        for token in tokens {
            if ["|", "||", "&&", ";"].contains(token) {
                if expectCommand { throw CLICommandValidationError.missingCommand }
                expectCommand = true
                continue
            }
            if expectCommand {
                if token.hasPrefix(">") || token.hasPrefix("<") {
                    throw CLICommandValidationError.missingCommand
                }
                let normalized = unquote(token)
                guard !normalized.isEmpty else { throw CLICommandValidationError.missingCommand }
                if normalized.contains("/") || normalized.contains("=") {
                    throw CLICommandValidationError.commandPathNotAllowed(normalized)
                }
                commands.append(normalized)
                expectCommand = false
            }
        }
        if expectCommand { throw CLICommandValidationError.missingCommand }

        if readOnly {
            try validateReadOnly(tokens: tokens, commands: commands)
        }
        return CLICommandAnalysis(commands: commands, separators: separators, tokens: tokens)
    }

    private static func validateReadOnly(tokens: [String], commands: [String]) throws {
        for command in commands where !CLICommandCatalog.readOnly.contains(command) {
            throw CLICommandValidationError.readOnlyCommandRequired(command)
        }
        for token in tokens {
            if token.contains(">") || token == "<" || token.hasPrefix(">>") {
                throw CLICommandValidationError.readOnlyMutationNotAllowed(token)
            }
        }

        // Keep read-only find/sort semantics closed over known non-mutating behavior.
        let forbiddenFindFlags: Set<String> = [
            "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"
        ]
        let forbiddenSortFlags: Set<String> = ["-o", "--output"]
        var activeCommand: String?
        for token in tokens {
            if ["|", "||", "&&", ";"].contains(token) {
                activeCommand = nil
                continue
            }
            if activeCommand == nil {
                activeCommand = unquote(token)
                continue
            }
            let plain = unquote(token)
            if activeCommand == "find", forbiddenFindFlags.contains(plain) {
                throw CLICommandValidationError.readOnlyMutationNotAllowed(plain)
            }
            if activeCommand == "sort", forbiddenSortFlags.contains(plain) {
                throw CLICommandValidationError.readOnlyMutationNotAllowed(plain)
            }
        }
    }

    private static func unquote(_ token: String) -> String {
        guard token.count >= 2, let first = token.first, let last = token.last,
              (first == "\"" || first == "'"), first == last else { return token }
        return String(token.dropFirst().dropLast())
    }
}

public struct IOSSystemExecutor: ToolExecuting, Sendable {
    public let route: AppExecutionRoute = .cli
    private let policy: PolicyEngine
    private let approval: ApprovalRequesting
    private let runtime: any CLICommandRuntime
    private let runtimeRoot: URL

    public init(
        policy: PolicyEngine,
        approval: ApprovalRequesting,
        runtime: any CLICommandRuntime,
        runtimeRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("CloudCodeCLI", isDirectory: true)
    ) {
        self.policy = policy
        self.approval = approval
        self.runtime = runtime
        self.runtimeRoot = runtimeRoot.standardizedFileURL
    }

    public func supports(_ tool: ToolDescriptor, capabilities: CapabilityProfile) async -> Bool {
        switch tool.name {
        case "cli.run":
            return capabilities.isAvailable("cli.runtime")
        case "advanced.shell":
            return capabilities.isAvailable("execution.ios_system")
        default:
            return false
        }
    }

    public func execute(_ call: ToolCall, descriptor: ToolDescriptor, context: ToolExecutionContext) async throws -> ToolResult {
        guard let command = call.arguments["command"] else { throw ToolRouterError.noExecutionRoute("command missing") }
        let readOnlySurface = call.name == "cli.run"
        let analysis: CLICommandAnalysis
        do {
            analysis = try CLICommandAnalyzer.analyze(command, readOnly: readOnlySurface)
        } catch let error as CLICommandValidationError {
            throw ToolRouterError.noExecutionRoute(error.description)
        }

        let capability = await runtime.cliCommandCapability()
        guard capability.runtimeAvailable else {
            throw ToolRouterError.noExecutionRoute("ios_system runtime unavailable")
        }
        let available = Set(capability.commands)
        for name in analysis.commands where !available.contains(name) {
            throw ToolRouterError.noExecutionRoute(CLICommandValidationError.commandUnavailable(name).description)
        }

        // Generic CLI always stays inside a per-Agent-session workspace, even when broader typed
        // filesystem capabilities are available. Cross-container/root operations continue through
        // their typed helpers instead of inheriting the TrollStore App's broader process authority.
        let workspaceRoot = sessionWorkspaceRoot(for: call.sessionID)
        let cwd = try validatedWorkingDirectory(call.arguments["cwd"], allowedRoot: workspaceRoot)
        let timeoutMilliseconds = boundedTimeout(call.arguments["timeoutMs"], readOnly: readOnlySurface)

        let decision = policy.decision(mode: context.permissionMode, tool: descriptor, targetPath: cwd.path)
        if decision == .deny { throw TransactionError.confirmationDenied }
        // advanced.shell remains an explicit confirmation-gated escape hatch even in full mode.
        // Full mode may suppress ordinary writes, but it must not silently auto-approve generic shell.
        if !readOnlySurface || decision == .requireConfirmation {
            let preview = ApprovalPreview(
                title: "Run advanced shell",
                target: command,
                originalSummary: nil,
                diff: nil,
                reason: "Generic shell is a high-risk escape hatch; typed native tools remain preferred",
                plan: ["Validate packaged command catalog", "Execute bounded ios_system command", "Capture stdout/stderr separately", "Return explicit timeout/truncation state"],
                risk: descriptor.risk
            )
            guard await approval.requestApproval(preview) else { throw TransactionError.confirmationDenied }
        }

        let request = CLICommandExecutionRequest(
            command: command,
            sessionID: call.sessionID,
            workspaceRoot: workspaceRoot,
            workingDirectory: cwd,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let result = await runtime.executeCLI(request)
        let success = result.exitCode == 0 && !result.timedOut && !result.cancelled && !result.truncated && !result.binaryOutputSuppressed
        let commandSummary = analysis.commands.joined(separator: " | ")
        var payload: [String: String] = [
            "exitCode": String(result.exitCode),
            "stdout": result.stdout,
            "stderr": result.stderr,
            "timedOut": result.timedOut ? "true" : "false",
            "cancelled": result.cancelled ? "true" : "false",
            "truncated": result.truncated ? "true" : "false",
            "stdoutTruncated": result.stdoutTruncated ? "true" : "false",
            "stderrTruncated": result.stderrTruncated ? "true" : "false",
            "binaryOutputSuppressed": result.binaryOutputSuppressed ? "true" : "false",
            "cwd": result.workingDirectory,
            "commandSummary": commandSummary,
            "durationMs": String(result.durationMilliseconds)
        ]
        if result.timedOut { payload["failureKind"] = "timeout" }
        else if result.cancelled { payload["failureKind"] = "cancelled" }
        else if result.truncated { payload["failureKind"] = "output_truncated" }
        else if result.binaryOutputSuppressed { payload["failureKind"] = "binary_output_suppressed" }
        else if result.exitCode != 0 { payload["failureKind"] = "nonzero_exit" }

        let state: String
        if result.timedOut { state = "timed out" }
        else if result.cancelled { state = "cancelled" }
        else if result.truncated { state = "output truncated" }
        else if result.binaryOutputSuppressed { state = "binary output suppressed" }
        else { state = "exited \(result.exitCode)" }
        return ToolResult(
            toolCallID: call.id,
            success: success,
            summary: "CLI \(commandSummary) \(state)",
            payload: payload
        )
    }

    private func boundedTimeout(_ raw: String?, readOnly: Bool) -> Int {
        let defaultValue = readOnly ? 5_000 : 8_000
        guard let raw, let parsed = Int(raw) else { return defaultValue }
        let maximum = readOnly ? 10_000 : 15_000
        return min(max(parsed, 250), maximum)
    }

    private func sessionWorkspaceRoot(for sessionID: UUID) -> URL {
        runtimeRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .standardizedFileURL
    }

    private func validatedWorkingDirectory(_ raw: String?, allowedRoot: URL) throws -> URL {
        let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        guard let raw, !raw.isEmpty else { return root }
        let candidateURL: URL
        if raw.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            candidateURL = root.appendingPathComponent(raw, isDirectory: true)
        }
        let candidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
            throw CLICommandValidationError.cwdEscapesAllowedRoot
        }
        return candidate
    }
}
