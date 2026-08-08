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

@MainActor
@Suite("Context gauge thresholds")
struct ContextGaugeTests {
	@Test("the gauge stays hidden until the context is worth worrying about")
	func thresholds() {
		#expect(ComposerFooter.contextWarningPercent < ComposerFooter.contextCriticalPercent)
		#expect(ComposerFooter.contextWarningPercent > 0)
		#expect(ComposerFooter.contextCriticalPercent < 100)
	}
}

@MainActor
@Suite("API key caching")
struct APIKeyCacheTests {
	/// Counts reads so the number of keychain hits is observable — each one is a
	/// password prompt on an ad-hoc signed build.
	private final class CountingProvider: @unchecked Sendable {
		private let lock = NSLock()
		private var count = 0
		var value: String?

		init(value: String?) { self.value = value }

		var reads: Int {
			lock.lock()
			defer { lock.unlock() }
			return count
		}

		func read() -> String? {
			lock.lock()
			count += 1
			let current = value
			lock.unlock()
			return current
		}
	}

	private func makeCoordinator(
		transport: FakeOmpTransport,
		provider: CountingProvider
	) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.key.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { provider.read() }
		)
	}

	@Test("the key is read once, not once per omp boot")
	func readOncePerLaunch() async throws {
		let transport = FakeOmpTransport()
		let provider = CountingProvider(value: "sk-test")
		let coordinator = makeCoordinator(transport: transport, provider: provider)

		try await coordinator.ensureRunning()
		let afterFirstBoot = provider.reads

		// A mode change restarts omp, which is the path that used to re-read —
		// and with the idle reaper stopping omp after ten minutes, that meant a
		// password prompt per conversation.
		_ = coordinator.setMode(coordinator.mode == .build ? .plan : .build)
		try await coordinator.ensureRunning()

		#expect(afterFirstBoot == 1)
		#expect(provider.reads == 1)
	}

	@Test("a missing key is re-checked, so one stored from the terminal is picked up")
	func absentKeyIsNotCached() async throws {
		let transport = FakeOmpTransport()
		let provider = CountingProvider(value: nil)
		let coordinator = makeCoordinator(transport: transport, provider: provider)

		// No item exists, so the read cannot prompt — caching the nil would only
		// force a relaunch after `set-opencode-key.sh`.
		await #expect(throws: AgentError.self) { try await coordinator.ensureRunning() }
		provider.value = "sk-later"
		try await coordinator.ensureRunning()

		#expect(coordinator.runState == .ready)
	}
}

@MainActor
@Suite("Auto-scroll pinning")
struct AutoScrollPinningTests {
	@Test("an anchor that never reported is not treated as being at the bottom")
	func missingAnchorDoesNotPin() {
		// The 1pt anchor lives in a `LazyVStack`: scroll far enough up and it is
		// discarded, so no child supplies the preference and `onPreferenceChange`
		// fires with the default. A default that reads as "pinned" resurrects the
		// bug 0.10.0 fixed, in exactly the long-transcript case that needs it.
		#expect(!ConversationView.isPinned(distanceFromBottom: DistanceFromBottom.defaultValue))
	}

	@Test("resting at the bottom stays pinned, scrolling away does not")
	func thresholdBehaviour() {
		#expect(ConversationView.isPinned(distanceFromBottom: 0))
		#expect(ConversationView.isPinned(distanceFromBottom: 12))
		#expect(!ConversationView.isPinned(distanceFromBottom: 400))
	}
}

@Suite("Completion notification wording")
struct CompletionWordingTests {
	@Test("a crash mid-turn is not announced as a completed task")
	func stoppedIsNotSuccess() {
		// `handleTermination` sets `.stopped`, not `.failed`, so the default arm
		// reported a dead child as a finished job.
		let body = CompletionNotifier.body(for: .stopped, workspaceName: "rune")
		#expect(!body.contains("concluída"))
	}

	@Test("a real finish and a failure keep their own wording")
	func otherStatesUnchanged() {
		#expect(CompletionNotifier.body(for: .ready, workspaceName: "rune").contains("concluída"))
		#expect(CompletionNotifier.body(for: .failed("boom"), workspaceName: "rune").contains("boom"))
	}
}
