import Darwin
import Foundation
import os

final class MCPStudioProcessJobManager: @unchecked Sendable {
    private final class JobRecord {
        let validatedRequest: MCPStudioValidatedProcessRequest
        var state: MCPStudioProcessJobState = .accepted
        var result: MCPStudioProcessExecutionResult?
        var process: Process?
        var isolatedProcessGroup = false
        var cancellationRequested = false
        var completedAt: Date?

        init(validatedRequest: MCPStudioValidatedProcessRequest) {
            self.validatedRequest = validatedRequest
        }
    }

    private final class OutputCapture: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var stdout = Data()
        private var stderr = Data()
        private(set) var exceededLimit = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ data: Data, toStandardError: Bool) -> Bool {
            guard !data.isEmpty else { return false }
            lock.lock()
            defer { lock.unlock() }

            guard !exceededLimit else { return true }
            let used = stdout.count + stderr.count
            let remaining = max(0, limit - used)
            let acceptedCount = min(remaining, data.count)
            if acceptedCount > 0 {
                if toStandardError {
                    stderr.append(data.prefix(acceptedCount))
                } else {
                    stdout.append(data.prefix(acceptedCount))
                }
            }
            if acceptedCount < data.count {
                exceededLimit = true
            }
            return exceededLimit
        }

        func snapshot() -> (stdout: Data, stderr: Data, exceededLimit: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (stdout, stderr, exceededLimit)
        }
    }

    private let lock = NSLock()
    private let executionQueue = DispatchQueue(
        label: "org.eof.tools.MCPStudio.LaunchAgent.process-execution",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let logger = Logger(
        subsystem: MCPStudioLaunchAgentIdentity.agentBundleIdentifier,
        category: "process"
    )
    private var jobs: [UUID: JobRecord] = [:]
    private let resultRetentionInterval: TimeInterval = 5 * 60

    func submit(
        _ request: MCPStudioProcessExecutionRequest,
        hostOSCommandPolicy: MCPStudioHostOSCommandPolicy = .empty
    ) -> MCPStudioProcessJobAccepted {
        let validated: MCPStudioValidatedProcessRequest
        do {
            validated = try MCPStudioProcessExecutionPolicy.validate(
                request,
                hostOSCommandPolicy: hostOSCommandPolicy
            )
        } catch let error as MCPStudioProcessPolicyError {
            return MCPStudioProcessJobAccepted(
                accepted: false,
                requestID: request.requestID,
                state: nil,
                errorCode: error.code,
                message: error.message
            )
        } catch {
            return MCPStudioProcessJobAccepted(
                accepted: false,
                requestID: request.requestID,
                state: nil,
                errorCode: "policy_error",
                message: error.localizedDescription
            )
        }

        lock.lock()
        removeExpiredJobsLocked(now: Date())
        if let existing = jobs[request.requestID] {
            let state = existing.state
            lock.unlock()
            return MCPStudioProcessJobAccepted(
                accepted: true,
                requestID: request.requestID,
                state: state,
                errorCode: nil,
                message: "The request identifier already exists; the existing job was not executed again."
            )
        }
        let activeJobCount = jobs.values.reduce(into: 0) { count, job in
            if job.state != .completed {
                count += 1
            }
        }
        guard activeJobCount < MCPStudioProcessExecutionPolicy.maximumConcurrentJobs else {
            lock.unlock()
            return MCPStudioProcessJobAccepted(
                accepted: false,
                requestID: request.requestID,
                state: nil,
                errorCode: "agent_busy",
                message: "The Launch Agent is already running the maximum number of concurrent jobs."
            )
        }
        let record = JobRecord(validatedRequest: validated)
        jobs[request.requestID] = record
        lock.unlock()

        executionQueue.async { [weak self] in
            self?.execute(requestID: request.requestID)
        }

        return MCPStudioProcessJobAccepted(
            accepted: true,
            requestID: request.requestID,
            state: .accepted,
            errorCode: nil,
            message: nil
        )
    }

    func status(requestID: UUID) -> MCPStudioProcessJobStatus {
        lock.lock()
        removeExpiredJobsLocked(now: Date())
        guard let record = jobs[requestID] else {
            lock.unlock()
            return MCPStudioProcessJobStatus(
                requestID: requestID,
                state: nil,
                result: nil,
                errorCode: "job_not_found",
                message: "No retained job exists for the request identifier."
            )
        }
        let state = record.state
        let result = record.result
        lock.unlock()
        return MCPStudioProcessJobStatus(
            requestID: requestID,
            state: state,
            result: result,
            errorCode: nil,
            message: nil
        )
    }

    func cancel(requestID: UUID) -> MCPStudioProcessCancelResult {
        lock.lock()
        guard let record = jobs[requestID] else {
            lock.unlock()
            return MCPStudioProcessCancelResult(
                requestID: requestID,
                accepted: false,
                message: "No retained job exists for the request identifier."
            )
        }
        guard record.state != .completed else {
            lock.unlock()
            return MCPStudioProcessCancelResult(
                requestID: requestID,
                accepted: false,
                message: "The job has already completed."
            )
        }
        record.cancellationRequested = true
        let process = record.process
        let isolatedProcessGroup = record.isolatedProcessGroup
        lock.unlock()

        if let process, process.isRunning {
            terminate(process, isolatedProcessGroup: isolatedProcessGroup, signal: SIGTERM)
        }
        return MCPStudioProcessCancelResult(requestID: requestID, accepted: true, message: nil)
    }

    private func execute(requestID: UUID) {
        lock.lock()
        guard let record = jobs[requestID], record.state == .accepted else {
            lock.unlock()
            return
        }
        if record.cancellationRequested {
            let result = cancelledResult(for: record.validatedRequest.request)
            finish(record, result: result)
            lock.unlock()
            return
        }
        record.state = .running
        let validated = record.validatedRequest
        lock.unlock()

        let startedAt = Date()
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let inputPipe = Pipe()
        let output = OutputCapture(limit: validated.request.outputLimitBytes)
        let terminationSemaphore = DispatchSemaphore(value: 0)

        process.executableURL = validated.executableURL
        process.arguments = validated.arguments
        process.currentDirectoryURL = validated.workingDirectoryURL
        process.environment = validated.environment
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = inputPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak process] handle in
            if output.append(handle.availableData, toStandardError: false), process?.isRunning == true {
                process?.terminate()
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak process] handle in
            if output.append(handle.availableData, toStandardError: true), process?.isRunning == true {
                process?.terminate()
            }
        }
        process.terminationHandler = { _ in terminationSemaphore.signal() }

        do {
            try process.run()
        } catch {
            clearHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
            let result = MCPStudioProcessExecutionResult(
                requestID: requestID,
                terminationReason: .launchFailed,
                exitCode: nil,
                signal: nil,
                standardOutput: Data(),
                standardError: Data(error.localizedDescription.utf8),
                outputTruncated: false,
                resolvedExecutable: validated.executableURL.path,
                startedAt: startedAt.timeIntervalSince1970,
                durationSeconds: Date().timeIntervalSince(startedAt),
                message: error.localizedDescription
            )
            complete(requestID: requestID, result: result)
            return
        }

        let isolatedProcessGroup = setpgid(process.processIdentifier, process.processIdentifier) == 0
        lock.lock()
        if let current = jobs[requestID] {
            current.process = process
            current.isolatedProcessGroup = isolatedProcessGroup
        }
        let cancellationRequested = jobs[requestID]?.cancellationRequested == true
        lock.unlock()

        if cancellationRequested {
            terminate(process, isolatedProcessGroup: isolatedProcessGroup, signal: SIGTERM)
        }

        let inputData = validated.request.standardInput ?? Data()
        DispatchQueue.global(qos: .utility).async {
            do {
                if !inputData.isEmpty {
                    try inputPipe.fileHandleForWriting.write(contentsOf: inputData)
                }
                try inputPipe.fileHandleForWriting.close()
            } catch {
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        let timeout = DispatchTime.now() + validated.request.timeoutSeconds
        let timedOut = terminationSemaphore.wait(timeout: timeout) == .timedOut
        if timedOut, process.isRunning {
            terminate(process, isolatedProcessGroup: isolatedProcessGroup, signal: SIGTERM)
            if terminationSemaphore.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                terminate(process, isolatedProcessGroup: isolatedProcessGroup, signal: SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 2)
            }
        }

        clearHandlers(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
        _ = output.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), toStandardError: false)
        _ = output.append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), toStandardError: true)
        let captured = output.snapshot()
        if captured.exceededLimit, isolatedProcessGroup {
            Darwin.kill(-process.processIdentifier, SIGKILL)
        }

        lock.lock()
        let wasCancelled = jobs[requestID]?.cancellationRequested == true
        lock.unlock()

        let reason: MCPStudioProcessTerminationReason
        if captured.exceededLimit {
            reason = .outputLimitExceeded
        } else if wasCancelled {
            reason = .cancelled
        } else if timedOut {
            reason = .timedOut
        } else if process.terminationReason == .uncaughtSignal {
            reason = .signaled
        } else {
            reason = .exited
        }

        let result = MCPStudioProcessExecutionResult(
            requestID: requestID,
            terminationReason: reason,
            exitCode: reason == .exited ? process.terminationStatus : nil,
            signal: reason == .signaled ? process.terminationStatus : nil,
            standardOutput: captured.stdout,
            standardError: captured.stderr,
            outputTruncated: captured.exceededLimit,
            resolvedExecutable: validated.executableURL.path,
            startedAt: startedAt.timeIntervalSince1970,
            durationSeconds: Date().timeIntervalSince(startedAt),
            message: resultMessage(for: reason)
        )
        complete(requestID: requestID, result: result)
    }

    private func complete(requestID: UUID, result: MCPStudioProcessExecutionResult) {
        lock.lock()
        if let record = jobs[requestID] {
            finish(record, result: result)
        }
        lock.unlock()
        logger.info("Completed process request \(requestID.uuidString, privacy: .public) with \(result.terminationReason.rawValue, privacy: .public).")
    }

    private func finish(_ record: JobRecord, result: MCPStudioProcessExecutionResult) {
        record.result = result
        record.state = .completed
        record.process = nil
        record.completedAt = Date()
    }

    private func cancelledResult(for request: MCPStudioProcessExecutionRequest) -> MCPStudioProcessExecutionResult {
        MCPStudioProcessExecutionResult(
            requestID: request.requestID,
            terminationReason: .cancelled,
            exitCode: nil,
            signal: nil,
            standardOutput: Data(),
            standardError: Data(),
            outputTruncated: false,
            resolvedExecutable: nil,
            startedAt: nil,
            durationSeconds: 0,
            message: "The job was cancelled before launch."
        )
    }

    private func terminate(_ process: Process, isolatedProcessGroup: Bool, signal: Int32) {
        if isolatedProcessGroup {
            Darwin.kill(-process.processIdentifier, signal)
        } else {
            Darwin.kill(process.processIdentifier, signal)
        }
    }

    private func clearHandlers(stdoutPipe: Pipe, stderrPipe: Pipe) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
    }

    private func removeExpiredJobsLocked(now: Date) {
        jobs = jobs.filter { _, record in
            guard let completedAt = record.completedAt else { return true }
            return now.timeIntervalSince(completedAt) < resultRetentionInterval
        }
    }

    private func resultMessage(for reason: MCPStudioProcessTerminationReason) -> String? {
        switch reason {
        case .timedOut:
            return "The process exceeded its configured timeout."
        case .cancelled:
            return "The process was cancelled."
        case .outputLimitExceeded:
            return "The process exceeded its configured output limit."
        default:
            return nil
        }
    }
}
