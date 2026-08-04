import Foundation

public enum RpcError: Error, LocalizedError, Equatable {
	case notRunning
	case timedOut(command: String)
	case commandFailed(command: String, message: String, code: String?)
	case unexpectedPayload(command: String)
	case processTerminated(String)

	public var errorDescription: String? {
		switch self {
		case .notRunning:
			return "OMP is not running."
		case .timedOut(let command):
			return "\(command) timed out."
		case .commandFailed(let command, let message, let code):
			return code.map { "\(command) failed (\($0)): \(message)" } ?? "\(command) failed: \(message)"
		case .unexpectedPayload(let command):
			return "\(command) returned an unexpected payload."
		case .processTerminated(let reason):
			return "OMP terminated: \(reason)"
		}
	}
}

/// Correlates outbound command ids with their `RpcResponse`.
///
/// Ordering between a command response and the agent events it triggers is not
/// guaranteed (docs/rpc.md: "clients MUST match responses on `id`, not on
/// emission order"), and some failures answer with `id: undefined` and never
/// resolve at all — hence the per-request timeout.
@MainActor
public final class RpcRequestStore {
	private var pending: [String: CheckedContinuation<RpcResponse, Error>] = [:]
	private var commandNames: [String: String] = [:]
	private var counter = 0

	public init() {}

	public func nextId() -> String {
		counter += 1
		return "req_\(counter)"
	}

	public var pendingCount: Int { pending.count }

	/// Suspends until the matching response arrives or `timeout` elapses.
	public func response(
		forId id: String,
		command: String,
		timeout: Duration
	) async throws -> RpcResponse {
		commandNames[id] = command
		let timeoutTask = Task { [weak self] in
			try? await Task.sleep(for: timeout)
			guard !Task.isCancelled else { return }
			self?.fail(id: id, error: RpcError.timedOut(command: command))
		}
		defer { timeoutTask.cancel() }

		return try await withCheckedThrowingContinuation { continuation in
			pending[id] = continuation
		}
	}

	/// Returns `true` when the response matched a pending request.
	@discardableResult
	public func resolve(_ response: RpcResponse) -> Bool {
		guard let id = response.id, let continuation = pending.removeValue(forKey: id) else { return false }
		commandNames.removeValue(forKey: id)
		continuation.resume(returning: response)
		return true
	}

	public func fail(id: String, error: Error) {
		guard let continuation = pending.removeValue(forKey: id) else { return }
		commandNames.removeValue(forKey: id)
		continuation.resume(throwing: error)
	}

	/// Rejects every in-flight request. Called when the process dies so no
	/// caller is left suspended forever.
	public func failAll(with error: Error) {
		let inFlight = pending
		pending.removeAll()
		commandNames.removeAll()
		for (_, continuation) in inFlight {
			continuation.resume(throwing: error)
		}
	}
}
