import Foundation
import Testing

@testable import RuneKit

@MainActor
@Suite("Agent state machine")
struct AgentCoordinatorTests {
	private func makeCoordinator(
		transport: FakeOmpTransport,
		idleInterval: TimeInterval = 3600,
		apiKey: String? = "test-key",
		keyStore: KeyStoreSpy? = nil
	) -> AgentCoordinator {
		let defaults = UserDefaults(suiteName: "rune.tests.\(UUID().uuidString)")!
		return AgentCoordinator(
			transport: transport,
			defaults: defaults,
			idleInterval: idleInterval,
			apiKeyProvider: { keyStore?.current ?? apiKey },
			apiKeyWriter: { value in
				if let keyStore { try keyStore.write(value) }
			}
		)
	}

	/// The coordinator reacts to frames on a detached consume task; give the
	/// main actor a few turns to drain them.
	private func settle(_ turns: Int = 6) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(20))
		for _ in 0..<turns { await Task.yield() }
	}

	// MARK: - Boot

	@Test("boot negotiates v2, verifies the catalogue, and pins the configured model")
	func bootHandshake() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)

		try await coordinator.ensureRunning()

		let types = transport.commandTypes()
		#expect(types.first == "negotiate_protocol")
		#expect(types.contains("get_available_models"))
		#expect(types.contains("set_model"))
		#expect(types.contains("set_thinking_level"))
		#expect(transport.chunkReassemblyLimit == 67_108_864)
		#expect(coordinator.runState == .ready)
		#expect(coordinator.activeModelDescription == AppConfiguration.primaryModelSelector)
		#expect(coordinator.thinkingLevel == AppConfiguration.thinkingLevel)
		#expect(transport.thinkingLevel == "max")
	}

	@Test("an effort the model does not advertise is skipped instead of failing the boot")
	func unsupportedEffortDegradesGracefully() async throws {
		let transport = FakeOmpTransport()
		transport.modelEfforts = ["low", "medium"]
		let coordinator = makeCoordinator(transport: transport)

		try await coordinator.ensureRunning()

		#expect(coordinator.runState == .ready)
		#expect(!transport.commandTypes().contains("set_thinking_level"))
		#expect(coordinator.thinkingLevel == nil)
		let warned = coordinator.items.contains {
			guard case .notice(let entry) = $0 else { return false }
			return entry.level == .warning && entry.text.lowercased().contains("effort")
		}
		#expect(warned)
	}

	@Test("a missing keychain entry blocks the boot with the setup instructions")
	func missingKeyBlocksBoot() async {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport, apiKey: nil)

		await #expect(throws: AgentError.self) { try await coordinator.ensureRunning() }
		#expect(!transport.isRunning)
	}

	@Test("an absent model substitutes another free one, and never a paid one")
	func modelUnavailableFallsBackToFree() async throws {
		let transport = FakeOmpTransport()
		transport.catalogue = ["claude-opus-5", "deepseek-v4-flash-0731"]
		let coordinator = makeCoordinator(transport: transport)

		// A hardcoded model id is a single point of failure the app cannot repair
		// at runtime: when the provider retires it, refusing to boot leaves every
		// install dead until a release ships. Substituting is allowed — silently
		// substituting, or substituting something billable, is not.
		try await coordinator.ensureRunning()
		#expect(coordinator.runState == .ready)
		#expect(coordinator.activeModelDescription != AppConfiguration.primaryModelSelector)
		#expect(coordinator.items.contains {
			guard case .notice(let entry) = $0 else { return false }
			return entry.level == .warning
		})
	}

	@Test("image support is read from the model's declared input kinds")
	func detectsImageSupport() async throws {
		let textOnly = FakeOmpTransport()
		let textCoordinator = makeCoordinator(transport: textOnly)
		try await textCoordinator.ensureRunning()
		#expect(!textCoordinator.modelSupportsImages)

		let multimodal = FakeOmpTransport()
		multimodal.modelInputs = ["text", "image"]
		let visionCoordinator = makeCoordinator(transport: multimodal)
		try await visionCoordinator.ensureRunning()
		#expect(visionCoordinator.modelSupportsImages)
	}

	@Test("concurrent callers share a single boot")
	func concurrentBootIsDeduplicated() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)

		async let first: Void = coordinator.ensureRunning()
		async let second: Void = coordinator.ensureRunning()
		_ = try await (first, second)

		#expect(transport.commandTypes().filter { $0 == "negotiate_protocol" }.count == 1)
	}

	// MARK: - Streaming

	@Test("text deltas accumulate into one assistant turn and close on agent_end")
	func streamingAccumulates() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		transport.emit(#"{"type":"agent_start"}"#)
		for piece in ["Olá", ", ", "mundo"] {
			transport.emit("""
			{"type":"message_update","message":{"role":"assistant"},\
			"assistantMessageEvent":{"type":"text_delta","delta":"\(piece)"}}
			""")
		}
		await settle()
		#expect(coordinator.runState == .thinking)

		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()

		let assistantTurns = coordinator.items.compactMap { item -> AssistantTurn? in
			guard case .assistant(let turn) = item else { return nil }
			return turn
		}
		#expect(assistantTurns.count == 1)
		#expect(assistantTurns.first?.text == "Olá, mundo")
		#expect(assistantTurns.first?.isStreaming == false)
		#expect(coordinator.runState == .ready)
	}

	@Test("a non-terminal agent_end does not end the run")
	func nonTerminalAgentEndKeepsRunning() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":false}"#)
		await settle()
		#expect(coordinator.runState == .thinking)

		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()
		#expect(coordinator.runState == .ready)
	}

	@Test("a prompt sent mid-run is queued as steering, not as a bare prompt")
	func midRunPromptSteers() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		await coordinator.submit(text: "primeira", attachments: [])
		await settle()
		transport.emit(#"{"type":"agent_start"}"#)
		await settle()

		await coordinator.submit(text: "segunda", attachments: [])
		await settle()

		let prompts = transport.sent.compactMap { entry -> StreamingBehavior?? in
			guard case .prompt(_, _, let behavior) = entry.command else { return nil }
			return behavior
		}
		#expect(prompts.count == 2)
		#expect(prompts[0] == StreamingBehavior?.none)
		#expect(prompts[1] == .steer)
	}

	// MARK: - Tools

	@Test("a tool call collapses to one row and records its result")
	func toolLifecycle() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		transport.emit("""
		{"type":"tool_execution_start","toolCallId":"t1","toolName":"read",\
		"args":{"path":"/Users/x/Dev/app/src/main.swift"}}
		""")
		await settle()
		#expect(coordinator.runState == .usingTool("read"))

		transport.emit("""
		{"type":"tool_execution_end","toolCallId":"t1","toolName":"read",\
		"result":{"content":[{"type":"text","text":"conteúdo"}]}}
		""")
		await settle()

		let tools = coordinator.items.compactMap { item -> ToolActivity? in
			guard case .tool(let activity) = item else { return nil }
			return activity
		}
		#expect(tools.count == 1)
		#expect(tools[0].status == .succeeded)
		#expect(tools[0].summary == "Leu …/src/main.swift")
		#expect(tools[0].resultText == "conteúdo")
	}

	@Test("a failed tool is marked as an error and carries no diff")
	func failedTool() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		transport.emit(#"{"type":"tool_execution_start","toolCallId":"t1","toolName":"bash","args":{"command":"false"}}"#)
		transport.emit("""
		{"type":"tool_execution_end","toolCallId":"t1","toolName":"bash",\
		"result":{"content":[{"type":"text","text":"- a\\n+ b\\n- c"}]},"isError":true}
		""")
		await settle()

		guard case .tool(let activity) = coordinator.items.last else {
			Issue.record("expected a tool row")
			return
		}
		#expect(activity.status == .failed)
		#expect(activity.diff == nil)
	}

	// MARK: - Abort and termination

	@Test("abort moves to the aborting state and issues the abort command")
	func abortIssuesCommand() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		await coordinator.abort()
		#expect(transport.commandTypes().contains("abort"))
	}

	@Test("an unexpected exit stops the state machine and surfaces one failure")
	func unexpectedExit() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		transport.terminate(status: 1, reason: "signal(9)")
		await settle()

		#expect(coordinator.runState == .stopped)
		let failures = coordinator.items.filter {
			if case .failure = $0 { return true }
			return false
		}
		#expect(failures.count == 1)
	}

	@Test("a restart after an exit re-runs the full handshake")
	func restartAfterExit() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		transport.terminate(status: 0, reason: "exit(0)")
		await settle()
		#expect(coordinator.runState == .stopped)

		try await coordinator.ensureRunning()
		#expect(coordinator.runState == .ready)
		#expect(transport.commandTypes().first == "negotiate_protocol")
	}

	// MARK: - Idle shutdown

	@Test("an idle session is reaped once the deadline passes")
	func idleShutdown() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport, idleInterval: 0.15)
		try await coordinator.ensureRunning()
		#expect(transport.isRunning)

		try await Task.sleep(for: .milliseconds(500))
		await settle()

		#expect(!transport.isRunning)
		#expect(coordinator.runState == .stopped)
	}

	@Test("an unanswered interactive request keeps the process alive past the deadline")
	func pendingRequestBlocksIdleShutdown() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport, idleInterval: 0.15)
		try await coordinator.ensureRunning()

		transport.emit("""
		{"type":"extension_ui_request","id":"ui_1","method":"select",\
		"title":"Allow tool: bash","options":["Approve","Deny"]}
		""")
		await settle()

		try await Task.sleep(for: .milliseconds(500))
		await settle()
		#expect(transport.isRunning)

		coordinator.answer(requestId: "ui_1", with: .value("Approve"))
		try await Task.sleep(for: .milliseconds(500))
		await settle()
		#expect(!transport.isRunning)
	}

	@Test("an in-flight run is never reaped by the idle timer")
	func busyRunBlocksIdleShutdown() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport, idleInterval: 0.15)
		try await coordinator.ensureRunning()

		await coordinator.submit(text: "trabalho longo", attachments: [])
		transport.emit(#"{"type":"agent_start"}"#)
		await settle()

		try await Task.sleep(for: .milliseconds(500))
		await settle()
		#expect(transport.isRunning)
	}

	// MARK: - Interactive requests

	@Test("an approval prompt is surfaced inline and answered over the same id")
	func approvalRoundTrip() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		transport.emit("""
		{"type":"extension_ui_request","id":"ui_7","method":"select",\
		"title":"Allow tool: bash\\nCommand: rm -rf build","options":["Approve","Deny"]}
		""")
		await settle()

		guard case .request(let pending) = coordinator.items.last else {
			Issue.record("expected an inline request")
			return
		}
		#expect(pending.request.isApprovalPrompt)

		coordinator.answer(requestId: "ui_7", with: .value("Deny"))
		await settle()

		let answered = transport.sent.contains { entry in
			guard case .extensionUIResponse(let id, let answer) = entry.command else { return false }
			return id == "ui_7" && answer == .value("Deny")
		}
		#expect(answered)
	}

	@Test("fire-and-forget UI frames never become pending requests")
	func nonBlockingUIFramesAreIgnored() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		transport.emit(#"{"type":"extension_ui_request","id":"w1","method":"setWidget","widgetKey":"autoresearch"}"#)
		transport.emit(#"{"type":"extension_ui_request","id":"s1","method":"setStatus","statusKey":"k","statusText":"x"}"#)
		await settle()

		let requests = coordinator.items.filter {
			if case .request = $0 { return true }
			return false
		}
		#expect(requests.isEmpty)
	}

	// MARK: - Local commands

	@Test("/status reports without starting OMP")
	func statusCommandDoesNotStartProcess() async {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)

		await coordinator.submit(text: "/status", attachments: [])
		#expect(!transport.isRunning)
		guard case .notice(let entry) = coordinator.items.last else {
			Issue.record("expected a notice")
			return
		}
		#expect(entry.text.contains("Workspace:"))
	}

	@Test("/cd rejects a path that is not a directory and keeps the workspace")
	func changeDirectoryRejectsBadPath() async {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		let original = coordinator.workspace

		await coordinator.submit(text: "/cd /nao/existe/em/lugar/nenhum", attachments: [])
		#expect(coordinator.workspace == original)
		guard case .failure = coordinator.items.last else {
			Issue.record("expected a failure entry")
			return
		}
	}

	@Test("/cd to a real directory stops the running process, since cwd is fixed at launch")
	func changeDirectoryRestartsProcess() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		let target = FileManager.default.temporaryDirectory
		await coordinator.submit(text: "/cd \(target.path)", attachments: [])
		await settle()

		#expect(!transport.isRunning)
		#expect(coordinator.workspace.url == target.standardizedFileURL)
	}

	// MARK: - API key

	@Test("/key writes to the keychain without leaking the value into the transcript")
	func setKeyStoresWithoutLeaking() async {
		let transport = FakeOmpTransport()
		let store = KeyStoreSpy(current: nil)
		let coordinator = makeCoordinator(transport: transport, apiKey: nil, keyStore: store)

		let secret = "sk-live-abcdefghijklmnop9876"
		await coordinator.submit(text: "/key \(secret)", attachments: [])

		#expect(store.current == secret)
		// Nothing rendered may contain the key, and no user turn is recorded.
		let rendered = coordinator.items.compactMap(\.copyableText).joined(separator: "\n")
		#expect(!rendered.contains(secret))
		#expect(!rendered.contains("abcdefghijklmnop"))
		#expect(!coordinator.items.contains { if case .user = $0 { return true } else { return false } })
		// Only the last four characters are echoed back.
		#expect(rendered.contains("••••9876"))
	}

	@Test("/key does not start OMP, and surrounding whitespace is trimmed")
	func setKeyTrimsAndDoesNotBoot() async {
		let transport = FakeOmpTransport()
		let store = KeyStoreSpy(current: nil)
		let coordinator = makeCoordinator(transport: transport, apiKey: nil, keyStore: store)

		await coordinator.submit(text: "/key   sk-padded-1234   ", attachments: [])

		#expect(store.current == "sk-padded-1234")
		#expect(!transport.isRunning)
	}

	@Test("/key with no argument reports presence without revealing anything")
	func bareKeyCommandReportsStatus() async {
		let transport = FakeOmpTransport()
		let store = KeyStoreSpy(current: "sk-existing-0000")
		let coordinator = makeCoordinator(transport: transport, keyStore: store)

		await coordinator.submit(text: "/key", attachments: [])

		guard case .notice(let entry) = coordinator.items.last else {
			Issue.record("expected a notice")
			return
		}
		#expect(entry.text.contains("configurada"))
		#expect(!entry.text.contains("sk-existing"))
	}

	@Test("changing the key stops a running OMP, whose environment cannot be updated")
	func newKeyRestartsProcess() async throws {
		let transport = FakeOmpTransport()
		let store = KeyStoreSpy(current: "sk-old-1111")
		let coordinator = makeCoordinator(transport: transport, keyStore: store)
		try await coordinator.ensureRunning()
		#expect(transport.isRunning)

		await coordinator.submit(text: "/key sk-new-2222", attachments: [])
		await settle()

		#expect(store.current == "sk-new-2222")
		#expect(!transport.isRunning)
	}

	@Test("a keychain write failure is surfaced and the old key is kept")
	func keyWriteFailureIsReported() async {
		let transport = FakeOmpTransport()
		let store = KeyStoreSpy(current: "sk-old-1111", failWrites: true)
		let coordinator = makeCoordinator(transport: transport, keyStore: store)

		await coordinator.submit(text: "/key sk-new-2222", attachments: [])

		#expect(store.current == "sk-old-1111")
		guard case .failure(let entry) = coordinator.items.last else {
			Issue.record("expected a failure entry")
			return
		}
		#expect(entry.text.contains("Keychain"))
		#expect(!(entry.detail ?? "").contains("sk-new"))
	}

	@Test("masking never exposes more than the last four characters")
	func maskingIsConservative() {
		#expect(AgentCoordinator.masked("sk-live-abcdefghijklmnop9876") == "••••9876")
		#expect(AgentCoordinator.masked("abcd") == "••••••••")
		#expect(AgentCoordinator.masked("") == "••••••••")
	}

	// MARK: - Images

	@Test("a text-only model still receives the image, for inspect_image to delegate")
	func imageSentForVisionDelegation() async throws {
		// The primary model cannot read images, but a vision model is configured,
		// so OMP's `inspect_image` picks the attachment up. Refusing here would
		// block a path that works.
		#expect(AppConfiguration.visionModelSelector != nil)

		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		#expect(!coordinator.modelSupportsImages)

		let attachment = PendingAttachment.image(
			RpcImage(mimeType: "image/png", base64Data: "aW1n"),
			label: "Imagem PNG"
		)
		await coordinator.submit(text: "o que é isto?", attachments: [attachment])
		await settle()

        let images = transport.sent.compactMap { entry -> [RpcImage]? in
			guard case .prompt(_, let images, _) = entry.command else { return nil }
			return images
		}.first
		#expect(images?.count == 1)
		let refused = coordinator.items.contains {
			if case .failure = $0 { return true }
			return false
		}
		#expect(!refused)
	}

	@Test("an image reaches the wire as ImageContent when the model accepts it")
	func imageSentOnMultimodalModel() async throws {
		let transport = FakeOmpTransport()
		transport.modelInputs = ["text", "image"]
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		let attachment = PendingAttachment.image(
			RpcImage(mimeType: "image/png", base64Data: "aW1n"),
			label: "Imagem PNG"
		)
		await coordinator.submit(text: "descreva", attachments: [attachment])
		await settle()

		let images = transport.sent.compactMap { entry -> [RpcImage]? in
			guard case .prompt(_, let images, _) = entry.command else { return nil }
			return images
		}.first
		#expect(images?.count == 1)
		#expect(images?.first?.mimeType == "image/png")
	}

	@Test("attached paths travel as absolute paths for OMP's own read tools")
	func filePathsAreInlinedAsPaths() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		let url = URL(fileURLWithPath: "/tmp/exemplo.txt")
		await coordinator.submit(
			text: "resuma",
			attachments: [PendingAttachment.path(url, isDirectory: false)]
		)
		await settle()

		let message = transport.sent.compactMap { entry -> String? in
			guard case .prompt(let message, _, _) = entry.command else { return nil }
			return message
		}.first
		#expect(message?.contains("/tmp/exemplo.txt") == true)
		#expect(message?.contains("arquivo:") == true)
	}
}

@MainActor
@Suite("Plan / build mode")
struct AgentModeTests {
	private func makeCoordinator(transport: FakeOmpTransport) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.mode.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	private func settle(_ turns: Int = 6) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(20))
		for _ in 0..<turns { await Task.yield() }
	}

	@Test("plan mode restricts the tool registry to read-only tools")
	func planAllowListIsReadOnly() {
		let tools = try! #require(AgentMode.plan.toolAllowList)
		// The mode's entire promise is "changes nothing"; these would break it.
		for mutating in ["write", "edit", "bash", "python", "notebook", "browser", "computer", "task"] {
			#expect(!tools.contains(mutating), "\(mutating) must not survive plan mode")
		}
		#expect(tools.contains("read"))
		#expect(tools.contains("grep"))
	}

	@Test("build mode passes no allow-list, so a newly added tool stays available")
	func buildKeepsEveryTool() {
		#expect(AgentMode.build.toolAllowList == nil)
		#expect(!AgentMode.build.launchArguments.contains("--tools"))
	}

	@Test("plan mode reaches omp as --tools")
	func planLaunchArguments() {
		let arguments = AgentMode.plan.launchArguments
		let index = try! #require(arguments.firstIndex(of: "--tools"))
		#expect(arguments[index + 1].contains("read"))
		#expect(!arguments[index + 1].contains("bash"))
	}

	@Test("toggling flips between the two modes")
	func toggleFlips() {
		let coordinator = makeCoordinator(transport: FakeOmpTransport())
		let initial = coordinator.mode
		#expect(coordinator.toggleMode())
		#expect(coordinator.mode == initial.next)
		#expect(coordinator.toggleMode())
		#expect(coordinator.mode == initial)
	}

	@Test("the process launches with the selected mode")
	func launchesWithSelectedMode() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		coordinator.setMode(.plan)

		try await coordinator.ensureRunning()
		#expect(transport.launchedMode == .plan)
	}

	@Test("switching mode under a live process restarts it exactly once")
	func modeChangeRestartsProcess() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		#expect(transport.launchCount == 1)
		#expect(!coordinator.modeIsPending)

		coordinator.setMode(.plan)
		#expect(coordinator.modeIsPending)

		try await coordinator.ensureRunning()
		#expect(transport.launchCount == 2)
		#expect(transport.launchedMode == .plan)
		#expect(!coordinator.modeIsPending)
	}

	@Test("no restart when the mode did not actually change")
	func sameModeDoesNotRestart() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		coordinator.setMode(coordinator.mode)
		try await coordinator.ensureRunning()
		#expect(transport.launchCount == 1)
	}

	@Test("the session survives a mode switch, so the plan stays in context")
	func sessionSurvivesModeSwitch() async throws {
		// A real file on disk: `restoreSessionIfPossible` only issues
		// `switch_session` for a session that actually exists, so a fake path
		// would silently skip the very behaviour under test.
		let sessionFile = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-session-\(UUID().uuidString).jsonl")
		try Data("{}\n".utf8).write(to: sessionFile)
		defer { try? FileManager.default.removeItem(at: sessionFile) }

		let transport = FakeOmpTransport()
		transport.sessionFile = sessionFile.path
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await settle()

		coordinator.setMode(.plan)
		try await coordinator.ensureRunning()
		await settle()

		#expect(transport.commandTypes().contains("switch_session"))
	}

	@Test("the mode cannot change mid-run, and says why")
	func lockedWhileBusy() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		await coordinator.submit(text: "trabalha", attachments: [])
        transport.emit(#"{"type":"agent_start"}"#)
		await settle()
		#expect(coordinator.isBusy)

		let before = coordinator.mode
		#expect(!coordinator.toggleMode())
		#expect(coordinator.mode == before)
		guard case .notice(let entry) = coordinator.items.last else {
			Issue.record("expected a notice")
			return
		}
		#expect(entry.level == .warning)
	}

	@Test("the chosen mode is remembered across launches")
	func modePersists() {
		let suite = "rune.mode.persist.\(UUID().uuidString)"
		let defaults = UserDefaults(suiteName: suite)!

		let first = AgentCoordinator(
			transport: FakeOmpTransport(),
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
		first.setMode(.plan)

		let second = AgentCoordinator(
			transport: FakeOmpTransport(),
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
		#expect(second.mode == .plan)
	}
}

@MainActor
@Suite("Conversation restore")
struct ConversationRestoreTests {
	private func writeTranscript() throws -> String {
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-restore-\(UUID().uuidString).jsonl")
		let lines = [
			#"{"type":"session","cwd":"/Users/x/Dev","id":"s1","timestamp":"2026-08-04T00:00:00.000Z","version":3}"#,
			#"{"type":"message","id":"1","message":{"role":"user","content":[{"type":"text","text":"pergunta anterior"}]}}"#,
			#"{"type":"message","id":"2","message":{"role":"assistant","content":[{"type":"text","text":"resposta anterior"}]}}"#,
		]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
		return file.path
	}

	private func makeCoordinator(
		sessionFile: String?,
		transport: FakeOmpTransport = FakeOmpTransport()
	) -> AgentCoordinator {
		let defaults = UserDefaults(suiteName: "rune.restore.\(UUID().uuidString)")!
		if let sessionFile {
			defaults.set(sessionFile, forKey: AppConfiguration.DefaultsKey.lastSessionFile)
		}
		return AgentCoordinator(
			transport: transport,
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	@Test("the saved conversation is rendered without starting OMP")
	func restoresWithoutBooting() async throws {
		let path = try writeTranscript()
		defer { try? FileManager.default.removeItem(atPath: path) }

		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(sessionFile: path, transport: transport)
		#expect(coordinator.items.isEmpty)

		await coordinator.restoreConversationFromDisk()

		// This is the whole point: the history appears with no process running,
		// so reopening the panel after a relaunch is not blank.
		#expect(!transport.isRunning)
		#expect(coordinator.items.count == 2)
		#expect(coordinator.hasConversation)
	}

	@Test("restoring never overwrites a conversation already on screen")
	func doesNotClobberLiveItems() async throws {
		let path = try writeTranscript()
		defer { try? FileManager.default.removeItem(atPath: path) }

		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(sessionFile: path, transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "mensagem nova", attachments: [])

		let before = coordinator.items.count
        await coordinator.restoreConversationFromDisk()
		#expect(coordinator.items.count == before)
	}

	@Test("no saved session means nothing is restored and nothing breaks")
	func noSessionIsSafe() async {
		let coordinator = makeCoordinator(sessionFile: nil)
		await coordinator.restoreConversationFromDisk()
		#expect(coordinator.items.isEmpty)
	}

	@Test("a session file that no longer exists is ignored")
	func missingFileIsSafe() async {
		let coordinator = makeCoordinator(sessionFile: "/tmp/rune-sumiu-\(UUID().uuidString).jsonl")
		await coordinator.restoreConversationFromDisk()
		#expect(coordinator.items.isEmpty)
	}
}

@Suite("Approval policy")
struct ApprovalPolicyTests {
	@Test("neither mode prompts — plan is safe by its registry, build by choice")
	func bothModesAutoApprove() {
		for mode in AgentMode.allCases {
			#expect(mode.approvalMode == "yolo", "\(mode.label) must not prompt")
		}
	}

	@Test("the approval mode reaches omp on the command line")
	func approvalReachesTheCommandLine() {
		for mode in AgentMode.allCases {
			let arguments = mode.launchArguments
			let index = arguments.firstIndex(of: "--approval-mode")
			#expect(index != nil, "\(mode.label) never passes --approval-mode")
			#expect(arguments[index! + 1] == "yolo")
		}
	}

	@Test("plan still ships its read-only allow-list alongside the approval flag")
	func planKeepsItsAllowList() {
		let arguments = AgentMode.plan.launchArguments
		let index = try! #require(arguments.firstIndex(of: "--tools"))
		let tools = arguments[index + 1]
		// Auto-approval only stays safe because these are simply absent.
		for mutating in ["write", "edit", "bash", "python", "notebook", "browser", "computer", "task"] {
			#expect(!tools.split(separator: ",").contains(Substring(mutating)))
		}
		#expect(tools.contains("read"))
	}

	@Test("build passes no allow-list, so every tool stays available")
	func buildRestrictsNothing() {
		#expect(!AgentMode.build.launchArguments.contains("--tools"))
	}
}
