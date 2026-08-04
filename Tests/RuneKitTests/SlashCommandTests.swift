import Foundation
import Testing

@testable import RuneKit

@Suite("Slash command matching")
struct SlashCommandTests {
	private let catalogue: [SlashCommand] = SlashCommand.local + [
		SlashCommand(name: "compact", summary: "Compact the conversation", source: .omp),
		SlashCommand(name: "context", summary: "Show context usage", source: .omp),
		SlashCommand(name: "code-review", summary: "Code review", source: .omp),
		SlashCommand(name: "computer", summary: "Toggle computer use", source: .omp),
		SlashCommand(name: "vision", summary: "Toggle vision delegation", source: .omp),
	]

	private func names(_ query: String) -> [String] {
		SlashCommand.matches(query, in: catalogue).map(\.name)
	}

	@Test("an empty query lists everything with the app's own commands first")
	func emptyQueryPrefersLocal() {
		let result = SlashCommand.matches("", in: catalogue)
		#expect(result.count == catalogue.count)
		#expect(result.prefix(SlashCommand.local.count).allSatisfy { $0.source == .local })
	}

	@Test("prefix matches outrank mid-string ones")
	func prefixBeatsSubstring() {
		let result = names("co")
		let prefixed = ["compact", "context", "code-review", "computer"]
		#expect(Set(result.prefix(4)) == Set(prefixed))
	}

	@Test("an exact name wins even when longer names also match")
	func exactMatchWins() {
		#expect(names("new").first == "new")
		#expect(names("compact").first == "compact")
	}

	@Test("shorter names rank above longer ones at equal match quality")
	func shorterNamesFirst() {
		let result = names("c")
		let compactIndex = result.firstIndex(of: "compact")
		let codeReviewIndex = result.firstIndex(of: "code-review")
		#expect(compactIndex != nil && codeReviewIndex != nil)
		#expect(compactIndex! < codeReviewIndex!)
	}

	@Test("a local command outranks an OMP one at equal match quality")
	func localOutranksOmp() {
		let result = SlashCommand.matches("c", in: catalogue)
		let firstLocal = result.firstIndex { $0.source == .local }
		let firstOmp = result.firstIndex { $0.source == .omp }
		#expect(firstLocal != nil && firstOmp != nil)
		#expect(firstLocal! < firstOmp!)
	}

	@Test("descriptions are searchable, ranked below name matches")
	func descriptionMatchesRankLast() {
		let result = names("delegation")
		#expect(result == ["vision"])
	}

	@Test("a query matching nothing returns nothing")
	func noMatch() {
		#expect(names("zzzznada").isEmpty)
	}

	@Test("matching ignores case")
	func caseInsensitive() {
		#expect(names("COMPACT").first == "compact")
	}

	@Test("a command taking an argument completes with a trailing space")
	func completionKeepsTyping() {
		let key = SlashCommand.local.first { $0.name == "key" }!
		#expect(key.completion == "/key ")
	}
}

@MainActor
@Suite("Composer slash suggestions")
struct ComposerSuggestionTests {
	private func makeComposer() -> (ComposerModel, FakeOmpTransport, AgentCoordinator) {
		let transport = FakeOmpTransport()
		let coordinator = AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.suggest.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
		return (ComposerModel(coordinator: coordinator), transport, coordinator)
	}

	@Test("typing a bare slash opens the list")
	func slashOpensList() {
		let (composer, _, _) = makeComposer()
		#expect(!composer.isSuggesting)
		composer.text = "/"
		#expect(composer.isSuggesting)
		#expect(composer.suggestions.contains { $0.name == "key" })
	}

	@Test("the list narrows as the command is typed")
	func listNarrows() {
		let (composer, _, _) = makeComposer()
		composer.text = "/st"
		#expect(composer.suggestions.map(\.name) == ["status"])
	}

	@Test("a space closes the list, since the argument is being typed")
	func spaceClosesList() {
		let (composer, _, _) = makeComposer()
		composer.text = "/key"
		#expect(composer.isSuggesting)
		composer.text = "/key "
		#expect(!composer.isSuggesting)
	}

	@Test("ordinary text never opens the list")
	func plainTextDoesNotSuggest() {
		let (composer, _, _) = makeComposer()
		composer.text = "explica esse erro"
		#expect(!composer.isSuggesting)
	}

	@Test("arrows wrap around the list and are only consumed while it is open")
	func selectionWraps() {
		let (composer, _, _) = makeComposer()
		#expect(!composer.moveSelection(by: 1))

		composer.text = "/"
		let count = composer.suggestions.count
		#expect(composer.moveSelection(by: -1))
		#expect(composer.selectedSuggestion == count - 1)
		#expect(composer.moveSelection(by: 1))
		#expect(composer.selectedSuggestion == 0)
	}

	@Test("accepting inserts the completion and closes the list")
	func acceptCompletes() {
		let (composer, _, _) = makeComposer()
		composer.text = "/ab"
		#expect(composer.acceptSuggestion())
		#expect(composer.text == "/abort ")
		#expect(!composer.isSuggesting)
	}

	@Test("accepting with no list open leaves the text alone, so Enter still sends")
	func acceptIsNoOpWhenClosed() {
		let (composer, _, _) = makeComposer()
		composer.text = "olá"
		#expect(!composer.acceptSuggestion())
		#expect(composer.text == "olá")
	}

	@Test("Esc closes the list without reopening on the next keystroke")
	func dismissStaysDismissed() {
		let (composer, _, _) = makeComposer()
		composer.text = "/ke"
		#expect(composer.dismissSuggestions())
		#expect(!composer.isSuggesting)

		composer.text = "/key"
		#expect(!composer.isSuggesting)

		// Starting a different word arms the list again.
		composer.text = "hello"
		composer.text = "/n"
		#expect(composer.isSuggesting)
	}

	@Test("Esc with no list open is not consumed, so it still closes the panel")
	func dismissIsNoOpWhenClosed() {
		let (composer, _, _) = makeComposer()
		#expect(!composer.dismissSuggestions())
	}

	@Test("commands advertised by OMP join the list and outlive the process")
	func ompCommandsAreMergedAndCached() async throws {
		let (composer, transport, coordinator) = makeComposer()
		try await coordinator.ensureRunning()

		transport.emit("""
		{"type":"available_commands_update","commands":[\
		{"name":"compact","description":"Compact the conversation"},\
		{"name":"status","description":"duplicata que o app já trata"}]}
		""")
		for _ in 0..<6 { await Task.yield() }
		try? await Task.sleep(for: .milliseconds(20))

		composer.text = "/comp"
		#expect(composer.suggestions.contains { $0.name == "compact" && $0.source == .omp })

		// A name collision keeps the app's own handler, not OMP's description.
		let status = coordinator.availableCommands.filter { $0.name == "status" }
		#expect(status.count == 1)
		#expect(status.first?.source == .local)
	}
}

@Suite("Session store")
struct SessionStoreTests {
	/// Writes a transcript with the header OMP actually emits: a `title` line,
	/// then a `session` line carrying cwd/id/timestamp.
	private func writeTranscript(
		in directory: URL,
		title: String,
		cwd: String,
		id: String,
		firstUserMessage: String? = nil
	) throws -> URL {
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let file = directory.appendingPathComponent("2026-08-04T00-00-00-000Z_\(id).jsonl")
		var lines = [
			#"{"type":"title","title":"\#(title)","updatedAt":0,"v":1}"#,
			"""
			{"type":"session","cwd":"\(cwd)","id":"\(id)",\
			"timestamp":"2026-08-04T00:00:00.000Z","version":3}
			""",
		]
		if let firstUserMessage {
			lines.append(#"{"type":"message","message":{"role":"user","content":[{"type":"text","text":"\#(firstUserMessage)"}]}}"#)
		}
		try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
		return file
	}

	private func makeRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-sessions-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		return root
	}

	@Test("reads title, cwd and id out of a transcript header")
	func parsesHeader() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try writeTranscript(
			in: root.appendingPathComponent("slug-a"),
			title: "Corrigir o refresh do token",
			cwd: "/Users/x/Dev/app",
			id: "aaa"
		)

		let sessions = SessionStore.recentSessions(root: root)
		#expect(sessions.count == 1)
		#expect(sessions[0].title == "Corrigir o refresh do token")
		#expect(sessions[0].cwd == "/Users/x/Dev/app")
		#expect(sessions[0].sessionId == "aaa")
		#expect(sessions[0].workspaceName == "app")
	}

	@Test("falls back to the first user message when OMP never titled the session")
	func fallsBackToFirstMessage() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		_ = try writeTranscript(
			in: root.appendingPathComponent("slug-b"),
			title: "",
			cwd: "/Users/x/Dev/app",
			id: "bbb",
			firstUserMessage: "por que a sessão cai depois de 1h?"
		)

		let sessions = SessionStore.recentSessions(root: root)
		#expect(sessions.first?.title == "por que a sessão cai depois de 1h?")
	}

	@Test("a transcript with no session line is skipped instead of listed blank")
	func skipsHeaderlessFile() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let directory = root.appendingPathComponent("slug-c")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		try "não é jsonl válido\n".write(
			to: directory.appendingPathComponent("broken.jsonl"),
			atomically: true,
			encoding: .utf8
		)

		#expect(SessionStore.recentSessions(root: root).isEmpty)
	}

	@Test("most recently touched transcripts come first")
	func sortsByRecency() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let older = try writeTranscript(
			in: root.appendingPathComponent("slug-old"), title: "Antiga",
			cwd: "/Users/x/Dev/app", id: "old"
		)
		let newer = try writeTranscript(
			in: root.appendingPathComponent("slug-new"), title: "Recente",
			cwd: "/Users/x/Dev/app", id: "new"
		)
		try FileManager.default.setAttributes(
			[.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: older.path
		)
		try FileManager.default.setAttributes(
			[.modificationDate: Date()], ofItemAtPath: newer.path
		)

		#expect(SessionStore.recentSessions(root: root).map(\.title) == ["Recente", "Antiga"])
	}

	@Test("the limit bounds how many transcripts are opened")
	func respectsLimit() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		for index in 0..<5 {
			_ = try writeTranscript(
				in: root.appendingPathComponent("slug-\(index)"), title: "S\(index)",
				cwd: "/Users/x/Dev/app", id: "id\(index)"
			)
		}
		#expect(SessionStore.recentSessions(root: root, limit: 2).count == 2)
	}

	@Test("a missing root yields nothing rather than throwing")
	func missingRootIsEmpty() {
		let root = URL(fileURLWithPath: "/tmp/rune-nao-existe-\(UUID().uuidString)")
		#expect(SessionStore.recentSessions(root: root).isEmpty)
	}

    @Test("the sessions root is inferred from a live transcript path, honouring --profile")
	func infersRootFromSessionFile() throws {
		let root = try makeRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let file = try writeTranscript(
			in: root.appendingPathComponent("slug-a"), title: "T",
			cwd: "/Users/x", id: "aaa"
		)
		#expect(SessionStore.root(forSessionFile: file.path).path == root.path)
		// Unknown paths fall back to the default location.
		#expect(SessionStore.root(forSessionFile: nil).path == SessionStore.defaultRoot.path)
	}

	@Test("relative ages read as short human labels")
	func ageLabels() {
		func summary(secondsAgo: TimeInterval) -> SessionSummary {
			SessionSummary(
				path: "/p", sessionId: "i", cwd: "/c",
				startedAt: Date(), modifiedAt: Date().addingTimeInterval(-secondsAgo),
				title: "t"
			)
		}
		#expect(summary(secondsAgo: 10).age() == "agora")
		#expect(summary(secondsAgo: 600).age() == "10 min")
		#expect(summary(secondsAgo: 7200).age() == "2 h")
		#expect(summary(secondsAgo: 172_800).age() == "2 d")
	}
}

@Suite("Transcript to conversation")
struct TranscriptConversationTests {
	private func write(_ lines: [String]) throws -> String {
		let file = FileManager.default.temporaryDirectory
			.appendingPathComponent("rune-transcript-\(UUID().uuidString).jsonl")
		try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
		return file.path
	}

	/// Shapes taken from a real `~/.omp/agent/sessions/**.jsonl`.
	private let userLine = #"{"type":"message","id":"1","message":{"role":"user","content":[{"type":"text","text":"por que a sessão cai?"}]}}"#
	private let assistantLine = """
	{"type":"message","id":"2","message":{"role":"assistant","content":[\
	{"type":"thinking","thinking":"raciocínio interno que não deve aparecer"},\
	{"type":"text","text":"Achei o problema."}]}}
	"""
	private let toolCallLine = """
	{"type":"message","id":"3","message":{"role":"assistant","content":[\
	{"type":"toolCall","id":"call_1","name":"read","arguments":{"path":"/Users/x/Dev/app/src/AuthService.swift"}}]}}
	"""
	private let toolResultLine = """
	{"type":"message","id":"4","message":{"role":"toolResult","toolCallId":"call_1",\
	"toolName":"read","content":[{"type":"text","text":"conteúdo do arquivo"}]}}
	"""

	@Test("user and assistant turns are rebuilt, thinking is never surfaced")
	func rebuildsTurns() throws {
		let path = try write([userLine, assistantLine])
		defer { try? FileManager.default.removeItem(atPath: path) }

		let items = SessionStore.conversation(at: path)
		#expect(items.count == 2)
		guard case .user(let user) = items[0], case .assistant(let assistant) = items[1] else {
			Issue.record("expected a user turn then an assistant turn")
			return
		}
		#expect(user.text == "por que a sessão cai?")
		#expect(assistant.text == "Achei o problema.")
		#expect(assistant.isStreaming == false)
		#expect(!assistant.text.contains("raciocínio interno"))
	}

	@Test("a tool call is matched with its result by toolCallId")
	func matchesToolResults() throws {
		let path = try write([userLine, toolCallLine, toolResultLine])
		defer { try? FileManager.default.removeItem(atPath: path) }

		let items = SessionStore.conversation(at: path)
		guard case .tool(let activity) = items[1] else {
			Issue.record("expected a tool row")
			return
		}
		#expect(activity.id == "call_1")
		#expect(activity.name == "read")
		#expect(activity.status == .succeeded)
		#expect(activity.resultText == "conteúdo do arquivo")
		#expect(activity.summary == "Leu …/src/AuthService.swift")
	}

	@Test("a tool call with no recorded result reads as interrupted, not as running")
	func unmatchedToolCallIsNotLeftSpinning() throws {
		let path = try write([userLine, toolCallLine])
		defer { try? FileManager.default.removeItem(atPath: path) }

		guard case .tool(let activity) = SessionStore.conversation(at: path)[1] else {
			Issue.record("expected a tool row")
			return
		}
		// `.running` would render a spinner that never stops in restored history.
		#expect(activity.status == .failed)
		#expect(activity.resultText.contains("interrompida"))
	}

	@Test("an errored tool result is marked failed and carries no diff")
	func errorResult() throws {
		let errored = """
		{"type":"message","id":"4","message":{"role":"toolResult","toolCallId":"call_1",\
		"toolName":"read","isError":true,"content":[{"type":"text","text":"- a\\n+ b\\n- c"}]}}
		"""
		let path = try write([toolCallLine, errored])
		defer { try? FileManager.default.removeItem(atPath: path) }

		guard case .tool(let activity) = SessionStore.conversation(at: path)[0] else {
			Issue.record("expected a tool row")
			return
		}
		#expect(activity.status == .failed)
		#expect(activity.diff == nil)
	}

	@Test("non-message entries are ignored")
	func ignoresBookkeepingEntries() throws {
		let path = try write([
			#"{"type":"title","title":"t","updatedAt":0,"v":1}"#,
			#"{"type":"session","cwd":"/x","id":"s","timestamp":"2026-08-04T00:00:00.000Z","version":3}"#,
			#"{"type":"model_change","id":"m","model":{"id":"x"}}"#,
			userLine,
		])
		defer { try? FileManager.default.removeItem(atPath: path) }

		let items = SessionStore.conversation(at: path)
		#expect(items.count == 1)
		guard case .user = items[0] else {
			Issue.record("expected only the user turn")
			return
		}
	}

	@Test("a malformed line does not abort the rest of the transcript")
	func survivesGarbage() throws {
		let path = try write([userLine, "isto não é json", assistantLine])
		defer { try? FileManager.default.removeItem(atPath: path) }
		#expect(SessionStore.conversation(at: path).count == 2)
	}

	@Test("only the tail is kept when the transcript is longer than the limit")
	func keepsTail() throws {
		var lines: [String] = []
		for index in 0..<20 {
			lines.append(#"{"type":"message","id":"\#(index)","message":{"role":"user","content":[{"type":"text","text":"m\#(index)"}]}}"#)
		}
		let path = try write(lines)
		defer { try? FileManager.default.removeItem(atPath: path) }

		let items = SessionStore.conversation(at: path, limit: 5)
		#expect(items.count == 5)
		guard case .user(let last) = items.last else {
			Issue.record("expected a user turn")
			return
		}
		#expect(last.text == "m19")
	}

	@Test("a missing file yields nothing rather than throwing")
	func missingFile() {
		#expect(SessionStore.conversation(at: "/tmp/rune-nao-existe-\(UUID().uuidString).jsonl").isEmpty)
	}
}

/// Parses whatever transcripts this machine actually has.
///
/// The synthetic fixtures above encode my reading of the format; this checks
/// that reading against files OMP really wrote. It skips itself when there are
/// none, so CI stays green on a clean runner.
@Suite(
	"Transcript format, against real OMP files",
	.enabled(if: !SessionStore.recentSessions(root: SessionStore.defaultRoot, limit: 5).isEmpty,
	         "no OMP transcripts on this machine")
)
struct RealTranscriptTests {
	private var sessions: [SessionSummary] {
		SessionStore.recentSessions(root: SessionStore.defaultRoot, limit: 5)
	}

	@Test("every recent transcript yields a header the picker can label")
	func headersParse() throws {
		for session in sessions {
			#expect(!session.sessionId.isEmpty)
			#expect(!session.title.isEmpty, "session \(session.path) produced no label")
		}
	}

	@Test("a transcript with messages rebuilds into renderable items")
	func conversationsRebuild() throws {
		// The largest recent transcript is the one most likely to exercise tool
		// calls, results, and multi-block assistant messages.
		let candidates = sessions.map { ($0, SessionStore.conversation(at: $0.path)) }
		guard let (session, items) = candidates.max(by: { $0.1.count < $1.1.count }), !items.isEmpty
		else { return }

		// No restored tool row may be left spinning — that would be a permanent
		// spinner in the history.
		for case .tool(let activity) in items {
			#expect(activity.status != .running, "tool \(activity.name) restored as running")
		}
		// Assistant turns must be closed, or the caret keeps blinking forever.
		for case .assistant(let turn) in items {
			#expect(!turn.isStreaming)
		}
		#expect(items.contains { if case .user = $0 { return true }; return false },
		        "\(session.path) rebuilt with no user turn")
	}
}
