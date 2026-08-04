import Foundation

/// Seam between the coordinator and the real child process.
///
/// Exists so the whole state machine — negotiation, model selection, streaming,
/// abort, restart, idle shutdown — can be driven in tests without spawning a
/// process or spending a token. See `FakeOmpTransport` in the test target.
public protocol OmpTransport: AnyObject, Sendable {
	var isRunning: Bool { get }
	func start(workspace: URL, apiKey: String?) throws -> AsyncStream<OmpProcessEvent>
	func send(_ command: RpcCommand, id: String?) throws
	func enableChunkReassembly(maxReassembledBytes: Int)
	func stop()
	func stopImmediately()
}

/// Production transport: resolves `omp` on disk and drives `OmpProcessController`.
public final class LiveOmpTransport: OmpTransport {
	private let controller = OmpProcessController()

	public init() {}

	public var isRunning: Bool { controller.isRunning }

	public var processIdentifier: Int32? { controller.processIdentifier }

	public func start(workspace: URL, apiKey: String?) throws -> AsyncStream<OmpProcessEvent> {
		guard let executable = OmpLocator.find() else { throw OmpProcessError.executableNotFound }
		return try controller.start(executable: executable, workspace: workspace, apiKey: apiKey)
	}

	public func send(_ command: RpcCommand, id: String?) throws {
		try controller.send(command, id: id)
	}

	public func enableChunkReassembly(maxReassembledBytes: Int) {
		controller.enableChunkReassembly(maxReassembledBytes: maxReassembledBytes)
	}

	public func stop() { controller.stop() }

	public func stopImmediately() { controller.stopImmediately() }
}
