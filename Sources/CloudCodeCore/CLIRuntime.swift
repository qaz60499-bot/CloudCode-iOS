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
    case pathArgumentUnsafe(String)
    case pathArgumentEscapesSession(String)

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
        case .pathArgumentUnsafe(let token): return "CLI path argument cannot be safely confined to the session workspace: \(token)"
        case .pathArgumentEscapesSession(let token): return "CLI path argument escapes the session workspace: \(token)"
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

        try validateUniversalConstraints(tokens: tokens)
        if readOnly {
            try validateReadOnly(tokens: tokens, commands: commands)
        }
        return CLICommandAnalysis(commands: commands, separators: separators, tokens: tokens)
    }

    private static func validateUniversalConstraints(tokens: [String]) throws {
        // Keep the first CLI generation on the audited short-option surface. Besides simplifying
        // path confinement, this closes forms such as --output=/outside that otherwise bypass an
        // exact-token guard written for the corresponding short option.
        for token in tokens {
            let plain = unquote(token)
            if plain.hasPrefix("--"), plain != "--" {
                throw CLICommandValidationError.unsupportedSyntax(plain)
            }
        }

        // `find -exec/-ok` is itself an executable launcher and would bypass the packaged-command
        // catalog. Its file-output predicates similarly hide writes inside a nominal find command.
        // Symlink-following find modes are disabled because the generic CLI is session-confined.
        let forbiddenFindFlags: Set<String> = [
            "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls", "-H", "-L"
        ]
        // sort output/temp-file flags introduce hidden write paths; the bounded first generation
        // returns sort output through captured stdout instead.
        let forbiddenSortFlags: Set<String> = ["-o", "-T"]
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
                throw CLICommandValidationError.unsupportedSyntax(plain)
            }
            if activeCommand == "sort", forbiddenSortFlags.contains(plain) {
                throw CLICommandValidationError.unsupportedSyntax(plain)
            }
        }
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

private enum CLIPathConfinement {
    private static let separators: Set<String> = ["|", "||", "&&", ";"]

    static func validate(
        analysis: CLICommandAnalysis,
        sessionRoot: URL,
        workingDirectory: URL,
        homeDirectory: URL,
        temporaryDirectory: URL,
        readOnly: Bool,
        fileManager: FileManager = .default
    ) throws {
        let root = canonicalURL(sessionRoot, fileManager: fileManager)
        let cwd = canonicalURL(workingDirectory, fileManager: fileManager)
        guard isInside(cwd, root: root) else {
            throw CLICommandValidationError.cwdEscapesAllowedRoot
        }

        for segment in commandSegments(analysis.tokens) {
            guard let first = segment.first else { continue }
            let command = unquote(first)
            let operands = try pathOperands(command: command, arguments: Array(segment.dropFirst()))
            if readOnly, command == "uniq", operands.count > 1 {
                throw CLICommandValidationError.readOnlyMutationNotAllowed("uniq output file")
            }
            for operand in operands {
                try validatePathOperand(
                    operand,
                    sessionRoot: root,
                    workingDirectory: cwd,
                    homeDirectory: canonicalURL(homeDirectory, fileManager: fileManager),
                    temporaryDirectory: canonicalURL(temporaryDirectory, fileManager: fileManager),
                    fileManager: fileManager
                )
            }
        }
    }

    private static func commandSegments(_ tokens: [String]) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for token in tokens {
            if separators.contains(token) {
                if !current.isEmpty { result.append(current) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(token)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func pathOperands(command: String, arguments: [String]) throws -> [String] {
        switch command {
        case "pwd", "echo":
            return []
        case "ls":
            try rejectOptionCharacters(arguments, forbidden: ["H", "L"])
            return try operandsSkippingShortOptions(arguments, valueOptions: [])
        case "cp":
            try rejectOptionCharacters(arguments, forbidden: ["H", "L"])
            return try operandsSkippingShortOptions(arguments, valueOptions: [])
        case "cat", "mv", "rm":
            return try operandsSkippingShortOptions(arguments, valueOptions: [])
        case "mkdir":
            return try operandsSkippingShortOptions(arguments, valueOptions: ["m"])
        case "stat":
            return try operandsSkippingShortOptions(arguments, valueOptions: ["f", "t"])
        case "head":
            return try operandsSkippingShortOptions(arguments, valueOptions: ["n", "c"])
        case "tail":
            try rejectOptionCharacters(arguments, forbidden: ["F", "f"])
            return try operandsSkippingShortOptions(arguments, valueOptions: ["b", "c", "n"])
        case "wc":
            return try operandsSkippingShortOptions(arguments, valueOptions: ["M", "N"])
        case "sort":
            return try operandsSkippingShortOptions(arguments, valueOptions: ["k", "t"])
        case "uniq":
            return try operandsSkippingShortOptions(arguments, valueOptions: ["f", "s"])
        case "find":
            return try findPathOperands(arguments)
        case "grep":
            return try grepPathOperands(arguments)
        default:
            // Capability validation should prevent this branch. Keep path policy fail-closed if
            // the packaged catalog grows before this confinement model is updated.
            throw CLICommandValidationError.pathArgumentUnsafe("unsupported command path model: \(command)")
        }
    }

    private static func rejectOptionCharacters(_ arguments: [String], forbidden: Set<Character>) throws {
        var endOptions = false
        for token in arguments {
            let plain = unquote(token)
            if plain == "--" {
                endOptions = true
                continue
            }
            guard !endOptions, plain.hasPrefix("-"), plain != "-", !plain.hasPrefix("--") else { continue }
            for option in plain.dropFirst() where forbidden.contains(option) {
                throw CLICommandValidationError.unsupportedSyntax("-\(option)")
            }
        }
    }

    private static func operandsSkippingShortOptions(_ arguments: [String], valueOptions: Set<Character>) throws -> [String] {
        var operands: [String] = []
        var index = 0
        var endOptions = false
        while index < arguments.count {
            let plain = unquote(arguments[index])
            if !endOptions, plain == "--" {
                endOptions = true
                index += 1
                continue
            }
            if !endOptions, plain.hasPrefix("-"), plain != "-" {
                guard !plain.hasPrefix("--") else {
                    throw CLICommandValidationError.unsupportedSyntax(plain)
                }
                let optionCharacters = Array(plain.dropFirst())
                var consumesFollowingValue = false
                for (offset, option) in optionCharacters.enumerated() where valueOptions.contains(option) {
                    consumesFollowingValue = offset == optionCharacters.count - 1
                    break
                }
                if consumesFollowingValue {
                    guard index + 1 < arguments.count else {
                        throw CLICommandValidationError.pathArgumentUnsafe("missing option value after \(plain)")
                    }
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            operands.append(plain)
            index += 1
        }
        return operands
    }

    private static func findPathOperands(_ arguments: [String]) throws -> [String] {
        var paths: [String] = []
        var index = 0
        var endOptions = false

        // Parse the bounded path-prefix first. Once an expression begins, every accepted predicate
        // is explicitly whitelisted below; predicates that take a filesystem path (for example
        // -newer/-samefile) are intentionally unsupported in the first generation.
        while index < arguments.count {
            let plain = unquote(arguments[index])
            if !endOptions, plain == "--" {
                endOptions = true
                index += 1
                continue
            }
            if !endOptions, plain == "-f" {
                guard index + 1 < arguments.count else {
                    throw CLICommandValidationError.pathArgumentUnsafe("missing find -f path")
                }
                paths.append(unquote(arguments[index + 1]))
                index += 2
                continue
            }
            if plain == "!" || plain.hasPrefix("-") { break }
            paths.append(plain)
            index += 1
        }

        let noValuePredicates: Set<String> = [
            "-a", "-and", "-o", "-or", "-not", "-empty", "-print", "-print0", "-xdev", "-depth", "-delete"
        ]
        let oneValuePredicates: Set<String> = [
            "-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-type", "-size",
            "-maxdepth", "-mindepth", "-perm", "-user", "-group", "-uid", "-gid", "-links", "-inum",
            "-atime", "-ctime", "-mtime", "-amin", "-cmin", "-mmin"
        ]
        while index < arguments.count {
            let predicate = unquote(arguments[index])
            if predicate == "!" || noValuePredicates.contains(predicate) {
                index += 1
                continue
            }
            if oneValuePredicates.contains(predicate) {
                guard index + 1 < arguments.count else {
                    throw CLICommandValidationError.pathArgumentUnsafe("missing find predicate value after \(predicate)")
                }
                index += 2
                continue
            }
            throw CLICommandValidationError.unsupportedSyntax(predicate)
        }
        return paths
    }

    private static func grepPathOperands(_ arguments: [String]) throws -> [String] {
        try rejectOptionCharacters(arguments, forbidden: ["R"])
        let valueOptions: Set<Character> = ["A", "B", "C", "D", "d", "e", "f", "m"]
        var paths: [String] = []
        var index = 0
        var endOptions = false
        var patternProvidedByOption = false
        var positionalPatternSeen = false

        while index < arguments.count {
            let plain = unquote(arguments[index])
            if !endOptions, plain == "--" {
                endOptions = true
                index += 1
                continue
            }
            if !endOptions, plain.hasPrefix("-"), plain != "-" {
                guard !plain.hasPrefix("--") else {
                    throw CLICommandValidationError.unsupportedSyntax(plain)
                }
                let optionCharacters = Array(plain.dropFirst())
                var consumedSeparateValue = false
                for (offset, option) in optionCharacters.enumerated() where valueOptions.contains(option) {
                    let hasAttachedValue = offset < optionCharacters.count - 1
                    if option == "e" || option == "f" { patternProvidedByOption = true }
                    if option == "f" {
                        if hasAttachedValue {
                            paths.append(String(optionCharacters[(offset + 1)...]))
                        } else {
                            guard index + 1 < arguments.count else {
                                throw CLICommandValidationError.pathArgumentUnsafe("missing grep -f pattern file")
                            }
                            paths.append(unquote(arguments[index + 1]))
                            consumedSeparateValue = true
                        }
                    } else if !hasAttachedValue {
                        guard index + 1 < arguments.count else {
                            throw CLICommandValidationError.pathArgumentUnsafe("missing option value after \(plain)")
                        }
                        consumedSeparateValue = true
                    }
                    break
                }
                index += consumedSeparateValue ? 2 : 1
                continue
            }

            if !patternProvidedByOption, !positionalPatternSeen {
                positionalPatternSeen = true
            } else {
                paths.append(plain)
            }
            index += 1
        }
        return paths
    }

    private static func validatePathOperand(
        _ raw: String,
        sessionRoot: URL,
        workingDirectory: URL,
        homeDirectory: URL,
        temporaryDirectory: URL,
        fileManager: FileManager
    ) throws {
        if raw == "-" || raw.isEmpty { return }
        if raw.contains("\\") || raw.contains("*") || raw.contains("?") || raw.contains("[") || raw.contains("]") {
            throw CLICommandValidationError.pathArgumentUnsafe(raw)
        }

        let expanded: String
        if raw == "~" || raw.hasPrefix("~/") {
            expanded = homeDirectory.path + String(raw.dropFirst())
        } else if let value = expandKnownVariablePath(raw, name: "HOME", value: homeDirectory.path) {
            expanded = value
        } else if let value = expandKnownVariablePath(raw, name: "TMPDIR", value: temporaryDirectory.path) {
            expanded = value
        } else if let value = expandKnownVariablePath(raw, name: "PWD", value: workingDirectory.path) {
            expanded = value
        } else {
            guard !raw.contains("$") else { throw CLICommandValidationError.pathArgumentUnsafe(raw) }
            expanded = raw
        }

        let candidate = expanded.hasPrefix("/")
            ? URL(fileURLWithPath: expanded)
            : workingDirectory.appendingPathComponent(expanded)
        let standardized = candidate.standardizedFileURL
        guard isInside(standardized, root: sessionRoot) else {
            throw CLICommandValidationError.pathArgumentEscapesSession(raw)
        }

        // Do not allow a path below the session root to tunnel through a symlink into broader
        // TrollStore-visible storage. Rejecting symlinks is intentionally stricter than resolving
        // and permitting same-root links; the bounded first generation prioritizes containment.
        try rejectSymlinkComponents(standardized, root: sessionRoot, raw: raw, fileManager: fileManager)
    }

    private static func expandKnownVariablePath(_ raw: String, name: String, value: String) -> String? {
        let marker = "$\(name)"
        guard raw == marker || raw.hasPrefix(marker + "/") else { return nil }
        return value + String(raw.dropFirst(marker.count))
    }

    private static func rejectSymlinkComponents(
        _ candidate: URL,
        root: URL,
        raw: String,
        fileManager: FileManager
    ) throws {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            throw CLICommandValidationError.pathArgumentEscapesSession(raw)
        }
        var cursor = root.standardizedFileURL
        for component in candidateComponents.dropFirst(rootComponents.count) {
            cursor.appendPathComponent(component)
            guard let attributes = try? fileManager.attributesOfItem(atPath: cursor.path),
                  let type = attributes[.type] as? FileAttributeType else {
                // Missing destinations are valid for mkdir/cp/mv. Their existing parent chain has
                // already been checked, and remaining lexical components stay below sessionRoot.
                continue
            }
            if type == .typeSymbolicLink {
                throw CLICommandValidationError.pathArgumentUnsafe(raw)
            }
        }
    }

    private static func canonicalURL(_ url: URL, fileManager: FileManager) -> URL {
        let standardized = url.standardizedFileURL
        if fileManager.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        return standardized
    }

    private static func isInside(_ candidate: URL, root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return candidatePath == rootPath || candidatePath.hasPrefix(prefix)
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

        // Generic CLI always stays inside one per-Agent-session sandbox. `workspace` is the default
        // cwd while HOME/TMP remain sibling directories under the same mini-root; no generic CLI
        // operation inherits the TrollStore App's broader process-visible filesystem authority.
        let sessionRoot = cliSessionRoot(for: call.sessionID)
        let workspace = sessionRoot.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
        let home = sessionRoot.appendingPathComponent("home", isDirectory: true).standardizedFileURL
        let temporary = sessionRoot.appendingPathComponent("tmp", isDirectory: true).standardizedFileURL
        let cwd = try validatedWorkingDirectory(call.arguments["cwd"], defaultDirectory: workspace, allowedRoot: sessionRoot)
        try CLIPathConfinement.validate(
            analysis: analysis,
            sessionRoot: sessionRoot,
            workingDirectory: cwd,
            homeDirectory: home,
            temporaryDirectory: temporary,
            readOnly: readOnlySurface
        )
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
            workspaceRoot: sessionRoot,
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

    private func cliSessionRoot(for sessionID: UUID) -> URL {
        runtimeRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
    }

    private func validatedWorkingDirectory(_ raw: String?, defaultDirectory: URL, allowedRoot: URL) throws -> URL {
        let root = allowedRoot.standardizedFileURL.resolvingSymlinksInPath()
        let base = defaultDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard let raw, !raw.isEmpty else { return base }
        let candidateURL: URL
        if raw.hasPrefix("/") {
            candidateURL = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            candidateURL = base.appendingPathComponent(raw, isDirectory: true)
        }
        let candidate = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path == root.path || candidate.path.hasPrefix(rootPath) else {
            throw CLICommandValidationError.cwdEscapesAllowedRoot
        }
        return candidate
    }
}
