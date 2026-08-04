import Foundation

/// Turns a tool call into the one-line label shown in the collapsed row.
///
/// Raw JSON is never rendered directly; anything without a known shape falls
/// back to the bare tool name.
public enum ToolSummaryFormatter {
	public static func summary(name: String, arguments: JSONValue) -> String {
		switch name {
		case "read":
			return labelled("Leu", target(from: arguments, keys: ["path", "file_path", "url", "target"]))
		case "write":
			return labelled("Escreveu", target(from: arguments, keys: ["path", "file_path"]))
		case "edit", "ast-edit", "ast_edit":
			return labelled("Editou", target(from: arguments, keys: ["path", "file_path"]))
		case "bash", "bash-interactive":
			return labelled("Executou", firstLine(arguments["command"]?.stringValue))
		case "grep", "ast-grep", "ast_grep":
			return labelled("Pesquisou", quoted(arguments["pattern"]?.stringValue))
		case "glob":
			return labelled("Listou", arguments["pattern"]?.stringValue)
		case "list", "ls":
			return labelled("Listou", target(from: arguments, keys: ["path", "dir"]))
		case "fetch":
			return labelled("Buscou", arguments["url"]?.stringValue)
		case "task", "subagent":
			return labelled("Subagente", arguments["description"]?.stringValue ?? arguments["agent"]?.stringValue)
		case "todo":
			return "Atualizou o plano"
		case "compact":
			return "Compactou o contexto"
		default:
			if name.hasPrefix("mcp__") {
				return "MCP · " + name.dropFirst("mcp__".count).replacingOccurrences(of: "_", with: " ")
			}
			return name
		}
	}

	private static func labelled(_ verb: String, _ detail: String?) -> String {
		guard let detail, !detail.isEmpty else { return verb }
		return "\(verb) \(detail)"
	}

	private static func target(from arguments: JSONValue, keys: [String]) -> String? {
		for key in keys {
			if let value = arguments[key]?.stringValue, !value.isEmpty {
				return shortenPath(value)
			}
		}
		if let paths = arguments["paths"]?.arrayValue?.compactMap(\.stringValue), !paths.isEmpty {
			return paths.count == 1 ? shortenPath(paths[0]) : "\(paths.count) arquivos"
		}
		return nil
	}

	/// Keeps the last two path components so a long absolute path stays readable.
	static func shortenPath(_ path: String) -> String {
		guard path.contains("/"), !path.hasPrefix("http") else { return path }
		let components = path.split(separator: "/")
		guard components.count > 2 else { return path }
		return "…/" + components.suffix(2).joined(separator: "/")
	}

	private static func firstLine(_ text: String?) -> String? {
		guard let text else { return nil }
		let line = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
		return line.count > 60 ? String(line.prefix(60)) + "…" : line
	}

	private static func quoted(_ text: String?) -> String? {
		guard let text, !text.isEmpty else { return nil }
		return "“\(text)”"
	}
}
