import Foundation
import Testing

@testable import RuneKit

/// Regressions for the ways the run state used to get stuck, and for the ways a
/// cleared transcript used to refill itself.
@MainActor
@Suite("Run state recovery")
struct RunStateRecoveryTests {
	private func makeCoordinator(transport: FakeOmpTransport) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.recovery.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	private func settle(_ turns: Int = 6) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(20))
		for _ in 0..<turns { await Task.yield() }
	}

	/// Drives the coordinator to a state where a turn is genuinely running.
	private func startTurn(_ coordinator: AgentCoordinator, _ transport: FakeOmpTransport) async {
		await coordinator.submit(text: "oi", attachments: [])
		transport.emit(#"{"type":"agent_start"}"#)
		await settle()
	}

	@Test("aborting with nothing running is a no-op, not a permanent aborting state")
	func abortWhenIdleDoesNothing() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		#expect(coordinator.runState == .ready)

		// ⌘. and /abort are both reachable here, and OMP sends no `agent_end`
		// for a turn that already finished — so `.aborting` would never clear.
		await coordinator.abort()

		#expect(coordinator.runState == .ready)
		#expect(!transport.commandTypes().contains("abort"))
	}

	@Test("a failed abort restores the state it interrupted")
	func failedAbortRestoresState() async throws {
		let transport = FakeOmpTransport()
		transport.failsAbort = true
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await startTurn(coordinator, transport)
		#expect(coordinator.runState == .thinking)

		await coordinator.abort()

		#expect(coordinator.runState == .thinking)
		#expect(coordinator.items.contains { if case .failure = $0 { return true } else { return false } })
	}

	@Test("a successful abort still ends the run when agent_end arrives")
	func successfulAbortSettles() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await startTurn(coordinator, transport)

		await coordinator.abort()
		#expect(transport.commandTypes().contains("abort"))

		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()
		#expect(coordinator.runState == .ready)
	}

	@Test("a new session mid-run aborts first, so the cleared transcript stays cleared")
	func newSessionAbortsRunningTurn() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await startTurn(coordinator, transport)

		await coordinator.startNewSession()
		await settle()

		let types = transport.commandTypes()
		#expect(types.contains("abort"))
		#expect(types.contains("new_session"))
		#expect(coordinator.items.isEmpty)
	}

	@Test("text still buffered when the transcript is cleared never lands in it")
	func pendingStreamTextIsDiscardedOnClear() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await startTurn(coordinator, transport)

		transport.emit("""
		{"type":"message_update","message":{"role":"assistant"},\
		"assistantMessageEvent":{"type":"text_delta","delta":"resposta parcial"}}
		""")
		await settle(2)

		await coordinator.startNewSession()
		// Well past the flush deadline: a pending flush must not resurrect here.
		try? await Task.sleep(for: .milliseconds(200))
		await settle()

		#expect(coordinator.items.isEmpty)
	}

	@Test("a deliberate restart is not reported as a crash")
	func deliberateShutdownIsSilent() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await startTurn(coordinator, transport)

		// `/cd` shuts OMP down mid-turn on purpose. `wasBusy` is true for the
		// whole window, which used to make a clean exit(0) look like a crash.
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
		await coordinator.changeWorkspace(to: directory)
		await settle()

		let failures = coordinator.items.filter {
			if case .failure = $0 { return true }
			return false
		}
		#expect(failures.isEmpty)
	}
}

/// The streamed-text path: deltas are buffered and flushed, and the result has
/// to be indistinguishable from writing each delta straight through.
@MainActor
@Suite("Streaming coalescing")
struct StreamCoalescingTests {
	private func makeCoordinator(transport: FakeOmpTransport) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.stream.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	private func settle(_ turns: Int = 6) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(20))
		for _ in 0..<turns { await Task.yield() }
	}

	private func delta(_ text: String) -> String {
		"""
		{"type":"message_update","message":{"role":"assistant"},\
		"assistantMessageEvent":{"type":"text_delta","delta":"\(text)"}}
		"""
	}

	private func assistantText(_ coordinator: AgentCoordinator) -> String? {
		coordinator.items.compactMap { item -> String? in
			guard case .assistant(let turn) = item else { return nil }
			return turn.text
		}.last
	}

	@Test("many deltas coalesce into a single turn with the text in order")
	func deltasCoalesce() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		for word in ["um ", "dois ", "três"] { transport.emit(delta(word)) }
		await settle()
		try? await Task.sleep(for: .milliseconds(200))
		await settle()

		let turns = coordinator.items.filter {
			if case .assistant = $0 { return true }
			return false
		}
		#expect(turns.count == 1)
		#expect(assistantText(coordinator) == "um dois três")
	}

	@Test("the end of a turn flushes whatever is still buffered")
	func endOfTurnFlushes() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		transport.emit(delta("resposta"))
		// No sleep: `agent_end` lands while the flush deadline is still pending.
		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()

		#expect(assistantText(coordinator) == "resposta")
		#expect(coordinator.runState == .ready)
	}

	@Test("a tool call cannot jump ahead of text that is still buffered")
	func bufferedTextKeepsItsPlace() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		await settle()

		transport.emit(delta("vou ler o arquivo"))
		transport.emit("""
		{"type":"tool_execution_start","toolCallId":"t1","toolName":"read",\
		"args":{"path":"/tmp/x.swift"}}
		""")
		await settle()

		let kinds = coordinator.items.compactMap { item -> String? in
			switch item {
			case .assistant: return "assistant"
			case .tool: return "tool"
			default: return nil
			}
		}
		#expect(kinds == ["assistant", "tool"])
		#expect(assistantText(coordinator) == "vou ler o arquivo")
	}
}

@Suite("Tool argument clamping")
struct ToolArgumentClampingTests {
	@Test("a huge string leaf is truncated at construction, not at render time")
	func argumentsAreClamped() {
		let body = String(repeating: "x", count: AppConfiguration.maxRenderedToolResultCharacters * 3)
		let activity = ToolActivity(
			id: "t1",
			name: "write",
			arguments: .object(["path": .string("/tmp/a.swift"), "content": .string(body)])
		)

		let stored = activity.arguments["content"]?.stringValue
		#expect(stored?.count == AppConfiguration.maxRenderedToolResultCharacters + 1)
		#expect(activity.arguments["path"]?.stringValue == "/tmp/a.swift")
	}

	@Test("clamping walks nested arrays and objects and leaves non-strings alone")
	func clampingIsRecursive() {
		let value = JSONValue.object([
			"edits": .array([.object(["new": .string("abcdef")])]),
			"count": .number(3),
			"dry": .bool(true),
			"none": .null,
		])

		let clamped = value.clampingStrings(to: 3)
		#expect(clamped["edits"]?[0]?["new"]?.stringValue == "abc…")
		#expect(clamped["count"]?.doubleValue == 3)
		#expect(clamped["dry"]?.boolValue == true)
		#expect(clamped["none"] == JSONValue.null)
	}

	@Test("a string already within the limit is left untouched")
	func shortStringsAreUnchanged() {
		#expect(JSONValue.string("oi").clampingStrings(to: 10) == .string("oi"))
	}
}
