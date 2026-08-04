import Foundation

/// Splits assistant text into prose and fenced code, so each half can be
/// rendered by the right view.
///
/// SwiftUI's `AttributedString(markdown:)` handles inline emphasis, code spans,
/// and links well but flattens fenced blocks and mangles their whitespace.
/// Fences are therefore peeled off first and rendered verbatim in a monospaced
/// view — no WebView involved.
public enum MarkdownBlock: Identifiable, Sendable, Equatable {
	case prose(id: Int, text: String)
	case code(id: Int, language: String?, text: String)

	public var id: Int {
		switch self {
		case .prose(let id, _), .code(let id, _, _): return id
		}
	}

	public static func parse(_ text: String) -> [MarkdownBlock] {
		guard text.contains("```") else {
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? [] : [.prose(id: 0, text: trimmed)]
		}

		var blocks: [MarkdownBlock] = []
		var buffer: [String] = []
		var codeBuffer: [String] = []
		var language: String?
		var insideFence = false
		var nextId = 0

		func flushProse() {
			let joined = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
			buffer.removeAll()
			guard !joined.isEmpty else { return }
			blocks.append(.prose(id: nextId, text: joined))
			nextId += 1
		}

		for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
			if line.hasPrefix("```") {
				if insideFence {
					blocks.append(.code(id: nextId, language: language, text: codeBuffer.joined(separator: "\n")))
					nextId += 1
					codeBuffer.removeAll()
					language = nil
					insideFence = false
				} else {
					flushProse()
					let tag = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
					language = tag.isEmpty ? nil : tag
					insideFence = true
				}
				continue
			}
			if insideFence { codeBuffer.append(line) } else { buffer.append(line) }
		}

		// An unterminated fence happens constantly mid-stream; render what has
		// arrived instead of waiting for the closing marker.
		if insideFence, !codeBuffer.isEmpty {
			blocks.append(.code(id: nextId, language: language, text: codeBuffer.joined(separator: "\n")))
		} else {
			flushProse()
		}

		return blocks
	}
}

extension AttributedString {
	/// Inline markdown only — block structure is already handled by
	/// `MarkdownBlock`, and full parsing would drop the newlines that separate
	/// paragraphs and list items.
	static func inlineMarkdown(_ text: String) -> AttributedString {
		let options = AttributedString.MarkdownParsingOptions(
			interpretedSyntax: .inlineOnlyPreservingWhitespace
		)
		return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
	}
}
