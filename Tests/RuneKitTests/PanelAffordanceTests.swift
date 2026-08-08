import AppKit
import Testing

@testable import RuneKit

@MainActor
@Suite("Retry after a failure")
struct RetryAffordanceTests {
	private func makeCoordinator(transport: FakeOmpTransport) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.retry.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	private func settle(_ turns: Int = 6) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(20))
		for _ in 0..<turns { await Task.yield() }
	}

	@Test("nothing to retry before anything has been sent")
	func nothingToRetryInitially() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		#expect(coordinator.retryableMessage == nil)
	}

	@Test("the last user message is what a retry would send")
	func lastMessageIsRetryable() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "primeira", attachments: [])
		await settle()
		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()
		await coordinator.submit(text: "segunda", attachments: [])
		await settle()
		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()

		#expect(coordinator.retryableMessage == "segunda")
	}

	@Test("a message with an attachment is not offered, since the file would be dropped")
	func attachmentsBlockRetry() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()

		let file = URL(fileURLWithPath: "/tmp/rune-retry-test.txt")
		await coordinator.submit(text: "olha isso", attachments: [.path(file, isDirectory: false)])
		await settle()
		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()

		// `UserTurn` only keeps a summary of an attachment, so re-sending would
		// quietly produce a different request from the one that failed.
		#expect(coordinator.retryableMessage == nil)
	}

	@Test("nothing is offered while a turn is still running")
	func noRetryWhileBusy() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "oi", attachments: [])
		transport.emit(#"{"type":"agent_start"}"#)
		await settle()

		#expect(coordinator.runState.isBusy)
		#expect(coordinator.retryableMessage == nil)
	}

	@Test("retrying sends the message again")
	func retryResends() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "roda os testes", attachments: [])
		await settle()
		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()

		await coordinator.retryLastMessage()
		await settle()

		let prompts = transport.sent.compactMap { sent -> String? in
			guard case .prompt(let message, _, _) = sent.command else { return nil }
			return message
		}
		#expect(prompts == ["roda os testes", "roda os testes"])
	}
}

@MainActor
@Suite("Menu bar completion mark")
struct StatusItemCompletionTests {
	@Test("finishing with the panel closed marks the icon, and opening it clears the mark")
	func completionMarkLifecycle() {
		let item = StatusItemController()
		item.update(state: .ready, panelIsVisible: false)
		#expect(!item.showsCompletionMark)

		item.update(state: .thinking, panelIsVisible: false)
		item.update(state: .ready, panelIsVisible: false)
		// "Done" and "never ran" used to render identically, so the only way to
		// find out was to reopen the panel.
		#expect(item.showsCompletionMark)

		item.acknowledgeCompletion()
		#expect(!item.showsCompletionMark)
	}

	@Test("finishing with the panel open marks nothing — the user is already looking")
	func noMarkWhenPanelIsVisible() {
		let item = StatusItemController()
		item.update(state: .thinking, panelIsVisible: true)
		item.update(state: .ready, panelIsVisible: true)
		#expect(!item.showsCompletionMark)
	}

	@Test("a new run clears a pending mark")
	func newRunClearsMark() {
		let item = StatusItemController()
		item.update(state: .thinking, panelIsVisible: false)
		item.update(state: .ready, panelIsVisible: false)
		#expect(item.showsCompletionMark)

		item.update(state: .thinking, panelIsVisible: false)
		#expect(!item.showsCompletionMark)
	}
}

@Suite("Context gauge thresholds")
struct ContextGaugeTests {
	@Test("the gauge stays hidden until the context is worth worrying about")
	func thresholds() {
		#expect(ComposerFooter.contextWarningPercent < ComposerFooter.contextCriticalPercent)
		#expect(ComposerFooter.contextWarningPercent > 0)
		#expect(ComposerFooter.contextCriticalPercent < 100)
	}
}
