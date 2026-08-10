import Foundation
import os

// Entry point of the user-session launch agent.
//
// Lifecycle model (launchd, gui domain):
// - The job is registered per user session via ~/Library/LaunchAgents.
// - launchd starts the process (RunAtLoad) and restarts it on crash (KeepAlive).
// - launchd sends SIGTERM on `launchctl bootout`; we shut down cleanly.

private let logger = Logger(
    subsystem: MCPStudioLaunchAgentIdentity.agentBundleIdentifier,
    category: "main"
)

// The default SIGTERM handler must be ignored before a dispatch
// signal source can take over the signal.
signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigtermSource.setEventHandler {
    logger.info("Received SIGTERM, shutting down.")
    exit(EXIT_SUCCESS)
}
sigtermSource.resume()

// Vend the XPC Mach service that launchd registered for this job
// (see the MachServices key in the launchd plist).
let listener = NSXPCListener(machServiceName: MCPStudioLaunchAgentMachServiceName)
let delegate = MCPStudioLaunchAgentListenerDelegate()
listener.delegate = delegate
listener.resume()

logger.info("EoF MCP Studio Launch Agent started (uid=\(getuid()), pid=\(getpid())).")

// Keep the process alive; launchd owns the lifecycle.
dispatchMain()
