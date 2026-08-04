import Foundation

/// Single place where product identity, provider/model selection, and tuning
/// constants live. Everything the MVP might want to re-brand or re-point is
/// here so no other file hardcodes a name, id, or path.
public enum AppConfiguration {
	// MARK: - Identity

	/// Provisional product name. Change here to rename the whole app.
	public static let appName = "Rune"

	public static let bundleIdentifier = "dev.raniere.Rune"

	// MARK: - Keychain

	public static let keychainService = "dev.raniere.Rune"
	public static let keychainAccount = "opencode-api-key"

	/// Environment variable OMP reads for OpenCode Zen / OpenCode Go auth.
	/// Source: `docs/providers.md` and `docs/environment-variables.md` in
	/// `can1357/oh-my-pi` (v17.2.6).
	public static let apiKeyEnvironmentVariable = "OPENCODE_API_KEY"

	// MARK: - Provider and model

	public static let providerId = "opencode-zen"
	public static let primaryModelId = "deepseek-v4-flash-free"

	/// Reasoning effort requested after the model is pinned.
	/// `deepseek-v4-flash-free` advertises `thinking.efforts == ["high", "max"]`,
	/// so `max` is valid and `low`/`medium` would be rejected.
	public static let thinkingLevel = "max"

	/// Conceptual selector, used only for display and diagnostics.
	public static var primaryModelSelector: String { "\(providerId)/\(primaryModelId)" }

	/// Optional secondary model used for image input. `deepseek-v4-flash`
	/// advertises `input: ["text"]`, so images cannot be routed to it. Set this
	/// to e.g. `"opencode-zen/claude-haiku-4-5"` to enable image prompts.
	/// Left `nil` on purpose: silently switching to a different paid model is
	/// not acceptable.
	public static let visionModelSelector: String? = nil

	// MARK: - OMP process

	public static let ompExecutableName = "omp"

	/// Extra directories probed when `omp` is not on the inherited PATH.
	/// Covers Homebrew on Apple Silicon and Intel plus common per-user prefixes.
	public static let additionalSearchPaths: [String] = [
		"/opt/homebrew/bin",
		"/usr/local/bin",
		NSHomeDirectory() + "/.bun/bin",
		NSHomeDirectory() + "/.local/bin",
		"/usr/bin",
	]

	/// `rpc-ui` is confirmed present in omp 17.2.6 (`--mode=<value> … rpc, or rpc-ui`).
	/// It routes tool cards, selectors, and approval dialogs through
	/// `extension_ui_request` frames, which is exactly what the GUI renders.
	public static let ompMode = "rpc-ui"

	/// `write` auto-approves reads and file writes but prompts for `exec`-tier
	/// tools (bash, browser, subagents). OMP's own default is `yolo`, which
	/// would run shell commands with no confirmation at all.
	public static let approvalMode = "write"

	/// Tools kept in plan mode, as an allow-list for `omp --tools=…`.
	///
	/// Deliberately an allow-list: a deny-list would let any tool a future OMP
	/// release adds default to enabled, which is the wrong failure direction
	/// for a mode whose whole promise is "changes nothing".
	///
	/// Names from `omp --help` (v17.2.6). Excluded on purpose:
	/// `write`/`edit`/`notebook` (mutate files), `bash`/`python` (execute),
	/// `browser`/`computer` (act outside the workspace), and `task` (subagents
	/// would run with their own, unrestricted tool set).
	public static let planModeTools = [
		"read",
		"grep",
		"glob",
		"lsp",
		"web_search",
		"inspect_image",
		"todo",
		"ask",
	]

	public static let defaultMode = AgentMode.build

	public static let protocolVersion = 2

	// MARK: - Workspace

	public static let defaultWorkspaceRoot = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent("Dev")

	// MARK: - Lifecycle

	public static let idleShutdownMinutes = 10

	public static var idleShutdownInterval: TimeInterval {
		TimeInterval(idleShutdownMinutes) * 60
	}

	/// Grace period between SIGTERM and SIGKILL when stopping OMP.
	public static let terminationGraceSeconds: TimeInterval = 5

	// MARK: - Global shortcut

	/// Control + Option + Space.
	public static let defaultGlobalShortcut = GlobalShortcut(keyCode: 49, controlKey: true, optionKey: true)

	// MARK: - UI

	public static let panelWidth: CGFloat = 720
	public static let composerMinHeight: CGFloat = 44
	public static let composerMaxHeight: CGFloat = 180
	public static let historyMaxHeight: CGFloat = 460

	/// Diff and tool-result bodies are clamped before rendering so a 20k-line
	/// patch cannot stall the panel.
	public static let maxRenderedDiffLines = 200
	public static let maxRenderedToolResultCharacters = 4000

	// MARK: - UserDefaults keys (non-sensitive only)

	public enum DefaultsKey {
		public static let lastSessionFile = "lastSessionFile"
		public static let workspacePath = "workspacePath"
		public static let panelHeight = "panelHeight"
		public static let cachedCommands = "cachedSlashCommands"
		public static let mode = "agentMode"
	}
}

/// Carbon-style hot key description. Kept as plain data so it is testable and
/// easy to move into settings later.
public struct GlobalShortcut: Sendable, Equatable {
	public let keyCode: UInt32
	public let controlKey: Bool
	public let optionKey: Bool
	public let shiftKey: Bool
	public let commandKey: Bool

	public init(
		keyCode: UInt32,
		controlKey: Bool = false,
		optionKey: Bool = false,
		shiftKey: Bool = false,
		commandKey: Bool = false
	) {
		self.keyCode = keyCode
		self.controlKey = controlKey
		self.optionKey = optionKey
		self.shiftKey = shiftKey
		self.commandKey = commandKey
	}
}
