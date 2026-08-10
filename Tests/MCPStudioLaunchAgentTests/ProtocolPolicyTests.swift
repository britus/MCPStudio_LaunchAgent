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
}
