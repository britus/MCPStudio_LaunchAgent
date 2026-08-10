import Foundation

enum MCPStudioLaunchAgentIdentity {
    static let displayName = "EoF MCP Studio Launch Agent"
    static let teamIdentifier = "83NQU389JN"
    static let hostApplicationBundleIdentifier = "org.eof.tools.MCPStudio"
    static let agentBundleIdentifier = "org.eof.tools.MCPStudio.LaunchAgent"
    static let applicationGroupIdentifier = "group.org.eof.apps"
    static let launchdLabel = agentBundleIdentifier
    static let machServiceName = "group.org.eof.apps.mcpstudio.agent"

    static let hostSigningRequirement = signingRequirement(
        bundleIdentifier: hostApplicationBundleIdentifier
    )
    static let agentSigningRequirement = signingRequirement(
        bundleIdentifier: agentBundleIdentifier
    )

    private static func signingRequirement(bundleIdentifier: String) -> String {
        "identifier \"\(bundleIdentifier)\" and anchor apple generic " +
        "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}
