import Foundation

/// Recovers a unified diff from a tool result's text.
///
/// OMP does not put a structured patch in `details`, so shape detection is the
/// portable option: require hunk headers or a meaningful density of +/- lines
/// before treating text as a diff, otherwise ordinary output containing a stray
/// `-` would render as a bogus patch.
public enum DiffParser {
	private static let minimumChangedLines = 2

	public static func parse(
		_ text: String,
		maxLines: Int = AppConfiguration.maxRenderedDiffLines
	) -> DiffSummary? {
		let rawLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		guard rawLines.count >= 2 else { return nil }

		var added = 0
		var removed = 0
		var hunks = 0
		for line in rawLines {
			if line.hasPrefix("@@") { hunks += 1 }
			else if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
			else if line.hasPrefix("+") { added += 1 }
			else if line.hasPrefix("-") { removed += 1 }
		}

		let changed = added + removed
		guard changed >= minimumChangedLines else { return nil }
		// Without hunk headers, demand that changes dominate the text so a code
		// block or a bulleted list is not mistaken for a patch.
		if hunks == 0 {
			guard Double(changed) / Double(rawLines.count) >= 0.4 else { return nil }
		}

		let kept = rawLines.prefix(maxLines)
		let lines = kept.enumerated().map { index, raw in
			DiffSummary.Line(id: index, kind: kind(of: raw), text: raw)
		}

		return DiffSummary(
			lines: lines,
			addedCount: added,
			removedCount: removed,
			truncatedLineCount: max(0, rawLines.count - kept.count)
		)
	}

	private static func kind(of line: String) -> DiffSummary.Line.Kind {
		if line.hasPrefix("@@") { return .hunk }
		if line.hasPrefix("+++") || line.hasPrefix("---") { return .hunk }
		if line.hasPrefix("+") { return .added }
		if line.hasPrefix("-") { return .removed }
		return .context
	}
}

/// Flattens an `AgentToolResult` content array into displayable text.
public enum ToolResultFormatter {
	public static func text(
		from result: JSONValue,
		limit: Int = AppConfiguration.maxRenderedToolResultCharacters
	) -> String {
		var pieces: [String] = []
		if let blocks = result["content"]?.arrayValue {
			for block in blocks {
				switch block["type"]?.stringValue {
				case "text":
					if let text = block["text"]?.stringValue { pieces.append(text) }
				case "image":
					pieces.append("[imagem]")
				default:
					break
				}
			}
		}
		if pieces.isEmpty, case .string(let text) = result { pieces.append(text) }

		let joined = pieces.joined(separator: "\n")
		guard joined.count > limit else { return joined }
		let omitted = joined.count - limit
		return String(joined.prefix(limit)) + "\n… (\(omitted) caracteres omitidos)"
	}
}
