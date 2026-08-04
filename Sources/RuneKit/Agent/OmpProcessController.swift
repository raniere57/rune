import Foundation
import os

/// Anything the host learns from the child process.
public enum OmpProcessEvent: Sendable {
	case started(pid: Int32)
	case frame(RpcFrame)
	/// Recoverable decode problem — the stream continues.
	case decodeFailure(String)
	case stderr(String)
	case terminated(status: Int32, reason: String)
}

public enum OmpProcessError: Error, LocalizedError {
	case executableNotFound
	case alreadyRunning
	case notRunning
	case launchFailed(String)

	public var errorDescription: String? {
		switch self {
		case .executableNotFound:
			return "`omp` was not found in PATH. Install it with `brew install can1357/tap/omp`."
		case .alreadyRunning: return "OMP is already running."
		case .notRunning: return "OMP is not running."
		case .launchFailed(let reason): return "Failed to launch OMP: \(reason)"
		}
	}
}

/// Owns the `omp --mode rpc-ui` child process and its three pipes.
///
/// Concurrency note: `readabilityHandler` callbacks arrive on Foundation's own
/// serial queue per handle. Buffering and frame decoding happen inline there,
/// under `lock`, and completed frames are handed to `AsyncStream.Continuation`,
/// whose `yield` preserves call order. Hopping to an actor instead would lose
/// that ordering — `Task { await … }` gives no FIFO guarantee, and a reordered
/// JSONL stream would corrupt streaming text.
public final class OmpProcessController: @unchecked Sendable {
	private let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "process")
	private let lock = NSLock()

	private var process: Process?
	private var stdinPipe: Pipe?
	private var reader = RpcFrameReader()
	private var continuation: AsyncStream<OmpProcessEvent>.Continuation?
	private var stdinClosed = false

	public init() {}

	public var isRunning: Bool {
		lock.lock()
		defer { lock.unlock() }
		return process?.isRunning ?? false
	}

	public var processIdentifier: Int32? {
		lock.lock()
		defer { lock.unlock() }
		guard let process, process.isRunning else { return nil }
		return process.processIdentifier
	}

	// MARK: - Lifecycle

	public static let defaultArguments = [
		"--mode", AppConfiguration.ompMode,
		"--approval-mode", AppConfiguration.approvalMode,
	]

	public func start(
		executable: URL,
		workspace: URL,
		apiKey: String?,
		arguments: [String] = OmpProcessController.defaultArguments
	) throws -> AsyncStream<OmpProcessEvent> {
		lock.lock()
		guard process == nil else {
			lock.unlock()
			throw OmpProcessError.alreadyRunning
		}

		let process = Process()
		let stdin = Pipe()
		let stdout = Pipe()
		let stderr = Pipe()

		process.executableURL = executable
		process.arguments = arguments
		process.currentDirectoryURL = workspace
		process.standardInput = stdin
		process.standardOutput = stdout
		process.standardError = stderr

		var environment = ProcessInfo.processInfo.environment
		environment["PATH"] = OmpLocator.childPath()
		if let apiKey, !apiKey.isEmpty {
			environment[AppConfiguration.apiKeyEnvironmentVariable] = apiKey
		}
		process.environment = environment

		let (stream, continuation) = AsyncStream<OmpProcessEvent>.makeStream(
			bufferingPolicy: .unbounded
		)

		self.process = process
		self.stdinPipe = stdin
		self.continuation = continuation
		self.reader = RpcFrameReader()
		self.stdinClosed = false
		lock.unlock()

		stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			guard let self else { return }
			if data.isEmpty {
				handle.readabilityHandler = nil
				self.drainAtEOF()
			} else {
				self.ingestStdout(data)
			}
		}

		stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
			let data = handle.availableData
			guard let self else { return }
			if data.isEmpty {
				handle.readabilityHandler = nil
				return
			}
			guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
			self.emit(.stderr(text))
		}

		process.terminationHandler = { [weak self] finished in
			self?.handleTermination(of: finished)
		}

		do {
			try process.run()
		} catch {
			lock.lock()
			self.process = nil
			self.stdinPipe = nil
			self.continuation = nil
			lock.unlock()
			continuation.finish()
			throw OmpProcessError.launchFailed(error.localizedDescription)
		}

		logger.info("omp started, pid \(process.processIdentifier, privacy: .public)")
		emit(.started(pid: process.processIdentifier))
		return stream
	}

	/// Graceful stop. Closing stdin is the documented shutdown path: RPC mode
	/// drains accepted commands, disposes the session, and exits with code 0.
	/// SIGTERM/SIGKILL are only the backstop if it hangs.
	public func stop(gracePeriod: TimeInterval = AppConfiguration.terminationGraceSeconds) {
		lock.lock()
		guard let process, process.isRunning else {
			lock.unlock()
			return
		}
		let pid = process.processIdentifier
		lock.unlock()

		closeStdin()

		let deadline = Date().addingTimeInterval(gracePeriod)
		DispatchQueue.global(qos: .utility).async { [weak self] in
			while Date() < deadline {
				guard let self, self.isRunning else { return }
				Thread.sleep(forTimeInterval: 0.05)
			}
			guard let self, self.isRunning else { return }
			self.logger.warning("omp pid \(pid, privacy: .public) ignored stdin EOF, sending SIGTERM")
			self.lock.lock()
			self.process?.terminate()
			self.lock.unlock()

			Thread.sleep(forTimeInterval: 1.0)
			guard self.isRunning else { return }
			self.logger.error("omp pid \(pid, privacy: .public) still alive, sending SIGKILL")
			kill(pid, SIGKILL)
		}
	}

	/// Synchronous, best-effort stop used from `applicationWillTerminate`,
	/// where there is no time left to await anything.
	public func stopImmediately() {
		closeStdin()
		lock.lock()
		let running = process?.isRunning ?? false
		let pid = process?.processIdentifier
		lock.unlock()
		guard running, let pid else { return }
		kill(pid, SIGTERM)
	}

	// MARK: - Sending

	public func send(_ command: RpcCommand, id: String?) throws {
		let payload = try command.encoded(id: id)
		lock.lock()
		guard let stdinPipe, process?.isRunning == true, !stdinClosed else {
			lock.unlock()
			throw OmpProcessError.notRunning
		}
		let handle = stdinPipe.fileHandleForWriting
		lock.unlock()

		do {
			try handle.write(contentsOf: payload)
		} catch {
			throw OmpProcessError.launchFailed("stdin write failed: \(error.localizedDescription)")
		}
	}

	/// Turns on `rpc_chunk` reassembly. Only valid after the
	/// `negotiate_protocol` success response.
	public func enableChunkReassembly(maxReassembledBytes: Int) {
		lock.lock()
		reader.enableChunkReassembly(maxReassembledBytes: maxReassembledBytes)
		lock.unlock()
	}

	// MARK: - Internals

	private func ingestStdout(_ data: Data) {
		lock.lock()
		let outputs = reader.feed(data)
		lock.unlock()
		forward(outputs)
	}

	private func drainAtEOF() {
		lock.lock()
		let outputs = reader.finish()
		lock.unlock()
		forward(outputs)
	}

	private func forward(_ outputs: [RpcFrameReader.Output]) {
		for output in outputs {
			switch output {
			case .frame(let frame): emit(.frame(frame))
			case .failure(let message):
				logger.error("rpc decode failure: \(message, privacy: .public)")
				emit(.decodeFailure(message))
			}
		}
	}

	private func emit(_ event: OmpProcessEvent) {
		lock.lock()
		let continuation = self.continuation
		lock.unlock()
		continuation?.yield(event)
	}

	private func closeStdin() {
		lock.lock()
		let handle = stdinClosed ? nil : stdinPipe?.fileHandleForWriting
		stdinClosed = true
		lock.unlock()
		try? handle?.close()
	}

	private func handleTermination(of finished: Process) {
		let status = finished.terminationStatus
		let reason: String
		switch finished.terminationReason {
		case .exit: reason = "exit(\(status))"
		case .uncaughtSignal: reason = "signal(\(status))"
		@unknown default: reason = "unknown(\(status))"
		}
		logger.info("omp terminated: \(reason, privacy: .public)")

		lock.lock()
		let continuation = self.continuation
		self.process = nil
		self.stdinPipe = nil
		self.continuation = nil
		self.stdinClosed = true
		lock.unlock()

		continuation?.yield(.terminated(status: status, reason: reason))
		continuation?.finish()
	}
}
