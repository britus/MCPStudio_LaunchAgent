import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import MCPStudioLaunchAgent
#endif

final class IdentityConsistencyTests: XCTestCase {
    func testProductIdentityMatchesMCPStudioConventions() {
        XCTAssertEqual(MCPStudioLaunchAgentIdentity.displayName, "EoF MCP Studio Launch Agent")
        XCTAssertEqual(MCPStudioLaunchAgentIdentity.hostApplicationBundleIdentifier, "org.eof.tools.MCPStudio")
        XCTAssertEqual(MCPStudioLaunchAgentIdentity.agentBundleIdentifier, "org.eof.tools.MCPStudio.LaunchAgent")
        XCTAssertEqual(MCPStudioLaunchAgentIdentity.applicationGroupIdentifier, "group.org.eof.apps")
        XCTAssertEqual(
            MCPStudioLaunchAgentIdentity.launchdLabel,
            MCPStudioLaunchAgentIdentity.agentBundleIdentifier
        )
        XCTAssertTrue(
            MCPStudioLaunchAgentIdentity.machServiceName.hasPrefix(
                MCPStudioLaunchAgentIdentity.applicationGroupIdentifier + "."
            )
        )
    }

    func testLaunchdPropertyListUsesCanonicalIdentifiers() throws {
        let data = try Data(contentsOf: projectRoot
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("org.eof.tools.MCPStudio.LaunchAgent.plist.template"))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        let propertyList = try XCTUnwrap(value as? [String: Any])

        XCTAssertEqual(propertyList["Label"] as? String, MCPStudioLaunchAgentIdentity.launchdLabel)

        let services = try XCTUnwrap(propertyList["MachServices"] as? [String: Any])
        XCTAssertEqual(Set(services.keys), [MCPStudioLaunchAgentIdentity.machServiceName])
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
