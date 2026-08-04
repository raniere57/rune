import Foundation

/// One entry in the `/` suggestion list.
public struct SlashCommand: Identifiable, Sendable, Equatable, Codable {
	public enum Source: String, Sendable, Codable {
		/// Handled by the app itself, never forwarded.
		case local
		/// Handled by OMP; the app forwards the line verbatim.
		case omp
	}

	public let name: String
	public let summary: String
	public let source: Source
	/// Shown after the name when the command takes an argument.
	public let hint: String?

	public var id: String { name }

	public init(name: String, summary: String, source: Source, hint: String? = nil) {
		self.name = name
		self.summary = summary
		self.source = source
		self.hint = hint
	}

	/// What gets inserted when the suggestion is accepted. Commands that take
	/// an argument keep the trailing space so typing continues naturally.
	public var completion: String {
		hint == nil ? "/\(name) " : "/\(name) "
	}

	/// The five the app owns. Kept here rather than derived from
	/// `AgentCoordinator.LocalCommand` so the summaries can be written for a
	/// reader instead of a parser.
	public static let local: [SlashCommand] = [
		SlashCommand(
			name: "key",
			summary: "Grava a chave do OpenCode Zen no Keychain",
			source: .local,
			hint: "sk-…"
		),
		SlashCommand(
			name: "cd",
			summary: "Troca o workspace (reinicia o omp)",
			source: .local,
			hint: "caminho"
		),
		SlashCommand(name: "new", summary: "Nova sessão", source: .local),
		SlashCommand(name: "abort", summary: "Aborta a execução atual", source: .local),
		SlashCommand(
			name: "status",
			summary: "Estado, modelo, effort, chave, contexto e sessão",
			source: .local
		),
	]

	/// Ranks by how early and how tightly the query matches.
	///
	/// A prefix match must win over a mid-string one, otherwise typing `/co`
	/// buries `/compact` under `/code-review`'s description.
	static func matches(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
		let needle = query.lowercased()
		guard !needle.isEmpty else {
			// Local commands first: they are the ones with no other discovery path.
			return commands.sorted { lhs, rhs in
				lhs.source == rhs.source ? lhs.name < rhs.name : lhs.source == .local
			}
		}

		return commands
			.compactMap { command -> (SlashCommand, Int)? in
				let name = command.name.lowercased()
				if name == needle { return (command, 0) }
				if name.hasPrefix(needle) { return (command, 1) }
				if name.contains(needle) { return (command, 2) }
				if command.summary.lowercased().contains(needle) { return (command, 3) }
				return nil
			}
			.sorted { lhs, rhs in
				if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
				if lhs.0.source != rhs.0.source { return lhs.0.source == .local }
				return lhs.0.name.count < rhs.0.name.count
			}
			.map(\.0)
	}
}
