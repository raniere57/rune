import Foundation

/// One resumable OMP session, as summarised from its transcript file.
public struct SessionSummary: Identifiable, Sendable, Equatable {
	public let path: String
	public let sessionId: String
	public let cwd: String
	public let startedAt: Date
	public let modifiedAt: Date
	/// OMP's own title when it set one, otherwise the first user message.
	public let title: String

	public var id: String { path }

	public var workspaceName: String {
		URL(fileURLWithPath: cwd).lastPathComponent
	}

	/// Short, human relative age — "agora", "12 min", "3 h", "5 d".
	public func age(relativeTo now: Date = Date()) -> String {
		let seconds = now.timeIntervalSince(modifiedAt)
		switch seconds {
		case ..<60: return "agora"
		case ..<3600: return "\(Int(seconds / 60)) min"
		case ..<86400: return "\(Int(seconds / 3600)) h"
		default: return "\(Int(seconds / 86400)) d"
		}
	}
}

/// Reads OMP's on-disk session transcripts.
///
/// The app keeps no session database of its own — OMP already owns session
/// storage, so duplicating it would just be a second source of truth to drift.
/// This only reads the header of each transcript to build a picker.
public enum SessionStore {
	/// Default layout: `~/.omp/agent/sessions/<workspace-slug>/<stamp>_<uuid>.jsonl`.
	/// `--profile` moves this, so callers pass the directory derived from the
	/// live session file when they have one.
	public static var defaultRoot: URL {
		FileManager.default.homeDirectoryForCurrentUser
			.appendingPathComponent(".omp/agent/sessions")
	}

	/// Infers the sessions root from a known transcript path
	/// (`<root>/<slug>/<file>.jsonl`), so a custom `--profile` still resolves.
	public static func root(forSessionFile path: String?) -> URL {
		guard let path, !path.isEmpty else { return defaultRoot }
		let url = URL(fileURLWithPath: path)
		let inferred = url.deletingLastPathComponent().deletingLastPathComponent()
		return FileManager.default.fileExists(atPath: inferred.path) ? inferred : defaultRoot
	}

	/// Blocking file I/O — call from a background task, never the main actor.
	///
	/// `limit` caps how many transcripts are opened, since only the most recent
	/// ones are ever shown and a long-lived install accumulates hundreds.
	public static func recentSessions(
		root: URL,
		limit: Int = 40,
		fileManager: FileManager = .default
	) -> [SessionSummary] {
		guard let directories = try? fileManager.contentsOfDirectory(
			at: root,
			includingPropertiesForKeys: [.isDirectoryKey],
			options: [.skipsHiddenFiles]
		) else { return [] }

		var candidates: [(URL, Date)] = []
		for directory in directories {
			guard let files = try? fileManager.contentsOfDirectory(
				at: directory,
				includingPropertiesForKeys: [.contentModificationDateKey],
				options: [.skipsHiddenFiles]
			) else { continue }
			for file in files where file.pathExtension == "jsonl" {
				let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
					.contentModificationDate ?? .distantPast
				candidates.append((file, modified))
			}
		}

		return candidates
			.sorted { $0.1 > $1.1 }
			.prefix(limit)
			.compactMap { summary(of: $0.0, modifiedAt: $0.1) }
	}

	/// Parses the transcript header. The first two lines carry `title` and
	/// `session` (`cwd`, `id`, `timestamp`); the first user message is only read
	/// as a fallback label when OMP never titled the session.
	static func summary(of file: URL, modifiedAt: Date) -> SessionSummary? {
		guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
		defer { try? handle.close() }
		// 128 KiB is far past the header and bounds the read on a huge transcript.
		guard let chunk = try? handle.read(upToCount: 128 * 1024),
		      let text = String(data: chunk, encoding: .utf8)
		else { return nil }

		var title = ""
		var sessionId = ""
		var cwd = ""
		var startedAt = modifiedAt
		var firstUserMessage = ""

		for line in text.split(separator: "\n") {
			guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { continue }
			switch value["type"]?.stringValue {
			case "title":
				title = value["title"]?.stringValue ?? ""
			case "session":
				sessionId = value["id"]?.stringValue ?? ""
				cwd = value["cwd"]?.stringValue ?? ""
				if let stamp = value["timestamp"]?.stringValue,
				   let parsed = ISO8601DateFormatter.withFractionalSeconds.date(from: stamp) {
					startedAt = parsed
				}
			default:
				if firstUserMessage.isEmpty { firstUserMessage = userText(in: value) }
			}
			if !title.isEmpty, !sessionId.isEmpty, !firstUserMessage.isEmpty { break }
		}

		guard !sessionId.isEmpty else { return nil }
		let label = title.isEmpty ? firstUserMessage : title
		return SessionSummary(
			path: file.path,
			sessionId: sessionId,
			cwd: cwd,
			startedAt: startedAt,
			modifiedAt: modifiedAt,
			title: label.isEmpty ? "Sem título" : condensed(label)
		)
	}

	/// Pulls user-authored text out of a transcript entry, whatever wrapper the
	/// entry uses.
	private static func userText(in value: JSONValue) -> String {
		let message = value["message"] ?? value
		guard message["role"]?.stringValue == "user" else { return "" }
		if let text = message["content"]?.stringValue { return text }
		guard let blocks = message["content"]?.arrayValue else { return "" }
		return blocks
			.filter { $0["type"]?.stringValue == "text" }
			.compactMap { $0["text"]?.stringValue }
			.joined(separator: " ")
	}

	private static func condensed(_ text: String) -> String {
		let flattened = text
			.replacingOccurrences(of: "\n", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return flattened.count > 70 ? String(flattened.prefix(70)) + "…" : flattened
	}
}

extension ISO8601DateFormatter {
	/// `ISO8601DateFormatter` is not `Sendable`, and parsing happens on whatever
	/// background task reads the transcripts, so each call gets its own.
	static var withFractionalSeconds: ISO8601DateFormatter {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}
}

// MARK: - Rebuilding a conversation from disk

extension SessionStore {
	/// Largest tail of a transcript that is parsed. A long session can reach
	/// megabytes, and only the recent part is worth rendering.
	static let maxTranscriptBytes = 4 * 1024 * 1024

	/// Rebuilds the rendered conversation straight from a transcript file.
	///
	/// This exists so reopening the panel shows the conversation immediately,
	/// without starting OMP. The RPC path (`get_messages_page`) only runs during
	/// a boot, which is triggered by the first prompt — so after an app restart
	/// the panel used to look empty until the user sent something, even though
	/// the session was right there on disk.
	///
	/// Blocking I/O — call from a background task.
	public static func conversation(at path: String, limit: Int = 300) -> [ConversationItem] {
		guard let text = tail(of: URL(fileURLWithPath: path)) else { return [] }

		var items: [ConversationItem] = []
		/// Index into `items` for each `toolCallId`, so a `toolResult` arriving
		/// later can complete the row it belongs to.
		var toolIndexById: [String: Int] = [:]

		for line in text.split(separator: "\n") {
			guard let entry = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
			      entry["type"]?.stringValue == "message",
			      let message = entry["message"]
			else { continue }

			switch message["role"]?.stringValue {
			case "user":
				let text = joinedText(in: message)
				guard !text.isEmpty else { continue }
				items.append(.user(UserTurn(text: text)))

			case "assistant":
				// `thinking` blocks are skipped everywhere, including here.
				let text = joinedText(in: message)
				if !text.isEmpty {
					items.append(.assistant(AssistantTurn(text: text, isStreaming: false)))
				}
				for block in message["content"]?.arrayValue ?? []
				where block["type"]?.stringValue == "toolCall" {
					let id = block["id"]?.stringValue ?? UUID().uuidString
					toolIndexById[id] = items.count
					items.append(.tool(ToolActivity(
						id: id,
						name: block["name"]?.stringValue ?? "tool",
						arguments: block["arguments"] ?? .object([:]),
						// Corrected below if a result is found; a call with no
						// recorded result means the turn was interrupted.
						status: .failed,
						resultText: "Sem resultado registrado — a execução foi interrompida."
					)))
				}

			case "toolResult":
				guard let id = message["toolCallId"]?.stringValue,
				      let index = toolIndexById[id],
				      case .tool(var activity) = items[index]
				else { continue }
				let result = joinedText(in: message)
				activity.status = message["isError"]?.boolValue == true ? .failed : .succeeded
				activity.resultText = String(result.prefix(AppConfiguration.maxRenderedToolResultCharacters))
				activity.diff = activity.status == .succeeded ? DiffParser.parse(result) : nil
				items[index] = .tool(activity)

			default:
				continue
			}
		}

		return items.count > limit ? Array(items.suffix(limit)) : items
	}

	/// Text blocks of a message, joined. Non-text blocks are ignored.
	private static func joinedText(in message: JSONValue) -> String {
		if let text = message["content"]?.stringValue { return text }
		return (message["content"]?.arrayValue ?? [])
			.filter { $0["type"]?.stringValue == "text" }
			.compactMap { $0["text"]?.stringValue }
			.joined(separator: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Reads at most the last `maxTranscriptBytes`, dropping the leading partial
	/// line so the caller never sees a half-parsed entry.
	private static func tail(of file: URL) -> String? {
		guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
		defer { try? handle.close() }

		let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
		let start = max(0, size - maxTranscriptBytes)
		try? handle.seek(toOffset: UInt64(start))
		guard let data = try? handle.readToEnd(),
		      let text = String(data: data, encoding: .utf8)
		else { return nil }

		guard start > 0, let newline = text.firstIndex(of: "\n") else { return text }
		return String(text[text.index(after: newline)...])
	}
}
