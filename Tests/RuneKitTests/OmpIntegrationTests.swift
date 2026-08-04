import Foundation
import Testing

@testable import RuneKit

/// Exercises the real `omp` binary over stdio.
///
/// Cost policy: these tests never invoke a model. They stop at the handshake,
/// the catalogue, and `set_model`, all of which are local. `OPENCODE_API_KEY`
/// is set to a placeholder purely so the provider's catalogue is listed —
/// nothing is billed. The one test that would spend money is gated behind
/// `RUNE_LIVE_MODEL_TEST=1`.
@MainActor
@Suite(
	"OMP integration",
	.enabled(if: OmpLocator.find() != nil, "omp not installed"),
	.serialized
)
struct OmpIntegrationTests {
	private var workspace: URL { FileManager.default.temporaryDirectory }

	@Test("handshake: ready → v2 → get_state → models → clean exit", .timeLimit(.minutes(1)))
	func handshake() async throws {
		let transport = LiveOmpTransport()
		let stream = try transport.start(workspace: workspace, apiKey: "integration-placeholder", mode: .build)

		var reader = FrameCollector()
		var ready: RpcReady?
		var responses: [String: RpcResponse] = [:]
		var exitReason: String?

		let consume = Task {
			for await event in stream {
				switch event {
				case .frame(let frame):
					reader.record(frame)
					if case .ready(let value) = frame { ready = value }
					if case .response(let response) = frame, let id = response.id {
						responses[id] = response
					}
				case .terminated(_, let reason):
					exitReason = reason
				default:
					break
				}
			}
		}

		// 1. ready
		try await waitUntil("ready frame") { ready != nil }
		let readyFrame = try #require(ready)
		#expect(readyFrame.supportsV2)
		#expect(readyFrame.maxFrameBytes == 1_048_576)

		// 2. protocol v2
		try transport.send(.negotiateProtocol(version: 2), id: "it_negotiate")
		try await waitUntil("negotiate response") { responses["it_negotiate"] != nil }
		let negotiated = try #require(responses["it_negotiate"])
		#expect(negotiated.success)
		#expect(negotiated.data?["protocolVersion"]?.intValue == 2)
		transport.enableChunkReassembly(maxReassembledBytes: readyFrame.maxReassembledFrameBytes)

		// 3. get_state
		try transport.send(.getState, id: "it_state")
		try await waitUntil("get_state response") { responses["it_state"] != nil }
		let state = try #require(responses["it_state"])
		#expect(state.success)
		#expect(state.data?["sessionId"]?.stringValue?.isEmpty == false)

		// 4. catalogue — the configured provider and model must actually exist
		try transport.send(.getAvailableModels, id: "it_models")
		try await waitUntil("get_available_models response") { responses["it_models"] != nil }
		let catalogue = try #require(responses["it_models"])
		let models = try #require(catalogue.data?["models"]?.arrayValue)
		let target = models.first {
			$0["provider"]?.stringValue == AppConfiguration.providerId
				&& $0["id"]?.stringValue == AppConfiguration.primaryModelId
		}
		let model = try #require(
			target,
			"\(AppConfiguration.primaryModelSelector) missing from the installed catalogue"
		)
		// Recorded so a future OMP release that adds vision to this model is
		// caught here rather than at runtime.
		let inputs = model["input"]?.arrayValue?.compactMap(\.stringValue) ?? []
		#expect(inputs.contains("text"))

		// 5. pin the model
		try transport.send(
			.setModel(provider: AppConfiguration.providerId, modelId: AppConfiguration.primaryModelId),
			id: "it_model"
		)
		try await waitUntil("set_model response") { responses["it_model"] != nil }
		#expect(responses["it_model"]?.success == true)

		// 5b. the configured reasoning effort must be one the model advertises
		let efforts = model["thinking"]?["efforts"]?.arrayValue?.compactMap(\.stringValue) ?? []
		#expect(
			efforts.contains(AppConfiguration.thinkingLevel),
			"effort \(AppConfiguration.thinkingLevel) not offered; model advertises \(efforts)"
		)
		try transport.send(.setThinkingLevel(level: AppConfiguration.thinkingLevel), id: "it_effort")
		try await waitUntil("set_thinking_level response") { responses["it_effort"] != nil }
		#expect(responses["it_effort"]?.success == true)

		// 6. clean shutdown via stdin EOF
		transport.stop()
		try await waitUntil("process exit", timeout: 20) { exitReason != nil }
		#expect(exitReason == "exit(0)")
		#expect(!transport.isRunning)
		consume.cancel()
	}

	@Test("the coordinator boots against the real binary", .timeLimit(.minutes(1)))
	func coordinatorBoot() async throws {
		let defaults = UserDefaults(suiteName: "rune.integration.\(UUID().uuidString)")!
		let coordinator = AgentCoordinator(
			transport: LiveOmpTransport(),
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { "integration-placeholder" }
		)

		try await coordinator.ensureRunning()
		#expect(coordinator.runState == .ready)
		#expect(coordinator.activeModelDescription == AppConfiguration.primaryModelSelector)
		#expect(coordinator.thinkingLevel == AppConfiguration.thinkingLevel)
		// deepseek-v4-flash-free advertises `input: ["text"]`.
		#expect(!coordinator.modelSupportsImages)

		coordinator.shutdownForAppExit()
	}

	@Test(
		"a real model turn (billed — opt-in)",
		.enabled(if: ProcessInfo.processInfo.environment["RUNE_LIVE_MODEL_TEST"] == "1"),
		.timeLimit(.minutes(3))
	)
	func liveModelTurn() async throws {
		let key = try #require(
			KeychainStore.readIfPresent(),
			"store a key first: ./scripts/set-opencode-key.sh"
		)
		let defaults = UserDefaults(suiteName: "rune.live.\(UUID().uuidString)")!
		let coordinator = AgentCoordinator(
			transport: LiveOmpTransport(),
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { key }
		)

		try await coordinator.ensureRunning()
		await coordinator.submit(text: "Responda apenas com a palavra: pronto", attachments: [])

		try await waitUntil("assistant answer", timeout: 120) {
			coordinator.items.contains {
				if case .assistant(let turn) = $0 { return !turn.text.isEmpty }
				return false
			}
		}
		coordinator.shutdownForAppExit()
	}

	// MARK: - Helpers

	/// Polls a main-actor condition. Used instead of a fixed sleep so the tests
	/// finish as soon as the frame lands.
	private func waitUntil(
		_ description: String,
		timeout: TimeInterval = 45,
		_ condition: () -> Bool
	) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if condition() { return }
			try await Task.sleep(for: .milliseconds(25))
		}
		Issue.record("timed out waiting for \(description)")
		throw CancellationError()
	}
}

/// Records frame kinds so a failing run says what did arrive.
private struct FrameCollector {
	private(set) var kinds: [String] = []

	mutating func record(_ frame: RpcFrame) {
		switch frame {
		case .ready: kinds.append("ready")
		case .response(let response): kinds.append("response:\(response.command)")
		case .agentEvent: kinds.append("agent_event")
		case .extensionUIRequest: kinds.append("extension_ui_request")
		case .promptResult: kinds.append("prompt_result")
		case .availableCommands: kinds.append("available_commands_update")
		case .commandOutput: kinds.append("command_output")
		case .extensionError: kinds.append("extension_error")
		case .subagent(let kind, _): kinds.append(kind)
		case .unknown(let type, _): kinds.append("unknown:\(type)")
		}
	}
}
