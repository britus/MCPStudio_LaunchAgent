import Foundation

let MCPStudioLaunchAgentProtocolMajor = 1
let MCPStudioLaunchAgentProtocolMinor = 2

enum MCPStudioLaunchAgentCapability: String, Codable, CaseIterable {
    case nodeRuntime = "runtime.node"
    case pythonRuntime = "runtime.python"
    case developerTools = "developer.tools"
    case jobStatus = "job.status"
    case jobCancellation = "job.cancel"
}

enum MCPStudioProcessRuntime: String, Codable {
    case node
    case python
    case developerTool
}

enum MCPStudioProcessSourceKind: String, Codable {
    case none
    case path
    case inline
}

enum MCPStudioProcessJobState: String, Codable {
    case accepted
    case running
    case completed
}

enum MCPStudioProcessTerminationReason: String, Codable {
    case exited
    case signaled
    case timedOut
    case cancelled
    case outputLimitExceeded
    case policyDenied
    case launchFailed
}

struct MCPStudioAgentClientHello: Codable, Equatable {
    let protocolMajor: Int
    let minimumProtocolMinor: Int
    let maximumProtocolMinor: Int
    let clientVersion: String
    let clientBuild: String
    let clientInstanceID: UUID
    let requestedCapabilities: [MCPStudioLaunchAgentCapability]
    let allowedExecutableRoots: [String]?
    let allowedCommands: [String]?
}

struct MCPStudioAgentHello: Codable, Equatable {
    let accepted: Bool
    let protocolMajor: Int
    let protocolMinor: Int
    let agentVersion: String
    let agentBuild: String
    let agentInstanceID: UUID
    let capabilities: [MCPStudioLaunchAgentCapability]
    let allowedExecutableRoots: [String]
    let allowedCommands: [String]
    let policyVersion: Int
    let maximumTimeoutSeconds: Double
    let maximumOutputBytes: Int
    let message: String?
}

struct MCPStudioProcessExecutionRequest: Codable, Equatable {
    let requestID: UUID
    let conversationID: String
    let toolID: String
    let policyProfileID: String
    let runtime: MCPStudioProcessRuntime
    let executableHint: String?
    let sourceKind: MCPStudioProcessSourceKind
    let source: String?
    let arguments: [String]
    let workingDirectory: String?
    let environment: [String: String]
    let standardInput: Data?
    let timeoutSeconds: Double
    let outputLimitBytes: Int
}

struct MCPStudioProcessJobAccepted: Codable, Equatable {
    let accepted: Bool
    let requestID: UUID
    let state: MCPStudioProcessJobState?
    let errorCode: String?
    let message: String?
}

struct MCPStudioProcessExecutionResult: Codable, Equatable {
    let requestID: UUID
    let terminationReason: MCPStudioProcessTerminationReason
    let exitCode: Int32?
    let signal: Int32?
    let standardOutput: Data
    let standardError: Data
    let outputTruncated: Bool
    let resolvedExecutable: String?
    let startedAt: TimeInterval?
    let durationSeconds: Double
    let message: String?

    var succeeded: Bool {
        terminationReason == .exited && exitCode == 0
    }
}

struct MCPStudioProcessJobStatus: Codable, Equatable {
    let requestID: UUID
    let state: MCPStudioProcessJobState?
    let result: MCPStudioProcessExecutionResult?
    let errorCode: String?
    let message: String?
}

struct MCPStudioProcessCancelResult: Codable, Equatable {
    let requestID: UUID
    let accepted: Bool
    let message: String?
}

enum MCPStudioLaunchAgentWireCodec {
    static func encode<T: Encodable>(_ value: T) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            return Data()
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

@objc(MCPStudioLaunchAgentProtocol)
protocol MCPStudioLaunchAgentProtocol {
    func hello(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func submit(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func status(_ requestID: String, withReply reply: @escaping (Data) -> Void)
    func cancel(_ requestID: String, withReply reply: @escaping (Data) -> Void)
}
