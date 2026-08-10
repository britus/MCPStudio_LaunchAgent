import Foundation
import os

/// Mach service name of this agent, registered by launchd in the gui domain
/// of the logged-in user (see MachServices in the launchd plist).
/// The host app connects to this name with `NSXPCConnection(machServiceName:options:)`
/// using the default (non-privileged) options for a user-session service.
let MCPStudioLaunchAgentMachServiceName = MCPStudioLaunchAgentIdentity.machServiceName

/// XPC protocol shared between the agent and the host app.
///
/// Classic XPC pattern: both sides declare the same @objc protocol
/// (no shared framework needed between the app and an externally
/// installed agent). Keep the interface in sync on both sides.
@objc(MCPStudioLaunchAgentProtocol)
protocol MCPStudioLaunchAgentProtocol {
    /// Lightweight liveness check.
    func ping(reply: @escaping (String) -> Void)

    /// Proof-of-concept task executed in the context of the user session.
    func performTask(_ task: String, reply: @escaping (Bool, String) -> Void)
}

/// Business logic of the agent.
///
/// Runs with the identity and session of the logged-in user:
/// Aqua session access, user keychain, user defaults, user-writable paths.
/// No root privileges (that would require a LaunchDaemon in the system domain).
final class MCPStudioLaunchAgentService: NSObject, MCPStudioLaunchAgentProtocol {

    private let logger = Logger(
        subsystem: MCPStudioLaunchAgentIdentity.agentBundleIdentifier,
        category: "service"
    )

    func ping(reply: @escaping (String) -> Void) {
        logger.debug("ping")
        reply("pong (pid=\(getpid()), uid=\(getuid()))")
    }

    func performTask(_ task: String, reply: @escaping (Bool, String) -> Void) {
        logger.info("performTask: \(task, privacy: .public)")
        // Demo implementation: prove that we run inside the user session.
        let info = "user=\(NSUserName()) uid=\(getuid()) pid=\(getpid()) task=\(task)"
        reply(true, info)
    }
}

/// Accepts incoming XPC connections to the agent's Mach service.
final class MCPStudioLaunchAgentListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let logger = Logger(
        subsystem: MCPStudioLaunchAgentIdentity.agentBundleIdentifier,
        category: "xpc"
    )

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MCPStudioLaunchAgentProtocol.self)
        connection.exportedObject = MCPStudioLaunchAgentService()

        connection.invalidationHandler = { [logger] in
            logger.debug("Connection invalidated.")
        }
        connection.interruptionHandler = { [logger] in
            // The peer crashed or the connection was interrupted;
            // the next request from the client will create a new connection.
            logger.debug("Connection interrupted.")
        }

        connection.resume()
        logger.debug("Accepted new XPC connection.")
        return true
    }
}
