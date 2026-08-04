import Foundation

/// Explicit lifecycle of the agent as the GUI understands it.
///
/// Only `.stopped` and `.failed` allow the idle timer to reap the process;
/// every other case means work is in flight or a question is waiting.
public enum AgentRunState: Sendable, Equatable {
	case stopped
	case starting
	case ready
	case thinking
	case usingTool(String)
	case compacting
	case aborting
	case failed(String)

	/// True while OMP must stay alive regardless of the idle timer.
	public var isBusy: Bool {
		switch self {
		case .starting, .thinking, .usingTool, .compacting, .aborting: return true
		case .stopped, .ready, .failed: return false
		}
	}

	public var isRunning: Bool {
		if case .stopped = self { return false }
		if case .failed = self { return false }
		return true
	}

	/// Short status shown in the menu bar tooltip and the composer hint.
	public var label: String {
		switch self {
		case .stopped: return "Parado"
		case .starting: return "Iniciando…"
		case .ready: return "Pronto"
		case .thinking: return "Pensando…"
		case .usingTool(let name): return "Executando \(name)…"
		case .compacting: return "Compactando contexto…"
		case .aborting: return "Abortando…"
		case .failed(let message): return "Falha: \(message)"
		}
	}
}
