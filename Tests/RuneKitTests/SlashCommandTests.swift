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
