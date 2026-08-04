import Foundation

// MARK: - Ready

/// `{ type: "ready", protocolVersion, supportedProtocolVersions, maxFrameBytes, maxReassembledFrameBytes }`
public struct RpcReady: Sendable, Equatable {
	public let protocolVersion: Int
	public let supportedProtocolVersions: [Int]
	public let maxFrameBytes: Int
	public let maxReassembledFrameBytes: Int

	public var supportsV2: Bool { supportedProtocolVersions.contains(2) }

	init?(json: JSONValue) {
		guard let protocolVersion = json["protocolVersion"]?.intValue else { return nil }
		self.protocolVersion = protocolVersion
		self.supportedProtocolVersions = json["supportedProtocolVersions"]?.arrayValue?
			.compactMap(\.intValue) ?? [protocolVersion]
		// Defaults mirror the v17.2.6 ready frame; a runtime that omits them is
		// treated as advertising the documented ceilings rather than zero.
		self.maxFrameBytes = json["maxFrameBytes"]?.intValue ?? 1_048_576
		self.maxReassembledFrameBytes = json["maxReassembledFrameBytes"]?.intValue ?? 67_108_864
	}
}

// MARK: - Response

/// `{ id?, type: "response", command, success, data? | error, code? }`
public struct RpcResponse: Sendable, Equatable {
	public let id: String?
	public let command: String
	public let success: Bool
	public let data: JSONValue?
	public let error: String?
	public let code: String?

	init?(json: JSONValue) {
		guard let command = json["command"]?.stringValue,
		      let success = json["success"]?.boolValue
		else { return nil }
		self.id = json["id"]?.stringValue
		self.command = command
		self.success = success
		self.data = json["data"]
		self.error = json["error"]?.stringValue
		self.code = json["code"]?.stringValue
	}
}

// MARK: - Assistant streaming deltas

/// Subset of `AssistantMessageEvent` the GUI reacts to.
/// Thinking deltas are recognised but never carry their text: internal
/// reasoning is deliberately not surfaced.
public enum AssistantDelta: Sendable, Equatable {
	case start
	case textDelta(String)
	case textEnd(String)
	case thinkingStarted
	case thinkingEnded
	case toolCallStarted
	case toolCallEnd(id: String, name: String, arguments: JSONValue)
	case done(reason: String)
	case failed(reason: String)
	case other(String)

	init(json: JSONValue) {
		switch json["type"]?.stringValue {
		case "start": self = .start
		case "text_delta": self = .textDelta(json["delta"]?.stringValue ?? "")
		case "text_end": self = .textEnd(json["content"]?.stringValue ?? "")
		case "thinking_start", "thinking_delta": self = .thinkingStarted
		case "thinking_end": self = .thinkingEnded
		case "toolcall_start", "toolcall_delta": self = .toolCallStarted
		case "toolcall_end":
			let call = json["toolCall"]
			self = .toolCallEnd(
				id: call?["id"]?.stringValue ?? "",
				name: call?["name"]?.stringValue ?? "tool",
				arguments: call?["arguments"] ?? .object([:])
			)
		case "done": self = .done(reason: json["reason"]?.stringValue ?? "stop")
		case "error": self = .failed(reason: json["reason"]?.stringValue ?? "error")
		case let other: self = .other(other ?? "unknown")
		}
	}
}

// MARK: - Agent session events

/// `AgentSessionEvent` variants the GUI renders. Anything else is preserved as
/// `.other` so a newer OMP never silently drops information.
public enum AgentEventFrame: Sendable {
	case agentStart
	case agentEnd(isTerminal: Bool, raw: JSONValue)
	case turnStart
	case turnEnd
	case messageStart(role: String, raw: JSONValue)
	case messageUpdate(AssistantDelta)
	case messageEnd(role: String, raw: JSONValue)
	case toolExecutionStart(toolCallId: String, toolName: String, arguments: JSONValue)
	case toolExecutionUpdate(toolCallId: String, toolName: String)
	case toolExecutionEnd(toolCallId: String, toolName: String, result: JSONValue, isError: Bool)
	case compactionStart(reason: String, action: String)
	case compactionEnd(aborted: Bool, willRetry: Bool, errorMessage: String?)
	case retryStart(attempt: Int, maxAttempts: Int, errorMessage: String)
	case retryEnd(success: Bool, finalError: String?)
	case modelChanged
	case notice(level: String, message: String, source: String?)
	case other(type: String, raw: JSONValue)

	// swiftlint:disable:next cyclomatic_complexity
	init?(type: String, json: JSONValue) {
		switch type {
		case "agent_start":
			self = .agentStart
		case "agent_end":
			// `isTerminal` is optional; absent means terminal (older runtimes).
			self = .agentEnd(isTerminal: json["isTerminal"]?.boolValue ?? true, raw: json)
		case "turn_start":
			self = .turnStart
		case "turn_end":
			self = .turnEnd
		case "message_start":
			self = .messageStart(role: json["message"]?["role"]?.stringValue ?? "", raw: json)
		case "message_update":
			self = .messageUpdate(AssistantDelta(json: json["assistantMessageEvent"] ?? .null))
		case "message_end":
			self = .messageEnd(role: json["message"]?["role"]?.stringValue ?? "", raw: json)
		case "tool_execution_start":
			self = .toolExecutionStart(
				toolCallId: json["toolCallId"]?.stringValue ?? "",
				toolName: json["toolName"]?.stringValue ?? "tool",
				arguments: json["args"] ?? .object([:])
			)
		case "tool_execution_update":
			self = .toolExecutionUpdate(
				toolCallId: json["toolCallId"]?.stringValue ?? "",
				toolName: json["toolName"]?.stringValue ?? "tool"
			)
		case "tool_execution_end":
			self = .toolExecutionEnd(
				toolCallId: json["toolCallId"]?.stringValue ?? "",
				toolName: json["toolName"]?.stringValue ?? "tool",
				result: json["result"] ?? .null,
				isError: json["isError"]?.boolValue ?? false
			)
		case "auto_compaction_start":
			self = .compactionStart(
				reason: json["reason"]?.stringValue ?? "",
				action: json["action"]?.stringValue ?? ""
			)
		case "auto_compaction_end":
			self = .compactionEnd(
				aborted: json["aborted"]?.boolValue ?? false,
				willRetry: json["willRetry"]?.boolValue ?? false,
				errorMessage: json["errorMessage"]?.stringValue
			)
		case "auto_retry_start":
			self = .retryStart(
				attempt: json["attempt"]?.intValue ?? 0,
				maxAttempts: json["maxAttempts"]?.intValue ?? 0,
				errorMessage: json["errorMessage"]?.stringValue ?? ""
			)
		case "auto_retry_end":
			self = .retryEnd(
				success: json["success"]?.boolValue ?? false,
				finalError: json["finalError"]?.stringValue
			)
		case "model_changed":
			self = .modelChanged
		case "notice":
			self = .notice(
				level: json["level"]?.stringValue ?? "info",
				message: json["message"]?.stringValue ?? "",
				source: json["source"]?.stringValue
			)
		case "turn_abort", "thinking_level_changed", "todo_reminder", "todo_auto_clear",
		     "retry_fallback_applied", "retry_fallback_succeeded", "ttsr_triggered",
		     "irc_message", "goal_updated", "session_info_update", "config_update":
			self = .other(type: type, raw: json)
		default:
			return nil
		}
	}
}

// MARK: - Extension UI

/// `extension_ui_request` frames. In `rpc-ui` mode tool approvals arrive here
/// as `select` with `["Approve", "Deny"]` — see
/// `packages/coding-agent/src/extensibility/extensions/wrapper.ts`.
public struct ExtensionUIRequest: Sendable, Equatable, Identifiable {
	public enum Method: Sendable, Equatable {
		case select(title: String, options: [String])
		case confirm(title: String, message: String)
		case input(title: String, placeholder: String?)
		case editor(title: String, prefill: String?)
		case cancel(targetId: String)
		case notify(message: String, level: String)
		case setStatus(key: String, text: String?)
		case setWidget(key: String, lines: [String]?)
		case setTitle(String)
		case setEditorText(String)
		case openURL(url: String, launchURL: String?, instructions: String?)
		case unsupported(String)
	}

	public let id: String
	public let method: Method
	public let timeout: TimeInterval?

	/// True when the host must answer with an `extension_ui_response` frame.
	/// Notifications and status/widget updates are fire-and-forget.
	public var expectsResponse: Bool {
		switch method {
		case .select, .confirm, .input, .editor: return true
		case .cancel, .notify, .setStatus, .setWidget, .setTitle, .setEditorText, .openURL, .unsupported:
			return false
		}
	}

	/// Approval prompts are the only `select` OMP raises in this host, since we
	/// register no extensions of our own.
	public var isApprovalPrompt: Bool {
		guard case .select(_, let options) = method else { return false }
		return options == ["Approve", "Deny"]
	}

	init?(json: JSONValue) {
		guard let id = json["id"]?.stringValue,
		      let methodName = json["method"]?.stringValue
		else { return nil }
		self.id = id
		self.timeout = json["timeout"]?.doubleValue.map { $0 / 1000 }

		switch methodName {
		case "select":
			self.method = .select(
				title: json["title"]?.stringValue ?? "",
				options: json["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
			)
		case "confirm":
			self.method = .confirm(
				title: json["title"]?.stringValue ?? "",
				message: json["message"]?.stringValue ?? ""
			)
		case "input":
			self.method = .input(
				title: json["title"]?.stringValue ?? "",
				placeholder: json["placeholder"]?.stringValue
			)
		case "editor":
			self.method = .editor(
				title: json["title"]?.stringValue ?? "",
				prefill: json["prefill"]?.stringValue
			)
		case "cancel":
			self.method = .cancel(targetId: json["targetId"]?.stringValue ?? "")
		case "notify":
			self.method = .notify(
				message: json["message"]?.stringValue ?? "",
				level: json["notifyType"]?.stringValue ?? "info"
			)
		case "setStatus":
			self.method = .setStatus(
				key: json["statusKey"]?.stringValue ?? "",
				text: json["statusText"]?.stringValue
			)
		case "setWidget":
			self.method = .setWidget(
				key: json["widgetKey"]?.stringValue ?? "",
				lines: json["widgetLines"]?.arrayValue?.compactMap(\.stringValue)
			)
		case "setTitle":
			self.method = .setTitle(json["title"]?.stringValue ?? "")
		case "set_editor_text":
			self.method = .setEditorText(json["text"]?.stringValue ?? "")
		case "open_url":
			self.method = .openURL(
				url: json["url"]?.stringValue ?? "",
				launchURL: json["launchUrl"]?.stringValue,
				instructions: json["instructions"]?.stringValue
			)
		default:
			self.method = .unsupported(methodName)
		}
	}
}

// MARK: - Slash commands

public struct RpcSlashCommand: Sendable, Equatable {
	public let name: String
	public let description: String?

	init?(json: JSONValue) {
		guard let name = json["name"]?.stringValue else { return nil }
		self.name = name
		self.description = json["description"]?.stringValue
	}
}

// MARK: - Frame union

/// One logical inbound frame, already reassembled from any `rpc_chunk` sequence.
public enum RpcFrame: Sendable {
	case ready(RpcReady)
	case response(RpcResponse)
	case agentEvent(AgentEventFrame)
	case extensionUIRequest(ExtensionUIRequest)
	case promptResult(id: String?, agentInvoked: Bool)
	case availableCommands([RpcSlashCommand])
	case commandOutput(JSONValue)
	case extensionError(extensionPath: String, event: String, message: String)
	case subagent(kind: String, payload: JSONValue)
	case unknown(type: String, raw: JSONValue)

	/// Parses one already-complete JSON object. Chunk frames are handled by
	/// `RpcFrameReader` before reaching here.
	public static func make(from json: JSONValue) -> RpcFrame {
		let type = json["type"]?.stringValue ?? "unknown"
		switch type {
		case "ready":
			if let ready = RpcReady(json: json) { return .ready(ready) }
		case "response":
			if let response = RpcResponse(json: json) { return .response(response) }
		case "extension_ui_request":
			if let request = ExtensionUIRequest(json: json) { return .extensionUIRequest(request) }
		case "prompt_result":
			return .promptResult(
				id: json["id"]?.stringValue,
				agentInvoked: json["agentInvoked"]?.boolValue ?? false
			)
		case "available_commands_update":
			let commands = json["commands"]?.arrayValue?.compactMap(RpcSlashCommand.init(json:)) ?? []
			return .availableCommands(commands)
		case "command_output":
			return .commandOutput(json)
		case "extension_error":
			return .extensionError(
				extensionPath: json["extensionPath"]?.stringValue ?? "",
				event: json["event"]?.stringValue ?? "",
				message: json["error"]?.stringValue ?? ""
			)
		case "subagent_lifecycle", "subagent_progress", "subagent_event":
			return .subagent(kind: type, payload: json["payload"] ?? .null)
		default:
			break
		}

		if let event = AgentEventFrame(type: type, json: json) { return .agentEvent(event) }
		return .unknown(type: type, raw: json)
	}
}
