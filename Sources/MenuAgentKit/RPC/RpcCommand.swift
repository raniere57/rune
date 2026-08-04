import Foundation

/// `ImageContent` as consumed by `prompt`/`steer`/`follow_up`.
/// Shape confirmed in `packages/wire/src/index.ts`:
/// `{ type: "image", data: <base64>, mimeType: "image/png" }`.
public struct RpcImage: Sendable, Equatable {
	public let mimeType: String
	public let base64Data: String

	public init(mimeType: String, base64Data: String) {
		self.mimeType = mimeType
		self.base64Data = base64Data
	}

	var json: JSONValue {
		.object(["type": .string("image"), "mimeType": .string(mimeType), "data": .string(base64Data)])
	}
}

/// How a prompt sent while the agent is already streaming should be queued.
/// `AgentSession.prompt()` rejects an omitted behaviour during streaming.
public enum StreamingBehavior: String, Sendable {
	case steer
	case followUp
}

/// Every command this host issues. Deliberately a subset of `RpcCommand` —
/// host tools, host URI schemes, and session branching are not part of the MVP,
/// and modelling unused commands would be dead surface.
public enum RpcCommand: Sendable {
	case negotiateProtocol(version: Int)
	case getState
	case getAvailableModels
	case setModel(provider: String, modelId: String)
	case setThinkingLevel(level: String)
	case prompt(message: String, images: [RpcImage], streamingBehavior: StreamingBehavior?)
	case steer(message: String, images: [RpcImage])
	case followUp(message: String, images: [RpcImage])
	case abort
	case newSession
	case switchSession(path: String)
	case getMessagesPage(cursor: String?, limit: Int?)
	case getSessionStats
	case setSubagentSubscription(level: String)
	case extensionUIResponse(requestId: String, answer: ExtensionUIAnswer)

	/// The `type` field, also used as the `command` echoed on responses.
	/// `extension_ui_response` is not a command and never correlates.
	public var commandType: String {
		switch self {
		case .negotiateProtocol: return "negotiate_protocol"
		case .getState: return "get_state"
		case .getAvailableModels: return "get_available_models"
		case .setModel: return "set_model"
		case .setThinkingLevel: return "set_thinking_level"
		case .prompt: return "prompt"
		case .steer: return "steer"
		case .followUp: return "follow_up"
		case .abort: return "abort"
		case .newSession: return "new_session"
		case .switchSession: return "switch_session"
		case .getMessagesPage: return "get_messages_page"
		case .getSessionStats: return "get_session_stats"
		case .setSubagentSubscription: return "set_subagent_subscription"
		case .extensionUIResponse: return "extension_ui_response"
		}
	}

	public var expectsResponse: Bool {
		if case .extensionUIResponse = self { return false }
		return true
	}

	func json(id: String?) -> JSONValue {
		var fields: [String: JSONValue] = ["type": .string(commandType)]
		if let id, expectsResponse { fields["id"] = .string(id) }

		switch self {
		case .negotiateProtocol(let version):
			fields["protocolVersion"] = .number(Double(version))

		case .getState, .getAvailableModels, .abort, .newSession, .getSessionStats:
			break

		case .setModel(let provider, let modelId):
			fields["provider"] = .string(provider)
			fields["modelId"] = .string(modelId)

		case .setThinkingLevel(let level):
			fields["level"] = .string(level)

		case .prompt(let message, let images, let behavior):
			fields["message"] = .string(message)
			if !images.isEmpty { fields["images"] = .array(images.map(\.json)) }
			if let behavior { fields["streamingBehavior"] = .string(behavior.rawValue) }

		case .steer(let message, let images), .followUp(let message, let images):
			fields["message"] = .string(message)
			if !images.isEmpty { fields["images"] = .array(images.map(\.json)) }

		case .switchSession(let path):
			fields["sessionPath"] = .string(path)

		case .getMessagesPage(let cursor, let limit):
			if let cursor { fields["cursor"] = .string(cursor) }
			if let limit { fields["limit"] = .number(Double(limit)) }

		case .setSubagentSubscription(let level):
			fields["level"] = .string(level)

		case .extensionUIResponse(let requestId, let answer):
			fields["id"] = .string(requestId)
			answer.apply(to: &fields)
		}

		return .object(fields)
	}

	/// One JSONL line, newline included.
	public func encoded(id: String?) throws -> Data {
		var data = try JSONEncoder.jsonl.encode(json(id: id))
		data.append(0x0A)
		return data
	}
}

/// `RpcExtensionUIResponse` variants.
public enum ExtensionUIAnswer: Sendable, Equatable {
	case value(String)
	case confirmed(Bool)
	case cancelled(timedOut: Bool)

	func apply(to fields: inout [String: JSONValue]) {
		switch self {
		case .value(let text):
			fields["value"] = .string(text)
		case .confirmed(let flag):
			fields["confirmed"] = .bool(flag)
		case .cancelled(let timedOut):
			fields["cancelled"] = .bool(true)
			if timedOut { fields["timedOut"] = .bool(true) }
		}
	}
}
