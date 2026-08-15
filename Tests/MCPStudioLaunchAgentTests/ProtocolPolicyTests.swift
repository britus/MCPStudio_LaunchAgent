import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import MCPStudioLaunchAgent
#endif

final class ProtocolPolicyTests: XCTestCase {
    func testProtocolHandshakeAppliesHostPolicyToSubmittedTidyRequest() throws {
        let service = MCPStudioLaunchAgentService()
        let helloRequest = MCPStudioAgentClientHello(
            protocolMajor: MCPStudioLaunchAgentProtocolMajor,
            minimumProtocolMinor: 2,
            maximumProtocolMinor: MCPStudioLaunchAgentProtocolMinor,
            clientVersion: "test",
            clientBuild: "1",
            clientInstanceID: UUID(),
            requestedCapabilities: [.developerTools],
            allowedExecutableRoots: ["/usr/bin"],
            allowedCommands: ["tidy"]
        )

        var helloData = Data()
        service.hello(MCPStudioLaunchAgentWireCodec.encode(helloRequest)) {
            helloData = $0
        }
        let hello = try MCPStudioLaunchAgentWireCodec.decode(
            MCPStudioAgentHello.self,
            from: helloData
        )
        XCTAssertTrue(hello.accepted)
        XCTAssertEqual(hello.protocolMinor, 2)
        XCTAssertEqual(hello.allowedExecutableRoots, ["/usr/bin"])
        XCTAssertEqual(hello.allowedCommands, ["tidy"])

        let request = developerToolRequest(executable: "/usr/bin/tidy")
        var acceptedData = Data()
        service.submit(MCPStudioLaunchAgentWireCodec.encode(request)) {
            acceptedData = $0
        }
        let accepted = try MCPStudioLaunchAgentWireCodec.decode(
            MCPStudioProcessJobAccepted.self,
            from: acceptedData
        )

        XCTAssertTrue(accepted.accepted)
        let deadline = Date().addingTimeInterval(5)
        var executionResult: MCPStudioProcessExecutionResult?
        while Date() < deadline, executionResult == nil {
            var statusData = Data()
            service.status(accepted.requestID.uuidString) {
                statusData = $0
            }
            let status = try MCPStudioLaunchAgentWireCodec.decode(
                MCPStudioProcessJobStatus.self,
                from: statusData
            )
            executionResult = status.result
            if executionResult == nil {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        XCTAssertEqual(executionResult?.resolvedExecutable, "/usr/bin/tidy")
        XCTAssertEqual(executionResult?.terminationReason, .exited)
    }

    func testProtocolRequestRoundTripsThroughWireCodec() throws {
        let request = MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.node",
            policyProfileID: "runtime.node.v1",
            runtime: .node,
            executableHint: nil,
            sourceKind: .inline,
            source: "console.log('ok')",
            arguments: ["one"],
            workingDirectory: NSHomeDirectory(),
            environment: ["LANG": "de_DE.UTF-8"],
            standardInput: Data("input".utf8),
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )

        let encoded = MCPStudioLaunchAgentWireCodec.encode(request)
        let decoded = try MCPStudioLaunchAgentWireCodec.decode(
            MCPStudioProcessExecutionRequest.self,
            from: encoded
        )
        XCTAssertEqual(decoded, request)
    }

    func testEnvironmentDropsUnapprovedAndDynamicLoaderValues() {
        let environment = MCPStudioProcessExecutionPolicy.sanitizedEnvironment([
            "LANG": "de_DE.UTF-8",
            "API_TOKEN": "secret",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib"
        ])

        XCTAssertEqual(environment["LANG"], "de_DE.UTF-8")
        XCTAssertNil(environment["API_TOKEN"])
        XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
    }

    func testDeveloperToolPolicyRejectsShellExecutable() {
        let request = MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.shell",
            policyProfileID: "developer.tools.v1",
            runtime: .developerTool,
            executableHint: "/bin/sh",
            sourceKind: .none,
            source: nil,
            arguments: ["-c", "echo unsafe"],
            workingDirectory: NSHomeDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )

        XCTAssertThrowsError(try MCPStudioProcessExecutionPolicy.validate(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["tidy"], roots: ["/usr/bin"])
        )) { error in
            XCTAssertEqual((error as? MCPStudioProcessPolicyError)?.code, "tool_not_allowed")
        }
    }

    func testDeveloperToolPolicyUsesNegotiatedHostPolicyForTidy() throws {
        let request = developerToolRequest(executable: "/usr/bin/tidy")

        let validated = try MCPStudioProcessExecutionPolicy.validate(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["tidy"], roots: ["/usr/bin"])
        )

        XCTAssertEqual(validated.executableURL.path, "/usr/bin/tidy")
    }

    func testDeveloperToolPolicyRejectsTidyWhenClientDisablesIt() {
        let request = developerToolRequest(executable: "/usr/bin/tidy")

        XCTAssertThrowsError(try MCPStudioProcessExecutionPolicy.validate(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["xcodebuild"], roots: ["/usr/bin"])
        )) { error in
            XCTAssertEqual((error as? MCPStudioProcessPolicyError)?.code, "tool_not_allowed")
        }
    }

    func testNegotiatedPolicyUsesOnlyStructurallyValidHostValues() {
        let policy = MCPStudioProcessExecutionPolicy.sanitizedHostOSCommandPolicy(
            executableRoots: ["/usr/bin", "relative/bin"],
            commands: ["tidy", "sh", "gcc-3*", "*", "bad command", "/usr/bin/git"]
        )

        XCTAssertEqual(policy.executableRoots, ["/usr/bin"])
        XCTAssertEqual(policy.commands, ["gcc-3*", "sh", "tidy"])
    }

    func testPolicyRejectsSensitiveWorkingDirectory() {
        let request = MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.git",
            policyProfileID: "developer.tools.v1",
            runtime: .developerTool,
            executableHint: "/usr/bin/git",
            sourceKind: .none,
            source: nil,
            arguments: ["status"],
            workingDirectory: NSHomeDirectory() + "/.ssh",
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )

        XCTAssertThrowsError(try MCPStudioProcessExecutionPolicy.validate(request)) { error in
            XCTAssertEqual((error as? MCPStudioProcessPolicyError)?.code, "working_directory_denied")
        }
    }

    func testPythonInlineSourceUsesPythonCommandFlag() throws {
        let request = MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.python",
            policyProfileID: "runtime.python.v1",
            runtime: .python,
            executableHint: "/usr/bin/python3",
            sourceKind: .inline,
            source: "print('ok')",
            arguments: ["one"],
            workingDirectory: NSHomeDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )

        let validated = try MCPStudioProcessExecutionPolicy.validate(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["python3"], roots: ["/usr/bin"])
        )
        XCTAssertEqual(validated.arguments, ["-c", "print('ok')", "one"])
    }

    func testPython3CommandAllowsVersionedCanonicalSymlinkTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PythonPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let versionedExecutable = root.appendingPathComponent("python3.16")
        XCTAssertTrue(FileManager.default.createFile(atPath: versionedExecutable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: versionedExecutable.path
        )
        let python3Link = root.appendingPathComponent("python3")
        try FileManager.default.createSymbolicLink(at: python3Link, withDestinationURL: versionedExecutable)

        let request = MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.python",
            policyProfileID: "runtime.python.v1",
            runtime: .python,
            executableHint: python3Link.path,
            sourceKind: .inline,
            source: "print('ok')",
            arguments: [],
            workingDirectory: NSHomeDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )

        let validated = try MCPStudioProcessExecutionPolicy.validate(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["python3*"], roots: [root.path])
        )

        XCTAssertEqual(validated.executableURL.lastPathComponent, "python3.16")
    }

    func testExplicitPrefixRuleAllowsVersionedDeveloperToolName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandPrefixPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("gcc-3.21-2x")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let validated = try MCPStudioProcessExecutionPolicy.validate(
            developerToolRequest(executable: executable.path),
            hostOSCommandPolicy: hostPolicy(commands: ["gcc-3*"], roots: [root.path])
        )

        XCTAssertEqual(validated.executableURL.lastPathComponent, "gcc-3.21-2x")
    }

    func testHomebrewRuntimeSymlinkRemainsWithinApprovedInstallationRoot() throws {
        let nodePath = "/opt/homebrew/bin/node"
        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            throw XCTSkip("Homebrew Node.js is not installed on this test host.")
        }
        let request = MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.node",
            policyProfileID: "runtime.node.v1",
            runtime: .node,
            executableHint: nodePath,
            sourceKind: .inline,
            source: "console.log('ok')",
            arguments: [],
            workingDirectory: NSHomeDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )

        let validated = try MCPStudioProcessExecutionPolicy.validate(
            request,
            hostOSCommandPolicy: hostPolicy(
                commands: ["node"],
                roots: ["/opt/homebrew/bin", "/opt/homebrew/Cellar"]
            )
        )
        XCTAssertTrue(validated.executableURL.path.contains("/opt/homebrew/Cellar/node/"))
    }

    func testJobManagerExecutesTypedPythonRequest() throws {
        let manager = MCPStudioProcessJobManager()
        let request = pythonRequest(source: "print('agent-ok')", timeout: 10)

        XCTAssertTrue(manager.submit(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["python3"], roots: ["/usr/bin"])
        ).accepted)
        let result = try waitForResult(requestID: request.requestID, manager: manager)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "agent-ok\n")
        XCTAssertEqual(result.resolvedExecutable, "/usr/bin/python3")
    }

    func testJobManagerEnforcesTimeout() throws {
        let manager = MCPStudioProcessJobManager()
        let request = pythonRequest(source: "import time; time.sleep(3)", timeout: 1)

        XCTAssertTrue(manager.submit(
            request,
            hostOSCommandPolicy: hostPolicy(commands: ["python3"], roots: ["/usr/bin"])
        ).accepted)
        let result = try waitForResult(requestID: request.requestID, manager: manager)

        XCTAssertEqual(result.terminationReason, .timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testJobManagerRejectsWorkAboveConcurrencyLimit() {
        let manager = MCPStudioProcessJobManager()
        var acceptedRequestIDs: [UUID] = []

        for _ in 0..<MCPStudioProcessExecutionPolicy.maximumConcurrentJobs {
            let request = pythonRequest(source: "import time; time.sleep(3)", timeout: 10)
            XCTAssertTrue(manager.submit(
                request,
                hostOSCommandPolicy: hostPolicy(commands: ["python3"], roots: ["/usr/bin"])
            ).accepted)
            acceptedRequestIDs.append(request.requestID)
        }

        let rejected = manager.submit(
            pythonRequest(source: "print('too-many')", timeout: 10),
            hostOSCommandPolicy: hostPolicy(commands: ["python3"], roots: ["/usr/bin"])
        )
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.errorCode, "agent_busy")

        for requestID in acceptedRequestIDs {
            _ = manager.cancel(requestID: requestID)
        }
    }

    private func pythonRequest(source: String, timeout: Double) -> MCPStudioProcessExecutionRequest {
        MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.python",
            policyProfileID: "runtime.python.v1",
            runtime: .python,
            executableHint: "/usr/bin/python3",
            sourceKind: .inline,
            source: source,
            arguments: [],
            workingDirectory: NSHomeDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: timeout,
            outputLimitBytes: 1024 * 1024
        )
    }

    private func hostPolicy(commands: Set<String>, roots: [String]) -> MCPStudioHostOSCommandPolicy {
        MCPStudioHostOSCommandPolicy(executableRoots: roots, commands: commands)
    }

    private func developerToolRequest(executable: String) -> MCPStudioProcessExecutionRequest {
        MCPStudioProcessExecutionRequest(
            requestID: UUID(),
            conversationID: "conversation",
            toolID: "org.eof.tests.developer-tool",
            policyProfileID: "developer.tools.v1",
            runtime: .developerTool,
            executableHint: executable,
            sourceKind: .none,
            source: nil,
            arguments: ["-v"],
            workingDirectory: NSHomeDirectory(),
            environment: [:],
            standardInput: nil,
            timeoutSeconds: 30,
            outputLimitBytes: 1024
        )
    }

    private func waitForResult(
        requestID: UUID,
        manager: MCPStudioProcessJobManager,
        timeout: TimeInterval = 5
    ) throws -> MCPStudioProcessExecutionResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = manager.status(requestID: requestID)
            if let result = status.result {
                return result
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("The process job did not complete before the test deadline.")
        throw CocoaError(.coderReadCorrupt)
    }
}
