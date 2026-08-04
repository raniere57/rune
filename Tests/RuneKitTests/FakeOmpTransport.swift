import Foundation

@testable import RuneKit

/// In-memory stand-in for the `omp` child process.
///
/// Answers the boot handshake (`negotiate_protocol`, `get_available_models`,
/// `set_model`, `get_state`) with the exact payload shapes captured from
/// omp 17.2.6, so the coordinator can be driven end to end without spawning a
/// process or spending a token.
final class FakeOmpTransport: OmpTransport, @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: AsyncStream<OmpProcessEvent>.Continuation?
	private var running = false
	private var sentCommands: [(command: RpcCommand, id: String?)] = []

	/// When false the transport stays silent, so timeout paths can be exercised.
	var autoAnswersHandshake = true
	/// Model catalogue returned by `get_available_models`.
	var catalogue: [String] = ["deepseek-v4-flash", "deepseek-v4-flash-free", "claude-opus-5"]
	/// Reasoning efforts the fake model advertises, mirroring the real catalogue.
	var modelEfforts: [String] = ["high", "max"]
	var modelInputs: [String] = ["text"]
	var sessionFile = "/tmp/rune-test/session.jsonl"
	private(set) var chunkReassemblyLimit: Int?
	private(set) var stopCount = 0
	private(set) var thinkingLevel: String?

	var isRunning: Bool {
		lock.lock()
		defer { lock.unlock() }
		return running
	}

	var sent: [(command: RpcCommand, id: String?)] {
		lock.lock()
		defer { lock.unlock() }
		return sentCommands
	}

	func commandTypes() -> [String] { sent.map(\.command.commandType) }

	// MARK: - OmpTransport

	func start(workspace: URL, apiKey: String?) throws -> AsyncStream<OmpProcessEvent> {
		let (stream, continuation) = AsyncStream<OmpProcessEvent>.makeStream(bufferingPolicy: .unbounded)
		lock.lock()
		running = true
		self.continuation = continuation
		sentCommands.removeAll()
		lock.unlock()

		continuation.yield(.started(pid: 4242))
		emit("""
		{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1,2],\
		"maxFrameBytes":1048576,"maxReassembledFrameBytes":67108864}
		""")
		return stream
	}

	func send(_ command: RpcCommand, id: String?) throws {
		guard isRunning else { throw OmpProcessError.notRunning }
		lock.lock()
		sentCommands.append((command, id))
		lock.unlock()
		guard autoAnswersHandshake else { return }
		answer(command, id: id)
	}

	func enableChunkReassembly(maxReassembledBytes: Int) {
		chunkReassemblyLimit = maxReassembledBytes
	}

	func stop() {
		lock.lock()
		stopCount += 1
		lock.unlock()
		terminate(status: 0, reason: "exit(0)")
	}

	func stopImmediately() { stop() }

	// MARK: - Test driving

	/// Feeds one JSONL line through the real frame parser, so tests exercise
	/// the production decoding path rather than hand-built frames.
	func emit(_ json: String) {
		guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else {
			fatalError("FakeOmpTransport was handed invalid JSON: \(json)")
		}
		lock.lock()
		let continuation = self.continuation
		lock.unlock()
		continuation?.yield(.frame(RpcFrame.make(from: value)))
	}

	func terminate(status: Int32, reason: String) {
		lock.lock()
		guard running else {
			lock.unlock()
			return
		}
		running = false
		let continuation = self.continuation
		self.continuation = nil
		lock.unlock()

		continuation?.yield(.terminated(status: status, reason: reason))
		continuation?.finish()
	}

	// MARK: - Canned responses

	private func answer(_ command: RpcCommand, id: String?) {
		let identifier = id.map { "\"id\":\"\($0)\"," } ?? ""
		switch command {
		case .negotiateProtocol:
			emit("""
			{\(identifier)"type":"response","command":"negotiate_protocol","success":true,\
			"data":{"protocolVersion":2}}
			""")

		case .getAvailableModels:
			let models = catalogue.map { modelJSON(id: $0) }.joined(separator: ",")
			emit("""
			{\(identifier)"type":"response","command":"get_available_models","success":true,\
			"data":{"models":[\(models)]}}
			""")

		case .setModel(_, let modelId):
			guard catalogue.contains(modelId) else {
				emit("""
				{\(identifier)"type":"response","command":"set_model","success":false,\
				"error":"Model not found"}
				""")
				return
			}
			emit("""
			{\(identifier)"type":"response","command":"set_model","success":true,\
			"data":\(modelJSON(id: modelId))}
			""")

		case .getState:
			emit("""
			{\(identifier)"type":"response","command":"get_state","success":true,\
			"data":{"model":\(modelJSON(id: AppConfiguration.primaryModelId)),\
			"isStreaming":false,"isCompacting":false,"sessionId":"s1",\
			"sessionFile":"\(sessionFile)","messageCount":0,"queuedMessageCount":0,\
			"todoPhases":[],"autoCompactionEnabled":true,"fastModeEnabled":false,\
			"thinkingLevel":\(thinkingLevel.map { "\"\($0)\"" } ?? "null"),\
			"fastModeActive":false,"tokensPerSecond":null,"steeringMode":"one-at-a-time",\
			"followUpMode":"one-at-a-time","interruptMode":"immediate",\
			"contextUsage":{"tokens":1100,"contextWindow":1000000,"percent":0.11}}}
			""")

		case .prompt:
			emit("""
			{\(identifier)"type":"response","command":"prompt","success":true,\
			"data":{"agentInvoked":true}}
			""")

		case .abort:
			emit("{\(identifier)\"type\":\"response\",\"command\":\"abort\",\"success\":true}")

		case .newSession:
			emit("""
			{\(identifier)"type":"response","command":"new_session","success":true,\
			"data":{"cancelled":false}}
			""")

		case .switchSession:
			emit("""
			{\(identifier)"type":"response","command":"switch_session","success":true,\
			"data":{"cancelled":false}}
			""")

		case .getMessagesPage:
			emit("""
			{\(identifier)"type":"response","command":"get_messages_page","success":true,\
			"data":{"messages":[],"totalMessages":0}}
			""")

		case .setThinkingLevel(let level):
			guard modelEfforts.isEmpty || modelEfforts.contains(level) else {
				emit("""
				{\(identifier)"type":"response","command":"set_thinking_level","success":false,\
				"error":"Thinking effort \(level) is not supported by this model"}
				""")
				return
			}
			thinkingLevel = level
			emit("{\(identifier)\"type\":\"response\",\"command\":\"set_thinking_level\",\"success\":true}")

		case .steer, .followUp, .getSessionStats, .setSubagentSubscription:
			emit("""
			{\(identifier)"type":"response","command":"\(command.commandType)","success":true}
			""")

		case .extensionUIResponse:
			break
		}
	}

	private func modelJSON(id: String) -> String {
		let inputs = modelInputs.map { "\"\($0)\"" }.joined(separator: ",")
		let efforts = modelEfforts.map { "\"\($0)\"" }.joined(separator: ",")
		return """
		{"id":"\(id)","name":"\(id)","api":"openai-completions",\
		"provider":"\(AppConfiguration.providerId)","baseUrl":"https://opencode.ai/zen/v1",\
		"reasoning":true,"input":[\(inputs)],"contextWindow":200000,"maxTokens":128000,\
		"thinking":{"mode":"effort","efforts":[\(efforts)]}}
		"""
	}
}

/// Stands in for the login keychain so `/key` can be tested without writing to
/// the real one.
final class KeyStoreSpy: @unchecked Sendable {
	private let lock = NSLock()
	private var value: String?
	private let failWrites: Bool

	init(current: String?, failWrites: Bool = false) {
		self.value = current
		self.failWrites = failWrites
	}

	var current: String? {
		lock.lock()
		defer { lock.unlock() }
		return value
	}

	struct WriteFailure: Error, LocalizedError {
		var errorDescription: String? { "Keychain error: simulated denial" }
	}

	func write(_ newValue: String) throws {
		if failWrites { throw WriteFailure() }
		lock.lock()
		value = newValue
		lock.unlock()
	}
}
