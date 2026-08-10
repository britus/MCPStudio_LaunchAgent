import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import MCPStudioLaunchAgent
#endif

final class ProtocolPolicyTests: XCTestCase {
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

        XCTAssertThrowsError(try MCPStudioProcessExecutionPolicy.validate(request)) { error in
            XCTAssertEqual((error as? MCPStudioProcessPolicyError)?.code, "tool_not_allowed")
        }
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

        let validated = try MCPStudioProcessExecutionPolicy.validate(request)
        XCTAssertEqual(validated.arguments, ["-c", "print('ok')", "one"])
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

        let validated = try MCPStudioProcessExecutionPolicy.validate(request)
        XCTAssertTrue(validated.executableURL.path.contains("/opt/homebrew/Cellar/node/"))
    }

    func testJobManagerExecutesTypedPythonRequest() throws {
        let manager = MCPStudioProcessJobManager()
        let request = pythonRequest(source: "print('agent-ok')", timeout: 10)

        XCTAssertTrue(manager.submit(request).accepted)
        let result = try waitForResult(requestID: request.requestID, manager: manager)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), "agent-ok\n")
        XCTAssertEqual(result.resolvedExecutable, "/usr/bin/python3")
    }

    func testJobManagerEnforcesTimeout() throws {
        let manager = MCPStudioProcessJobManager()
        let request = pythonRequest(source: "import time; time.sleep(3)", timeout: 1)

        XCTAssertTrue(manager.submit(request).accepted)
        let result = try waitForResult(requestID: request.requestID, manager: manager)

        XCTAssertEqual(result.terminationReason, .timedOut)
        XCTAssertFalse(result.succeeded)
    }

    func testJobManagerRejectsWorkAboveConcurrencyLimit() {
        let manager = MCPStudioProcessJobManager()
        var acceptedRequestIDs: [UUID] = []

        for _ in 0..<MCPStudioProcessExecutionPolicy.maximumConcurrentJobs {
            let request = pythonRequest(source: "import time; time.sleep(3)", timeout: 10)
            XCTAssertTrue(manager.submit(request).accepted)
            acceptedRequestIDs.append(request.requestID)
        }

        let rejected = manager.submit(pythonRequest(source: "print('too-many')", timeout: 10))
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
