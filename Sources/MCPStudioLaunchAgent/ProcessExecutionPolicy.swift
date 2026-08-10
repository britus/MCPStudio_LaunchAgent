import Foundation

struct MCPStudioValidatedProcessRequest {
    let request: MCPStudioProcessExecutionRequest
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let environment: [String: String]
}

struct MCPStudioProcessPolicyError: Error, Equatable {
    let code: String
    let message: String
}

enum MCPStudioProcessExecutionPolicy {
    static let policyVersion = 1
    static let maximumTimeoutSeconds = 600.0
    static let maximumOutputBytes = 10 * 1024 * 1024
    static let maximumInputBytes = 5 * 1024 * 1024
    static let maximumInlineSourceBytes = 1024 * 1024

    private static let nodeProfile = "runtime.node.v1"
    private static let pythonProfile = "runtime.python.v1"
    private static let developerToolsProfile = "developer.tools.v1"

    private static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        "SDKROOT", "DEVELOPER_DIR", "CC", "CXX", "CPATH",
        "LIBRARY_PATH", "PKG_CONFIG_PATH"
    ]

    private static let allowedDeveloperTools: Set<String> = [
        "ar", "clang", "clang++", "cmake", "codesign", "gcc", "g++",
        "git", "ld", "lipo", "make", "ninja", "otool", "pkg-config",
        "qmake", "security", "swift", "swiftc", "xcodebuild", "xcrun"
    ]

    private static let executableRoots = [
        "/Applications/Xcode.app/Contents/Developer/usr/bin",
        "/Applications/Xcode.app/Contents/Developer/Toolchains",
        "/Library/Developer/CommandLineTools/usr/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/Cellar",
        "/usr/local/bin",
        "/usr/local/Cellar",
        "/opt/local/bin",
        "/usr/bin",
        "/bin"
    ]

    static func validate(_ request: MCPStudioProcessExecutionRequest) throws -> MCPStudioValidatedProcessRequest {
        try validateCommonLimits(request)

        let workingDirectoryURL = try validatedWorkingDirectory(request.workingDirectory)
        let environment = sanitizedEnvironment(request.environment)

        switch request.runtime {
        case .node:
            guard request.policyProfileID == nodeProfile else {
                throw denied("profile_mismatch", "The Node.js request does not use the V1 Node.js policy profile.")
            }
            let executable = try resolveRuntimeExecutable(
                hint: request.executableHint,
                acceptedNames: { $0 == "node" || $0 == "nodejs" },
                candidates: ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            )
            let arguments = try runtimeArguments(for: request, inlineFlag: "-e")
            return validated(request, executable, arguments, workingDirectoryURL, environment)

        case .python:
            guard request.policyProfileID == pythonProfile else {
                throw denied("profile_mismatch", "The Python request does not use the V1 Python policy profile.")
            }
            let executable = try resolveRuntimeExecutable(
                hint: request.executableHint,
                acceptedNames: { $0 == "python" || $0.hasPrefix("python3") },
                candidates: ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            )
            let arguments = try runtimeArguments(for: request, inlineFlag: "-c")
            return validated(request, executable, arguments, workingDirectoryURL, environment)

        case .developerTool:
            guard request.policyProfileID == developerToolsProfile else {
                throw denied("profile_mismatch", "The process request does not use the V1 developer-tools policy profile.")
            }
            guard request.sourceKind == .none, request.source == nil else {
                throw denied("source_not_allowed", "Developer-tool requests cannot contain inline or path-based source code.")
            }
            guard let hint = request.executableHint, !hint.isEmpty else {
                throw denied("missing_executable", "A developer-tool request requires an absolute executable path.")
            }
            let executable = try validatedDeveloperTool(hint)
            return validated(request, executable, request.arguments, workingDirectoryURL, environment)
        }
    }

    static func sanitizedEnvironment(_ requested: [String: String]) -> [String: String] {
        var environment: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8"
        ]

        for (key, value) in requested where allowedEnvironmentKeys.contains(key) {
            guard value.utf8.count <= 64 * 1024 else { continue }
            environment[key] = value
        }
        return environment
    }

    private static func validated(
        _ request: MCPStudioProcessExecutionRequest,
        _ executableURL: URL,
        _ arguments: [String],
        _ workingDirectoryURL: URL,
        _ environment: [String: String]
    ) -> MCPStudioValidatedProcessRequest {
        MCPStudioValidatedProcessRequest(
            request: request,
            executableURL: executableURL,
            arguments: arguments,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment
        )
    }

    private static func validateCommonLimits(_ request: MCPStudioProcessExecutionRequest) throws {
        guard !request.toolID.isEmpty, request.toolID.utf8.count <= 512 else {
            throw denied("invalid_tool", "The request contains an invalid tool identifier.")
        }
        guard request.conversationID.utf8.count <= 512 else {
            throw denied("invalid_conversation", "The request contains an invalid conversation identifier.")
        }
        guard request.arguments.count <= 256 else {
            throw denied("too_many_arguments", "The request exceeds the maximum argument count.")
        }
        let argumentBytes = request.arguments.reduce(0) { $0 + $1.utf8.count }
        guard argumentBytes <= 1024 * 1024 else {
            throw denied("arguments_too_large", "The request arguments exceed the V1 size limit.")
        }
        guard request.environment.count <= 64 else {
            throw denied("environment_too_large", "The request environment exceeds the V1 entry limit.")
        }
        guard (1...maximumTimeoutSeconds).contains(request.timeoutSeconds) else {
            throw denied("invalid_timeout", "The timeout must be between 1 and 600 seconds.")
        }
        guard (1...maximumOutputBytes).contains(request.outputLimitBytes) else {
            throw denied("invalid_output_limit", "The output limit exceeds the V1 policy.")
        }
        guard (request.standardInput?.count ?? 0) <= maximumInputBytes else {
            throw denied("input_too_large", "Standard input exceeds the V1 size limit.")
        }
    }

    private static func runtimeArguments(
        for request: MCPStudioProcessExecutionRequest,
        inlineFlag: String
    ) throws -> [String] {
        guard let source = request.source, !source.isEmpty else {
            throw denied("missing_source", "A Python or Node.js request requires source code or a script path.")
        }

        switch request.sourceKind {
        case .inline:
            guard source.utf8.count <= maximumInlineSourceBytes else {
                throw denied("inline_source_too_large", "Inline source exceeds the V1 size limit.")
            }
            return [inlineFlag, source] + request.arguments
        case .path:
            let scriptURL = try validatedUserFile(source)
            return [scriptURL.path] + request.arguments
        case .none:
            throw denied("missing_source_kind", "A Python or Node.js request requires an explicit source kind.")
        }
    }

    private static func resolveRuntimeExecutable(
        hint: String?,
        acceptedNames: (String) -> Bool,
        candidates: [String]
    ) throws -> URL {
        if let hint, !hint.isEmpty {
            guard hint.hasPrefix("/") else {
                throw denied("invalid_runtime", "Runtime executable hints must be absolute paths.")
            }
            let url = canonicalURL(hint)
            guard acceptedNames(url.lastPathComponent), isAllowedExecutableURL(url) else {
                throw denied("invalid_runtime", "The requested runtime executable is not allowed by the V1 policy.")
            }
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw denied("runtime_unavailable", "The requested runtime executable is not available.")
            }
            return url
        }

        for candidate in candidates {
            let url = canonicalURL(candidate)
            if acceptedNames(url.lastPathComponent),
               isAllowedExecutableURL(url),
               FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        throw denied("runtime_unavailable", "No allowed runtime executable is available.")
    }

    private static func validatedDeveloperTool(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw denied("invalid_executable", "Developer tools must use an absolute executable path.")
        }
        let url = canonicalURL(path)
        guard allowedDeveloperTools.contains(url.lastPathComponent) else {
            throw denied("tool_not_allowed", "The executable is not part of the V1 developer-tools allowlist.")
        }
        guard isAllowedExecutableURL(url), FileManager.default.isExecutableFile(atPath: url.path) else {
            throw denied("invalid_executable", "The developer tool is unavailable or outside an approved toolchain root.")
        }
        return url
    }

    private static func validatedWorkingDirectory(_ path: String?) throws -> URL {
        let rawPath = (path?.isEmpty == false) ? path! : NSHomeDirectory()
        let url = canonicalURL(rawPath)
        guard isAllowedUserURL(url) else {
            throw denied("working_directory_denied", "The working directory is outside the V1 user workspace policy.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw denied("invalid_working_directory", "The working directory must be an existing absolute directory.")
        }
        return url
    }

    private static func validatedUserFile(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw denied("invalid_script_path", "Script paths must be absolute.")
        }
        let url = canonicalURL(path)
        guard isAllowedUserURL(url) else {
            throw denied("script_path_denied", "The script path is outside the V1 user workspace policy.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw denied("invalid_script_path", "The script path must reference an existing file.")
        }
        return url
    }

    private static func isAllowedExecutableURL(_ url: URL) -> Bool {
        executableRoots.contains { contains(url.path, within: $0) }
    }

    private static func isAllowedUserURL(_ url: URL) -> Bool {
        let path = url.path
        let allowedRoots = [NSHomeDirectory(), "/Users/Shared", "/private/tmp", "/tmp"]
        guard allowedRoots.contains(where: { contains(path, within: $0) }) else { return false }

        let deniedRoots = [
            NSHomeDirectory() + "/.ssh",
            NSHomeDirectory() + "/.gnupg",
            NSHomeDirectory() + "/Library/Keychains",
            NSHomeDirectory() + "/Library/Mail",
            NSHomeDirectory() + "/Library/Messages"
        ]
        return !deniedRoots.contains(where: { contains(path, within: $0) })
    }

    private static func canonicalURL(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func contains(_ path: String, within root: String) -> Bool {
        let normalizedRoot = canonicalURL(root).path
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }

    private static func denied(_ code: String, _ message: String) -> MCPStudioProcessPolicyError {
        MCPStudioProcessPolicyError(code: code, message: message)
    }
}
