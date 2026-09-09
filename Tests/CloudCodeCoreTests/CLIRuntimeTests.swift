import XCTest
@testable import CloudCodeCore

private actor FakeCLIRuntime: CLICommandRuntime {
    var snapshot: CLICommandCapabilitySnapshot
    var queuedResults: [CLICommandExecutionResult]
    var requests: [CLICommandExecutionRequest] = []
    var capabilityRequestCount = 0

    init(
        commands: [String] = Array(CLICommandCatalog.packagedP0),
        runtimeAvailable: Bool = true,
        results: [CLICommandExecutionResult] = [CLICommandExecutionResult(exitCode: 0)]
    ) {
        self.snapshot = CLICommandCapabilitySnapshot(runtimeAvailable: runtimeAvailable, commands: commands, detail: "fake")
        self.queuedResults = results
    }

    func cliCommandCapability() async -> CLICommandCapabilitySnapshot {
        capabilityRequestCount += 1
        return snapshot
    }

    func executeCLI(_ request: CLICommandExecutionRequest) async -> CLICommandExecutionResult {
        requests.append(request)
        if queuedResults.isEmpty { return CLICommandExecutionResult(exitCode: 0) }
        return queuedResults.removeFirst()
    }

    func recordedRequests() -> [CLICommandExecutionRequest] { requests }
    func recordedCapabilityRequestCount() -> Int { capabilityRequestCount }
}

final class CLIRuntimeTests: XCTestCase {
    private func capabilities(runtime: CapabilityStatus = .available) -> CapabilityProfile {
        CapabilityProfile(records: [
            CapabilityRecord(id: "execution.ios_system", domain: .execution, status: runtime, detail: "test"),
            CapabilityRecord(id: "cli.runtime", domain: .execution, status: runtime, detail: "test")
        ])
    }

    private func context(
        mode: PermissionMode = .full,
        runtime: CapabilityStatus = .available,
        allowedRoot: URL? = nil
    ) -> ToolExecutionContext {
        ToolExecutionContext(permissionMode: mode, capabilityProfile: capabilities(runtime: runtime), allowedRoot: allowedRoot)
    }

    func testReadOnlyCLIParsesBoundedPipeline() throws {
        let analysis = try CLICommandAnalyzer.analyze("find . -name '*.json' | grep bundleId | head -n 5", readOnly: true)
        XCTAssertEqual(analysis.commands, ["find", "grep", "head"])
        XCTAssertEqual(analysis.separators, ["|", "|"])
    }

    func testReadOnlyCLIRejectsMutationAndSubstitution() {
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("find . -delete", readOnly: true))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("sort -o out.txt input.txt", readOnly: true))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("cat a > b", readOnly: true))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("echo $(pwd)", readOnly: true))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("cat a && cat b", readOnly: true))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("ls &", readOnly: true))
    }

    func testAdvancedShellStillRejectsExternalExecutablePathBackgroundAndRedirection() {
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("/bin/ls", readOnly: false))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("ls &", readOnly: false))
        XCTAssertThrowsError(try CLICommandAnalyzer.analyze("cat input > output", readOnly: false))
        XCTAssertNoThrow(try CLICommandAnalyzer.analyze("mkdir work && ls work", readOnly: false))
    }

    func testAdvancedShellRemainsConfirmationGatedInFullMode() async throws {
        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(
            policy: PolicyEngine(),
            approval: FixedApprovalRequester(approved: false),
            runtime: runtime
        )
        let descriptor = ToolDescriptor(
            name: "advanced.shell",
            summary: "",
            risk: .systemChange,
            requiredCapabilities: ["execution.ios_system"],
            preferredRoute: .cli
        )
        do {
            _ = try await executor.execute(
                ToolCall(name: "advanced.shell", arguments: ["command": "pwd"], sessionID: UUID()),
                descriptor: descriptor,
                context: context(mode: .full)
            )
            XCTFail("Expected advanced.shell to require explicit approval even in full mode")
        } catch let error as TransactionError {
            XCTAssertEqual(error, .confirmationDenied)
        }
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testExecutorRoutesOnlyWhenRuntimeCapabilityAvailable() async {
        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let shell = ToolDescriptor(name: "advanced.shell", summary: "", risk: .systemChange, requiredCapabilities: ["execution.ios_system"], preferredRoute: .cli)
        let read = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let shellAvailable = await executor.supports(shell, capabilities: capabilities())
        let readAvailable = await executor.supports(read, capabilities: capabilities())
        let shellUnavailable = await executor.supports(shell, capabilities: capabilities(runtime: .unavailable))
        let readUnavailable = await executor.supports(read, capabilities: capabilities(runtime: .unavailable))
        XCTAssertTrue(shellAvailable)
        XCTAssertTrue(readAvailable)
        XCTAssertFalse(shellUnavailable)
        XCTAssertFalse(readUnavailable)
    }

    func testUnavailableCommandFailsClosedBeforeExecution() async throws {
        let runtime = FakeCLIRuntime(commands: ["pwd"])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let call = ToolCall(name: "cli.run", arguments: ["command": "grep x file"], sessionID: UUID())
        do {
            _ = try await executor.execute(call, descriptor: descriptor, context: context())
            XCTFail("Expected unavailable command to fail closed")
        } catch let error as ToolRouterError {
            guard case .noExecutionRoute(let detail) = error else { return XCTFail("Unexpected error \(error)") }
            XCTAssertTrue(detail.contains("grep"))
        }
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testStdoutAndStderrStaySeparated() async throws {
        let runtime = FakeCLIRuntime(results: [
            CLICommandExecutionResult(exitCode: 0, stdout: "hello\n", stderr: "warning\n", workingDirectory: "/workspace", durationMilliseconds: 12)
        ])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let result = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "echo hello"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.payload["stdout"], "hello\n")
        XCTAssertEqual(result.payload["stderr"], "warning\n")
        XCTAssertEqual(result.payload["exitCode"], "0")
        XCTAssertEqual(result.payload["cwd"], "/workspace")
        XCTAssertEqual(result.payload["durationMs"], "12")
    }

    func testNonZeroExitIsDistinctFromTimeoutCancellationAndTruncation() async throws {
        let runtime = FakeCLIRuntime(results: [
            CLICommandExecutionResult(exitCode: 7, stderr: "no match")
        ])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let result = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "grep missing file"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.payload["failureKind"], "nonzero_exit")
        XCTAssertEqual(result.payload["timedOut"], "false")
        XCTAssertEqual(result.payload["cancelled"], "false")
        XCTAssertEqual(result.payload["truncated"], "false")
    }

    func testTruncationFailsClosedEvenWithZeroExit() async throws {
        let runtime = FakeCLIRuntime(results: [
            CLICommandExecutionResult(exitCode: 0, stdout: String(repeating: "x", count: 16), stdoutTruncated: true)
        ])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let result = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "cat file"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.payload["truncated"], "true")
        XCTAssertEqual(result.payload["failureKind"], "output_truncated")
    }

    func testBinaryOutputSuppressionFailsClosedEvenWithZeroExit() async throws {
        let runtime = FakeCLIRuntime(results: [
            CLICommandExecutionResult(exitCode: 0, stdout: "<binary output suppressed>", binaryOutputSuppressed: true)
        ])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let result = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "cat file"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.payload["binaryOutputSuppressed"], "true")
        XCTAssertEqual(result.payload["failureKind"], "binary_output_suppressed")
    }

    func testExactOutputBoundaryStaysSuccessfulWhenRuntimeDoesNotReportTruncation() async throws {
        let boundary = String(repeating: "x", count: 64 * 1024)
        let runtime = FakeCLIRuntime(results: [
            CLICommandExecutionResult(exitCode: 0, stdout: boundary, stdoutTruncated: false)
        ])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let result = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "cat file"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.payload["stdout"]?.count, boundary.count)
        XCTAssertEqual(result.payload["truncated"], "false")
    }

    func testTimeoutAndCancellationAreDistinct() async throws {
        let runtime = FakeCLIRuntime(results: [
            CLICommandExecutionResult(exitCode: -1, timedOut: true),
            CLICommandExecutionResult(exitCode: -1, cancelled: true),
            CLICommandExecutionResult(exitCode: 0, stdout: "next\n")
        ])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let first = try await executor.execute(ToolCall(name: "cli.run", arguments: ["command": "pwd"], sessionID: UUID()), descriptor: descriptor, context: context())
        let second = try await executor.execute(ToolCall(name: "cli.run", arguments: ["command": "pwd"], sessionID: UUID()), descriptor: descriptor, context: context())
        let third = try await executor.execute(ToolCall(name: "cli.run", arguments: ["command": "pwd"], sessionID: UUID()), descriptor: descriptor, context: context())
        XCTAssertEqual(first.payload["failureKind"], "timeout")
        XCTAssertEqual(second.payload["failureKind"], "cancelled")
        XCTAssertTrue(third.success)
        XCTAssertEqual(third.payload["stdout"], "next\n")
    }

    func testTimeoutIsBoundedAndSessionIDsRemainIsolatedAcrossRuns() async throws {
        let runtime = FakeCLIRuntime(results: [CLICommandExecutionResult(exitCode: 0), CLICommandExecutionResult(exitCode: 0)])
        let runtimeRoot = URL(fileURLWithPath: "/tmp/cloudcode-cli-runtime", isDirectory: true)
        let executor = IOSSystemExecutor(
            policy: PolicyEngine(),
            approval: FixedApprovalRequester(approved: true),
            runtime: runtime,
            runtimeRoot: runtimeRoot
        )
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let a = UUID()
        let b = UUID()
        _ = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "pwd", "cwd": "nested", "timeoutMs": "999999"], sessionID: a),
            descriptor: descriptor,
            context: context()
        )
        _ = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "pwd", "timeoutMs": "1"], sessionID: b),
            descriptor: descriptor,
            context: context()
        )
        let requests = await runtime.recordedRequests()
        let sessionA = runtimeRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(a.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
        let sessionB = runtimeRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(b.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
        let workspaceA = sessionA.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
        let workspaceB = sessionB.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].sessionID, a)
        XCTAssertEqual(requests[1].sessionID, b)
        XCTAssertEqual(requests[0].timeoutMilliseconds, 10_000)
        XCTAssertEqual(requests[1].timeoutMilliseconds, 250)
        XCTAssertEqual(requests[0].workspaceRoot.path, sessionA.path)
        XCTAssertEqual(requests[1].workspaceRoot.path, sessionB.path)
        XCTAssertNotEqual(requests[0].workspaceRoot.path, requests[1].workspaceRoot.path)
        XCTAssertEqual(requests[0].workingDirectory.path, workspaceA.appendingPathComponent("nested", isDirectory: true).path)
        XCTAssertEqual(requests[1].workingDirectory.path, workspaceB.path)
    }

    func testRepeatedExecutionDoesNotCarryForwardPriorCWD() async throws {
        let runtime = FakeCLIRuntime(results: [CLICommandExecutionResult(exitCode: 0), CLICommandExecutionResult(exitCode: 0)])
        let runtimeRoot = URL(fileURLWithPath: "/tmp/cloudcode-cli-repeat", isDirectory: true)
        let executor = IOSSystemExecutor(
            policy: PolicyEngine(),
            approval: FixedApprovalRequester(approved: true),
            runtime: runtime,
            runtimeRoot: runtimeRoot
        )
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let sessionID = UUID()
        _ = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "pwd", "cwd": "nested"], sessionID: sessionID),
            descriptor: descriptor,
            context: context()
        )
        _ = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "pwd"], sessionID: sessionID),
            descriptor: descriptor,
            context: context()
        )
        let requests = await runtime.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].workingDirectory.lastPathComponent, "nested")
        XCTAssertEqual(requests[1].workingDirectory.path, requests[1].workspaceRoot.appendingPathComponent("workspace", isDirectory: true).path)
        XCTAssertNotEqual(requests[0].workingDirectory.path, requests[1].workingDirectory.path)
    }

    func testExplicitCWDEscapingSessionWorkspaceIsRejected() async throws {
        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        do {
            _ = try await executor.execute(
                ToolCall(name: "cli.run", arguments: ["command": "pwd", "cwd": "/tmp/outside"], sessionID: UUID()),
                descriptor: descriptor,
                context: context(allowedRoot: URL(fileURLWithPath: "/tmp/inside", isDirectory: true))
            )
            XCTFail("Expected cwd escape to fail")
        } catch let error as CLICommandValidationError {
            XCTAssertEqual(error, .cwdEscapesAllowedRoot)
        }
    }

    func testCLIPathArgumentsCannotEscapeSessionSandbox() async throws {
        let runtime = FakeCLIRuntime()
        let runtimeRoot = URL(fileURLWithPath: "/tmp/cloudcode-cli-paths", isDirectory: true)
        let executor = IOSSystemExecutor(
            policy: PolicyEngine(),
            approval: FixedApprovalRequester(approved: true),
            runtime: runtime,
            runtimeRoot: runtimeRoot
        )
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        for command in ["cat /etc/passwd", "cat ../../outside", "grep needle /private/var/mobile/file"] {
            do {
                _ = try await executor.execute(
                    ToolCall(name: "cli.run", arguments: ["command": command], sessionID: UUID()),
                    descriptor: descriptor,
                    context: context()
                )
                XCTFail("Expected path confinement rejection for \(command)")
            } catch let error as CLICommandValidationError {
                guard case .pathArgumentEscapesSession = error else {
                    return XCTFail("Unexpected path error for \(command): \(error)")
                }
            }
        }
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testAdvancedShellCannotUsePathFlagsOrOperandsToEscapeCatalogBoundary() async throws {
        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "advanced.shell", summary: "", risk: .systemChange, requiredCapabilities: ["execution.ios_system"], preferredRoute: .cli)
        let commands = [
            "cp file /tmp/outside",
            "find . -newer /tmp/outside",
            "find . -exec cat file ;",
            "find . -fprint output",
            "sort -T /tmp input",
            "ls -L .",
            "cp -L source destination",
            "tail -f file",
            "grep -R needle ."
        ]
        for command in commands {
            do {
                _ = try await executor.execute(
                    ToolCall(name: "advanced.shell", arguments: ["command": command], sessionID: UUID()),
                    descriptor: descriptor,
                    context: context()
                )
                XCTFail("Expected bounded advanced shell rejection for \(command)")
            } catch is CLICommandValidationError {
                continue
            } catch is ToolRouterError {
                continue
            }
        }
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testReadOnlyUniqCannotUseSecondOperandAsOutputFile() async throws {
        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        do {
            _ = try await executor.execute(
                ToolCall(name: "cli.run", arguments: ["command": "uniq input.txt output.txt"], sessionID: UUID()),
                descriptor: descriptor,
                context: context()
            )
            XCTFail("Expected uniq output-file mutation to fail closed")
        } catch let error as CLICommandValidationError {
            guard case .readOnlyMutationNotAllowed = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testNonPathArgumentsRemainUsableInsideBoundedCLI() async throws {
        let runtime = FakeCLIRuntime(results: [CLICommandExecutionResult(exitCode: 0), CLICommandExecutionResult(exitCode: 0)])
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        let echo = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "echo /outside/is/text"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        let find = try await executor.execute(
            ToolCall(name: "cli.run", arguments: ["command": "find . -name '*.json'"], sessionID: UUID()),
            descriptor: descriptor,
            context: context()
        )
        XCTAssertTrue(echo.success)
        XCTAssertTrue(find.success)
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertEqual(recordedRequests.count, 2)
    }

    func testSymlinkPathInsideWorkspaceCannotTunnelOutsideSession() async throws {
        let fileManager = FileManager.default
        let runtimeRoot = fileManager.temporaryDirectory.appendingPathComponent("cloudcode-cli-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: runtimeRoot) }
        let sessionID = UUID()
        let workspace = runtimeRoot
            .appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        let link = workspace.appendingPathComponent("escape")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: fileManager.temporaryDirectory)

        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(
            policy: PolicyEngine(),
            approval: FixedApprovalRequester(approved: true),
            runtime: runtime,
            runtimeRoot: runtimeRoot
        )
        let descriptor = ToolDescriptor(name: "cli.run", summary: "", risk: .readOnly, requiredCapabilities: ["cli.runtime"], preferredRoute: .cli)
        do {
            _ = try await executor.execute(
                ToolCall(name: "cli.run", arguments: ["command": "cat escape/anything"], sessionID: sessionID),
                descriptor: descriptor,
                context: context()
            )
            XCTFail("Expected symlink path to fail closed")
        } catch let error as CLICommandValidationError {
            guard case .pathArgumentUnsafe = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let recordedRequests = await runtime.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testToolRegistryKeepsNativeStructuredRouteAheadOfCLIAndGUI() async throws {
        let registry = ToolRegistry()
        let filesValue = await registry.descriptor(named: "files.search")
        let cliValue = await registry.descriptor(named: "cli.run")
        let shellValue = await registry.descriptor(named: "advanced.shell")
        let guiValue = await registry.descriptor(named: "gui.tree")
        let files = try XCTUnwrap(filesValue)
        let cli = try XCTUnwrap(cliValue)
        let shell = try XCTUnwrap(shellValue)
        let gui = try XCTUnwrap(guiValue)
        XCTAssertEqual(files.preferredRoute, .structuredTool)
        XCTAssertEqual(cli.preferredRoute, .cli)
        XCTAssertEqual(shell.preferredRoute, .cli)
        XCTAssertEqual(gui.preferredRoute, .guiFallback)
        XCTAssertEqual(cli.risk, .readOnly)
        XCTAssertEqual(shell.risk, .systemChange)
    }

    func testProviderSchemaOmitsCLIWhenRuntimeCapabilityIsUnavailable() async {
        let runtime = FakeCLIRuntime()
        let executor = IOSSystemExecutor(policy: PolicyEngine(), approval: FixedApprovalRequester(approved: true), runtime: runtime)
        let registry = ToolRegistry()
        let router = ToolRouter(registry: registry, executors: [executor])
        let unavailable = await router.providerRoutableToolNames(capabilities: capabilities(runtime: .unavailable))
        XCTAssertFalse(unavailable.contains("cli.run"))
        XCTAssertFalse(unavailable.contains("advanced.shell"))

        let available = await router.providerRoutableToolNames(capabilities: capabilities())
        XCTAssertTrue(available.contains("cli.run"))
        XCTAssertTrue(available.contains("advanced.shell"))
    }

    func testStartupSafeCapabilityProbeDefersCLICatalogValidationWithoutTouchingRuntime() async {
        let runtime = FakeCLIRuntime()
        let probe = CapabilityProbe(appResolver: StaticAppResolver(), cliCapabilityProvider: runtime)
        let profile = await probe.probeStartupSafe()
        XCTAssertEqual(profile.status("execution.ios_system"), .deviceValidationRequired)
        XCTAssertEqual(profile.status("cli.runtime"), .deviceValidationRequired)
        for command in CLICommandCatalog.packagedP0 {
            XCTAssertEqual(profile.status("cli.command.\(command)"), .deviceValidationRequired)
        }
        XCTAssertEqual(profile.status("cli.command.jq"), .deviceValidationRequired)
        XCTAssertEqual(profile.status("homeos.shell"), .deviceValidationRequired)
        let capabilityRequestCount = await runtime.recordedCapabilityRequestCount()
        XCTAssertEqual(capabilityRequestCount, 0)
    }

    func testCapabilityProbeFailsClosedWhenAnyRequiredP0CommandIsMissing() async {
        let commands = CLICommandCatalog.packagedP0.subtracting(["uniq"]).sorted()
        let runtime = FakeCLIRuntime(commands: commands)
        let probe = CapabilityProbe(appResolver: StaticAppResolver(), cliCapabilityProvider: runtime)
        let profile = await probe.probeExtendedDevice()
        XCTAssertEqual(profile.status("execution.ios_system"), .unavailable)
        XCTAssertEqual(profile.status("cli.runtime"), .unavailable)
        XCTAssertEqual(profile.status("cli.command.uniq"), .unavailable)
        XCTAssertEqual(profile.status("cli.command.pwd"), .available)
        XCTAssertEqual(profile.status("homeos.shell"), .unavailable)
    }

    func testCapabilityProbeReportsPerCommandCatalogAndDoesNotClaimJQ() async {
        let runtime = FakeCLIRuntime()
        let probe = CapabilityProbe(appResolver: StaticAppResolver(), cliCapabilityProvider: runtime)
        let profile = await probe.probeExtendedDevice()
        XCTAssertEqual(profile.status("execution.ios_system"), .available)
        XCTAssertEqual(profile.status("cli.runtime"), .available)
        for command in CLICommandCatalog.packagedP0 {
            XCTAssertEqual(profile.status("cli.command.\(command)"), .available, "\(command) should be verified")
        }
        XCTAssertEqual(profile.status("cli.command.jq"), .unavailable)
        XCTAssertEqual(profile.status("homeos.shell"), .available)
        XCTAssertEqual(profile.status("homeos.script"), .unavailable)
    }
}
