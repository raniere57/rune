import Foundation
import Testing

@testable import RuneKit

@MainActor
@Suite("Context across an idle shutdown")
struct IdleContextTests {
	private func settle(_ turns: Int = 8) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(30))
		for _ in 0..<turns { await Task.yield() }
	}

	@Test("the second prompt after an idle shutdown resumes the same session")
	func resumesAfterIdleShutdown() async throws {
		// A real transcript on disk, the way OMP leaves one behind.
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-idle-\(UUID().uuidString).jsonl")
		try #"{"type":"session","cwd":"/tmp","id":"s1","timestamp":"2026-08-04T00:00:00.000Z","version":3}"#
			.appending("\n")
			.write(to: file, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: file) }

		let transport = FakeOmpTransport()
		transport.sessionFile = file.path
		let coordinator = AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.idlectx.\(UUID().uuidString)")!,
			idleInterval: 0.15,
			apiKeyProvider: { "test-key" }
		)

		// First turn.
		await coordinator.submit(text: "primeira", attachments: [])
		await settle()
		transport.emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#)
		await settle()

		// Idle shutdown reaps the process.
		try await Task.sleep(for: .milliseconds(600))
		await settle()
		#expect(!transport.isRunning, "o idle shutdown deveria ter encerrado o omp")

		// Second turn boots a fresh process.
		await coordinator.submit(text: "segunda", attachments: [])
		await settle()

		let switched = transport.sent.contains { entry in
			if case .switchSession(let path) = entry.command { return path == file.path }
			return false
		}
		#expect(switched, "sem switch_session o modelo perde todo o contexto anterior")

		// And the switch must happen BEFORE the prompt, or the prompt lands in
		// the fresh session that OMP created on startup.
		let types = transport.commandTypes()
		if let switchIndex = types.firstIndex(of: "switch_session"),
		   let promptIndex = types.lastIndex(of: "prompt") {
			#expect(switchIndex < promptIndex, "o prompt foi enviado antes do switch_session")
		}
	}
}

@MainActor
@Suite("Screen and model never diverge")
struct SessionIntegrityTests {
	private func settle(_ turns: Int = 8) async {
		for _ in 0..<turns { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(30))
		for _ in 0..<turns { await Task.yield() }
	}

	private func makeCoordinator(transport: FakeOmpTransport) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.integrity.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	@Test("changing the workspace clears the transcript along with the session")
	func workspaceChangeClearsTranscript() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)
		try await coordinator.ensureRunning()
		await coordinator.submit(text: "mensagem da conversa antiga", attachments: [])
		await settle()
		#expect(coordinator.hasConversation)

		await coordinator.changeWorkspace(to: FileManager.default.temporaryDirectory)
		await settle()

		// The session was reset, so nothing from before may stay on screen —
		// a visible history the model cannot see is the worst possible state.
		let carriedOver = coordinator.items.contains {
            if case .user(let turn) = $0 { return turn.text.contains("conversa antiga") }
			return false
		}
		#expect(!carriedOver)
	}

	@Test("a cancelled switch_session is treated as a failure, not a success")
	func cancelledSwitchIsAFailure() async throws {
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-cancel-\(UUID().uuidString).jsonl")
		try #"{"type":"session","cwd":"/tmp","id":"s1","timestamp":"2026-08-04T00:00:00.000Z","version":3}"#
			.appending("\n")
			.write(to: file, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: file) }

		let defaults = UserDefaults(suiteName: "rune.integrity.\(UUID().uuidString)")!
		defaults.set(file.path, forKey: AppConfiguration.DefaultsKey.lastSessionFile)

		let transport = FakeOmpTransport()
		transport.sessionFile = file.path
		transport.cancelsSwitchSession = true

		let coordinator = AgentCoordinator(
			transport: transport,
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
		try await coordinator.ensureRunning()
		await settle()

		// `success: true, cancelled: true` used to pass silently, leaving the
		// model on a different session than the panel showed.
		let warned = coordinator.items.contains {
			guard case .notice(let entry) = $0 else { return false }
			return entry.level == .warning && entry.text.contains("retomar")
		}
		#expect(warned, "uma troca cancelada precisa ser visível")
	}

	@Test("a session that loads a different transcript than requested is rejected")
	func mismatchedSessionIsRejected() async throws {
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-mismatch-\(UUID().uuidString).jsonl")
		try #"{"type":"session","cwd":"/tmp","id":"s1","timestamp":"2026-08-04T00:00:00.000Z","version":3}"#
			.appending("\n")
			.write(to: file, atomically: true, encoding: .utf8)
		defer { try? FileManager.default.removeItem(at: file) }

		let defaults = UserDefaults(suiteName: "rune.integrity.\(UUID().uuidString)")!
		defaults.set(file.path, forKey: AppConfiguration.DefaultsKey.lastSessionFile)

		let transport = FakeOmpTransport()
		// `switch_session` reports success but `get_state` keeps reporting a
		// different file — exactly the divergence that has to be caught.
		transport.sessionFile = "/tmp/rune-outra-sessao.jsonl"

		let coordinator = AgentCoordinator(
			transport: transport,
			defaults: defaults,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
		try await coordinator.ensureRunning()
		await settle()

		let warned = coordinator.items.contains {
			guard case .notice(let entry) = $0 else { return false }
			return entry.level == .warning
		}
		#expect(warned, "uma sessão divergente precisa ser detectada")
	}
}
