import Foundation

/// Read-only planning versus full editing.
///
/// Enforced by restricting the tool registry with `omp --tools=…`, not by
/// prompting for approval. In plan mode `write`, `edit`, `bash`, `python`,
/// `notebook`, `browser`, `computer`, and `task` are simply absent — the model
/// has no way to mutate anything, so there is nothing to approve and nothing to
/// slip through.
///
/// OMP's own plan mode lives in the interactive TUI (`Alt+Shift+P`) and is not
/// reachable over RPC, so the tool allow-list is the mechanism available to a
/// protocol host. It is also the stricter of the two.
public enum AgentMode: String, Sendable, CaseIterable, Codable {
	case plan
	case build

	public var next: AgentMode { self == .plan ? .build : .plan }

	public var label: String {
		switch self {
		case .plan: return "Plan"
		case .build: return "Build"
		}
	}

	public var summary: String {
		switch self {
		case .plan: return "Só leitura — investiga e planeja, não altera nada"
		case .build: return "Edita arquivos, roda comandos e usa subagentes"
		}
	}

	public var symbol: String {
		switch self {
		case .plan: return "eye"
		case .build: return "hammer"
		}
	}

	/// `nil` means "every tool", which is what `build` wants — passing an
	/// explicit list would silently drop tools a future OMP adds.
	public var toolAllowList: [String]? {
		switch self {
		case .build: return nil
		case .plan: return AppConfiguration.planModeTools
		}
	}

	/// Extra CLI arguments for this mode.
	public var launchArguments: [String] {
		guard let tools = toolAllowList else { return [] }
		return ["--tools", tools.joined(separator: ",")]
	}
}
