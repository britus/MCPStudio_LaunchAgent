import Foundation
import os

let MCPStudioLaunchAgentMachServiceName = MCPStudioLaunchAgentIdentity.machServiceName

final class MCPStudioLaunchAgentService: NSObject, MCPStudioLaunchAgentProtocol {
    private let lock = NSLock()
    private let jobManager: MCPStudioProcessJobManager
    private let agentInstanceID: UUID
    private var negotiatedProtocolMinor: Int?
    private var clientAllowedDeveloperTools: Set<String> = []
    private let logger = Logger(
        subsystem: MCPStudioLaunchAgentIdentity.agentBundleIdentifier,
        category: "service"
    )

    init(jobManager: MCPStudioProcessJobManager = MCPStudioProcessJobManager()) {
        self.jobManager = jobManager
        agentInstanceID = UUID()
        super.init()
    }

    func hello(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= MCPStudioProcessExecutionPolicy.maximumHelloPayloadBytes else {
            reply(MCPStudioLaunchAgentWireCodec.encode(agentHello(
                accepted: false,
                protocolMinor: MCPStudioLaunchAgentProtocolMinor,
                message: "The client hello payload exceeds the V1 size limit."
            )))
            return
        }
        let clientHello: MCPStudioAgentClientHello
        do {
            clientHello = try MCPStudioLaunchAgentWireCodec.decode(MCPStudioAgentClientHello.self, from: request)
        } catch {
            reply(MCPStudioLaunchAgentWireCodec.encode(agentHello(
                accepted: false,
                protocolMinor: MCPStudioLaunchAgentProtocolMinor,
                message: "The client hello payload is invalid."
            )))
            return
        }

        guard clientHello.protocolMajor == MCPStudioLaunchAgentProtocolMajor else {
            reply(MCPStudioLaunchAgentWireCodec.encode(agentHello(
                accepted: false,
                protocolMinor: MCPStudioLaunchAgentProtocolMinor,
                message: "The client and agent protocol major versions are incompatible."
            )))
            return
        }

        let negotiatedMinor = min(clientHello.maximumProtocolMinor, MCPStudioLaunchAgentProtocolMinor)
        guard negotiatedMinor >= clientHello.minimumProtocolMinor else {
            reply(MCPStudioLaunchAgentWireCodec.encode(agentHello(
                accepted: false,
                protocolMinor: negotiatedMinor,
                message: "The client and agent protocol minor ranges do not overlap."
            )))
            return
        }

        guard negotiatedMinor >= 1, let configuredTools = clientHello.allowedDeveloperTools else {
            reply(MCPStudioLaunchAgentWireCodec.encode(agentHello(
                accepted: false,
                protocolMinor: negotiatedMinor,
                message: "Protocol 1.1 requires the client developer-tools allowlist."
            )))
            return
        }

        let sanitizedTools = MCPStudioProcessExecutionPolicy.sanitizedDeveloperToolNames(configuredTools)

        lock.lock()
        negotiatedProtocolMinor = negotiatedMinor
        clientAllowedDeveloperTools = sanitizedTools
        lock.unlock()

        logger.info("Negotiated protocol 1.\(negotiatedMinor, privacy: .public) with client instance \(clientHello.clientInstanceID.uuidString, privacy: .public).")
        reply(MCPStudioLaunchAgentWireCodec.encode(agentHello(
            accepted: true,
            protocolMinor: negotiatedMinor,
            message: nil
        )))
    }

    func submit(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        guard request.count <= MCPStudioProcessExecutionPolicy.maximumRequestPayloadBytes else {
            reply(MCPStudioLaunchAgentWireCodec.encode(MCPStudioProcessJobAccepted(
                accepted: false,
                requestID: UUID(),
                state: nil,
                errorCode: "request_too_large",
                message: "The process request payload exceeds the V1 size limit."
            )))
            return
        }
        guard isHandshakeComplete else {
            let requestID = (try? MCPStudioLaunchAgentWireCodec.decode(
                MCPStudioProcessExecutionRequest.self,
                from: request
            ).requestID) ?? UUID()
            reply(MCPStudioLaunchAgentWireCodec.encode(MCPStudioProcessJobAccepted(
                accepted: false,
                requestID: requestID,
                state: nil,
                errorCode: "handshake_required",
                message: "A successful protocol handshake is required before submitting work."
            )))
            return
        }

        let executionRequest: MCPStudioProcessExecutionRequest
        do {
            executionRequest = try MCPStudioLaunchAgentWireCodec.decode(
                MCPStudioProcessExecutionRequest.self,
                from: request
            )
        } catch {
            reply(MCPStudioLaunchAgentWireCodec.encode(MCPStudioProcessJobAccepted(
                accepted: false,
                requestID: UUID(),
                state: nil,
                errorCode: "invalid_request",
                message: "The process request payload is invalid."
            )))
            return
        }

        lock.lock()
        let allowedTools = clientAllowedDeveloperTools
        lock.unlock()
        reply(MCPStudioLaunchAgentWireCodec.encode(jobManager.submit(
            executionRequest,
            clientAllowedDeveloperTools: allowedTools
        )))
    }

    func status(_ requestID: String, withReply reply: @escaping (Data) -> Void) {
        guard let identifier = UUID(uuidString: requestID) else {
            reply(MCPStudioLaunchAgentWireCodec.encode(MCPStudioProcessJobStatus(
                requestID: UUID(),
                state: nil,
                result: nil,
                errorCode: "invalid_request_id",
                message: "The request identifier is invalid."
            )))
            return
        }
        reply(MCPStudioLaunchAgentWireCodec.encode(jobManager.status(requestID: identifier)))
    }

    func cancel(_ requestID: String, withReply reply: @escaping (Data) -> Void) {
        guard let identifier = UUID(uuidString: requestID) else {
            reply(MCPStudioLaunchAgentWireCodec.encode(MCPStudioProcessCancelResult(
                requestID: UUID(),
                accepted: false,
                message: "The request identifier is invalid."
            )))
            return
        }
        reply(MCPStudioLaunchAgentWireCodec.encode(jobManager.cancel(requestID: identifier)))
    }

    private var isHandshakeComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return negotiatedProtocolMinor != nil
    }

    private func agentHello(accepted: Bool, protocolMinor: Int, message: String?) -> MCPStudioAgentHello {
        let info = Bundle.main.infoDictionary ?? [:]
        return MCPStudioAgentHello(
            accepted: accepted,
            protocolMajor: MCPStudioLaunchAgentProtocolMajor,
            protocolMinor: protocolMinor,
            agentVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            agentBuild: info["CFBundleVersion"] as? String ?? "unknown",
            agentInstanceID: agentInstanceID,
            capabilities: MCPStudioLaunchAgentCapability.allCases,
            policyVersion: MCPStudioProcessExecutionPolicy.policyVersion,
            maximumTimeoutSeconds: MCPStudioProcessExecutionPolicy.maximumTimeoutSeconds,
            maximumOutputBytes: MCPStudioProcessExecutionPolicy.maximumOutputBytes,
            message: message
        )
    }
}

final class MCPStudioLaunchAgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let jobManager = MCPStudioProcessJobManager()
    private let logger = Logger(
        subsystem: MCPStudioLaunchAgentIdentity.agentBundleIdentifier,
        category: "xpc"
    )

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid() else {
            logger.error("Rejected XPC connection from uid \(connection.effectiveUserIdentifier, privacy: .public).")
            return false
        }

        connection.setCodeSigningRequirement(MCPStudioLaunchAgentIdentity.hostSigningRequirement)
        connection.exportedInterface = NSXPCInterface(with: MCPStudioLaunchAgentProtocol.self)
        connection.exportedObject = MCPStudioLaunchAgentService(jobManager: jobManager)
        connection.invalidationHandler = { [logger] in
            logger.debug("Connection invalidated.")
        }
        connection.interruptionHandler = { [logger] in
            logger.debug("Connection interrupted.")
        }
        connection.resume()
        logger.debug("Accepted authenticated XPC connection for uid \(connection.effectiveUserIdentifier, privacy: .public).")
        return true
    }
}
