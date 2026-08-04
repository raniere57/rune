import Foundation

// MARK: - Turns

public struct UserTurn: Identifiable, Sendable, Equatable {
	public let id: String
	public var text: String
	public var attachments: [AttachmentSummary]

	public init(id: String = UUID().uuidString, text: String, attachments: [AttachmentSummary] = []) {
		self.id = id
		self.text = text
		self.attachments = attachments
	}
}

public struct AttachmentSummary: Identifiable, Sendable, Equatable {
	public enum Kind: String, Sendable {
		case image, file, folder
	}

	public let id: String
	public let kind: Kind
	public let label: String

	public init(id: String = UUID().uuidString, kind: Kind, label: String) {
		self.id = id
		self.kind = kind
		self.label = label
	}
}

public struct AssistantTurn: Identifiable, Sendable, Equatable {
	public let id: String
	public var text: String
	public var isStreaming: Bool

	public init(id: String = UUID().uuidString, text: String = "", isStreaming: Bool = true) {
		self.id = id
		self.text = text
		self.isStreaming = isStreaming
	}
}

// MARK: - Tool activity

public struct ToolActivity: Identifiable, Sendable, Equatable {
	public enum Status: Sendable, Equatable {
		case running
		case succeeded
		case failed
	}

	/// `toolCallId` — stable across start/update/end for the same call.
	public let id: String
	public let name: String
	public let arguments: JSONValue
	public var status: Status
	public var resultText: String
	public var diff: DiffSummary?

	public init(
		id: String,
		name: String,
		arguments: JSONValue,
		status: Status = .running,
		resultText: String = "",
		diff: DiffSummary? = nil
	) {
		self.id = id
		self.name = name
		self.arguments = arguments
		self.status = status
		self.resultText = resultText
		self.diff = diff
	}

	/// Collapsed one-liner, e.g. `Leu src/main.swift` or `Executou pnpm test`.
	public var summary: String { ToolSummaryFormatter.summary(name: name, arguments: arguments) }
}

/// A unified diff extracted from a tool result.
///
/// OMP's `write`/`edit` results carry no structured patch — `details` only has
/// `resolvedPath`, diagnostics, and metadata — so the diff is recovered from
/// the textual result. Detecting the shape rather than parsing a specific
/// format keeps this working across OMP releases.
public struct DiffSummary: Sendable, Equatable {
	public struct Line: Identifiable, Sendable, Equatable {
		public enum Kind: Sendable { case added, removed, context, hunk }
		public let id: Int
		public let kind: Kind
		public let text: String
	}

	public let lines: [Line]
	public let addedCount: Int
	public let removedCount: Int
	/// Lines beyond `AppConfiguration.maxRenderedDiffLines`, dropped so a huge
	/// patch cannot stall the panel.
	public let truncatedLineCount: Int

	public var isTruncated: Bool { truncatedLineCount > 0 }

	public var statLine: String {
		"+\(addedCount) −\(removedCount)"
	}
}

// MARK: - Other entries

public struct NoticeEntry: Identifiable, Sendable, Equatable {
	public enum Level: String, Sendable { case info, warning, error }
	public let id: String
	public let level: Level
	public let text: String

	public init(id: String = UUID().uuidString, level: Level, text: String) {
		self.id = id
		self.level = level
		self.text = text
	}
}

/// Text a local OMP slash command printed — `/session`, `/context`, `/usage`,
/// `/tools` and friends answer with `command_output` frames rather than an
/// agent turn.
public struct CommandOutputEntry: Identifiable, Sendable, Equatable {
	public let id: String
	public let text: String

	public init(id: String = UUID().uuidString, text: String) {
		self.id = id
		self.text = text
	}
}

public struct FailureEntry: Identifiable, Sendable, Equatable {
	public let id: String
	public let text: String
	public let detail: String?

	public init(id: String = UUID().uuidString, text: String, detail: String? = nil) {
		self.id = id
		self.text = text
		self.detail = detail
	}
}

/// An `extension_ui_request` awaiting a host answer, rendered inline.
public struct PendingRequest: Identifiable, Sendable, Equatable {
	public let id: String
	public let request: ExtensionUIRequest
	public var answered: Bool

	public init(request: ExtensionUIRequest, answered: Bool = false) {
		self.id = request.id
		self.request = request
		self.answered = answered
	}
}

// MARK: - Union

public enum ConversationItem: Identifiable, Sendable, Equatable {
	case user(UserTurn)
	case assistant(AssistantTurn)
	case tool(ToolActivity)
	case notice(NoticeEntry)
	case output(CommandOutputEntry)
	case failure(FailureEntry)
	case request(PendingRequest)

	public var id: String {
		switch self {
		case .user(let value): return "user:\(value.id)"
		case .assistant(let value): return "assistant:\(value.id)"
		case .tool(let value): return "tool:\(value.id)"
		case .notice(let value): return "notice:\(value.id)"
		case .output(let value): return "output:\(value.id)"
		case .failure(let value): return "failure:\(value.id)"
		case .request(let value): return "request:\(value.id)"
		}
	}

	/// Plain-text rendering used by "copy last answer".
	public var copyableText: String? {
		switch self {
		case .assistant(let turn): return turn.text
		case .user(let turn): return turn.text
		case .failure(let entry): return entry.text
		case .notice(let entry): return entry.text
		case .output(let entry): return entry.text
		case .tool, .request: return nil
		}
	}
}
