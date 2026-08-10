import Foundation

enum MCPStudioLaunchAgentIdentity {
    static let displayName = "EoF MCP Studio Launch Agent"
    static let hostApplicationBundleIdentifier = "org.eof.tools.MCPStudio"
    static let agentBundleIdentifier = "org.eof.tools.MCPStudio.LaunchAgent"
    static let applicationGroupIdentifier = "group.org.eof.apps"
    static let launchdLabel = agentBundleIdentifier
    static let machServiceName = "group.org.eof.apps.mcpstudio.agent"
}
