import Foundation
import CloudCodeCore

private final class IOSSystemCancellationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = Set<String>()

    func markCancelled(_ invocationID: String) {
        lock.lock()
        cancelled.insert(invocationID)
        lock.unlock()
    }

    func isCancelled(_ invocationID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(invocationID)
    }

    func clear(_ invocationID: String) {
        lock.lock()
        cancelled.remove(invocationID)
        lock.unlock()
    }
}

/// The single ordinary in-process ios_system adapter used by Cloud Code.
///
/// Upstream ios_system keeps currentSession/current-directory state process-wide. Cloud Code Agent
/// sessions may run concurrently, so concrete command execution and capability/framework probing are
/// serialized on one queue. The bridge itself never requests root/persona authority; every command
/// is additionally workspace-miniRoot scoped and receives a small per-session environment.
public final class IOSSystemRuntime: CLICommandRuntime, @unchecked Sendable {
    private let runtimeRoot: URL
    private let fileManager: FileManager
    private let executionQueue = DispatchQueue(label: "com.cloudcode.ios.cli-runtime", qos: .userInitiated)
    private let cancellation = IOSSystemCancellationRegistry()

    public init(runtimeRoot: URL, fileManager: FileManager = .default) {
        self.runtimeRoot = runtimeRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    public func cliCommandCapability() async -> CLICommandCapabilitySnapshot {
        await withCheckedContinuation { continuation in
            executionQueue.async {
                let raw = CloudCodeIOSSystemCapabilitySnapshot()
                let runtimeAvailable = (raw["runtimeAvailable"] as? NSNumber)?.boolValue ?? false
                let actual = Set((raw["commands"] as? [String]) ?? [])
                // Internal command dictionaries may grow later. Agent visibility remains bounded to
                // the catalog declared by CloudCodeCore; jq is not surfaced until it is truly linked.
                let exposed = CLICommandCatalog.packagedP0.union(CLICommandCatalog.desiredStructuredData)
                continuation.resume(returning: CLICommandCapabilitySnapshot(
                    runtimeAvailable: runtimeAvailable,
                    commands: actual.intersection(exposed).sorted(),
                    detail: raw["detail"] as? String ?? "ios_system capability bridge returned no detail"
                ))
            }
        }
    }

    public func executeCLI(_ request: CLICommandExecutionRequest) async -> CLICommandExecutionResult {
        let invocationID = UUID().uuidString
        if Task.isCancelled { return Self.cancelledResult(request) }

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                executionQueue.async { [self] in
                    if cancellation.isCancelled(invocationID) {
                        cancellation.clear(invocationID)
                        continuation.resume(returning: Self.cancelledResult(request))
                        return
                    }

                    let sessionRoot = runtimeRoot
                        .appendingPathComponent("Sessions", isDirectory: true)
                        .appendingPathComponent(request.sessionID.uuidString.lowercased(), isDirectory: true)
                    let home = sessionRoot.appendingPathComponent("home", isDirectory: true)
                    let temporary = sessionRoot.appendingPathComponent("tmp", isDirectory: true)
                    let workspace = sessionRoot.appendingPathComponent("workspace", isDirectory: true)
                    do {
                        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
                        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
                        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
                    } catch {
                        cancellation.clear(invocationID)
                        continuation.resume(returning: CLICommandExecutionResult(
                            exitCode: -1,
                            stderr: "CLI runtime directory setup failed: \(error.localizedDescription)",
                            workingDirectory: request.workingDirectory.path
                        ))
                        return
                    }

                    let expectedSessionRoot = sessionRoot.standardizedFileURL.resolvingSymlinksInPath()
                    let requestedSessionRoot = request.workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
                    guard requestedSessionRoot.path == expectedSessionRoot.path else {
                        cancellation.clear(invocationID)
                        continuation.resume(returning: CLICommandExecutionResult(
                            exitCode: -1,
                            stderr: "CLI request root does not match the session sandbox",
                            workingDirectory: request.workingDirectory.path
                        ))
                        return
                    }

                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: request.workingDirectory.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        cancellation.clear(invocationID)
                        continuation.resume(returning: CLICommandExecutionResult(
                            exitCode: -1,
                            stderr: "CLI working directory does not exist",
                            workingDirectory: request.workingDirectory.path
                        ))
                        return
                    }
                    let resolvedWorkingDirectory = request.workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
                    let sessionPrefix = expectedSessionRoot.path.hasSuffix("/") ? expectedSessionRoot.path : expectedSessionRoot.path + "/"
                    guard resolvedWorkingDirectory.path == expectedSessionRoot.path || resolvedWorkingDirectory.path.hasPrefix(sessionPrefix) else {
                        cancellation.clear(invocationID)
                        continuation.resume(returning: CLICommandExecutionResult(
                            exitCode: -1,
                            stderr: "CLI working directory escaped the session sandbox",
                            workingDirectory: request.workingDirectory.path
                        ))
                        return
                    }

                    let raw = CloudCodeIOSSystemRunCommand(
                        request.command,
                        invocationID,
                        request.sessionID.uuidString,
                        expectedSessionRoot.path,
                        resolvedWorkingDirectory.path,
                        home.path,
                        temporary.path,
                        Double(request.timeoutMilliseconds) / 1_000.0
                    )
                    cancellation.clear(invocationID)
                    continuation.resume(returning: Self.decode(raw, fallbackCWD: request.workingDirectory.path))
                }
            }
        }, onCancel: { [cancellation] in
            // If queued, remember cancellation until this exact invocation reaches the serial queue.
            // If active, the bridge owns the exact ID and calls upstream ios_kill() for that command.
            cancellation.markCancelled(invocationID)
            CloudCodeIOSSystemCancelInvocation(invocationID)
        })
    }

    private static func decode(_ raw: [String: Any], fallbackCWD: String) -> CLICommandExecutionResult {
        CLICommandExecutionResult(
            exitCode: (raw["exitCode"] as? NSNumber)?.int32Value ?? -1,
            stdout: raw["stdout"] as? String ?? "",
            stderr: raw["stderr"] as? String ?? "",
            timedOut: (raw["timedOut"] as? NSNumber)?.boolValue ?? false,
            cancelled: (raw["cancelled"] as? NSNumber)?.boolValue ?? false,
            stdoutTruncated: (raw["stdoutTruncated"] as? NSNumber)?.boolValue ?? false,
            stderrTruncated: (raw["stderrTruncated"] as? NSNumber)?.boolValue ?? false,
            binaryOutputSuppressed: (raw["binaryOutputSuppressed"] as? NSNumber)?.boolValue ?? false,
            workingDirectory: raw["cwd"] as? String ?? fallbackCWD,
            durationMilliseconds: (raw["durationMs"] as? NSNumber)?.intValue ?? 0
        )
    }

    private static func cancelledResult(_ request: CLICommandExecutionRequest) -> CLICommandExecutionResult {
        CLICommandExecutionResult(
            exitCode: -1,
            stderr: "CLI command cancelled before execution completed",
            cancelled: true,
            workingDirectory: request.workingDirectory.path
        )
    }
}
