import AppKit
import Foundation
import Observation
import os

/// Orchestrates everything between the UI and OMP: process lifecycle, protocol
/// negotiation, model selection, streaming, interactive requests, session
/// restore, and idle shutdown.
///
/// Deliberately owns no agent logic. Tools, context, editing, shell, git, LSP,
/// subagents, memory, and compaction all stay inside OMP; this type only
/// forwards intent and renders what comes back.
@MainActor
@Observable
public final class AgentCoordinator {
	// MARK: - Observable state

	public private(set) var runState: AgentRunState = .stopped
	public private(set) var items: [ConversationItem] = []
	public private(set) var workspace: Workspace
	public private(set) var activeModelDescription: String?
	public private(set) var thinkingLevel: String?
	public private(set) var contextPercent: Double?
	/// Local commands plus whatever OMP last advertised. Cached across runs so
	/// the `/` list is complete before the process has even started.
	public private(set) var availableCommands: [SlashCommand] = SlashCommand.local
	public private(set) var modelSupportsImages = false

	/// What the next run will use. Changing it does not touch a live process —
	/// the tool registry is fixed at launch, so the switch lands on the next
	/// boot (see `ensureRunning`).
	public private(set) var mode: AgentMode = AppConfiguration.defaultMode
	/// The mode the running process was actually launched with.
	private var runningMode: AgentMode?

	/// True when a restart is owed because the mode changed under a live process.
	public var modeIsPending: Bool { runningMode != nil && runningMode != mode }

	public var hasConversation: Bool { !items.isEmpty }

	/// True while OMP is streaming or running tools — the composer uses this to
	/// pick `steer` over a plain `prompt`.
	public var isBusy: Bool { runState.isBusy }

	// MARK: - Collaborators

	private let transport: OmpTransport
	private let requests = RpcRequestStore()
	private let defaults: UserDefaults
	private let apiKeyProvider: @Sendable () -> String?
	private let apiKeyWriter: @Sendable (String) throws -> Void
	/// Injectable so the shutdown path is testable without waiting ten minutes.
	private let idleInterval: TimeInterval

	private let lifecycleLog = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "lifecycle")
	private let rpcLog = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "rpc")
	private let sessionLog = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "session")

	// MARK: - Internal bookkeeping

	private var consumeTask: Task<Void, Never>?
	private var bootTask: Task<Void, Error>?
	private var readyContinuation: CheckedContinuation<RpcReady, Error>?
	private var idleTimer: DispatchSourceTimer?
	private var streamingAssistantId: String?
	/// Streamed text not yet written into `items` — see `appendAssistant`.
	private var streamingBuffer = ""
	private var flushTask: Task<Void, Never>?
	private var pendingRequestIds: Set<String> = []
	private var sessionFile: String?
	/// Bumped on every launch. The previous process's event stream can still be
	/// draining when the next one boots (a mode switch or `/cd` restarts it), and
	/// a late `terminated` from the old one would otherwise stop the new one.
	private var processGeneration = 0
	/// Set while this app is the one stopping OMP, so the termination handler
	/// does not report a deliberate restart as a crash.
	private var expectingShutdown = false

	/// Most recent transcripts on disk, for the conversation picker. Refreshed
	/// on demand rather than watched: the list is only read when the menu opens.
	public private(set) var recentSessions: [SessionSummary] = []
	/// Path of the transcript currently loaded, so the picker can mark it.
	public var activeSessionPath: String? { sessionFile }

	// MARK: - Init

	public init(
		transport: OmpTransport = LiveOmpTransport(),
		defaults: UserDefaults = .standard,
		idleInterval: TimeInterval = AppConfiguration.idleShutdownInterval,
		apiKeyProvider: @escaping @Sendable () -> String? = { KeychainStore.readIfPresent() },
		apiKeyWriter: @escaping @Sendable (String) throws -> Void = { try KeychainStore.write($0) }
	) {
		self.transport = transport
		self.defaults = defaults
		self.idleInterval = idleInterval
		self.apiKeyProvider = apiKeyProvider
		self.apiKeyWriter = apiKeyWriter

		if let saved = defaults.string(forKey: AppConfiguration.DefaultsKey.workspacePath) {
			self.workspace = Workspace(url: URL(fileURLWithPath: saved))
		} else {
			self.workspace = .default
		}
		self.sessionFile = defaults.string(forKey: AppConfiguration.DefaultsKey.lastSessionFile)
		if let saved = defaults.string(forKey: AppConfiguration.DefaultsKey.mode),
		   let restored = AgentMode(rawValue: saved) {
			self.mode = restored
		}
		loadCachedCommands()
	}

	// MARK: - Public intent

	/// Handles one composer submission: local slash commands first, then a
	/// prompt to OMP.
	public func submit(text rawText: String, attachments: [PendingAttachment]) async {
		let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty || !attachments.isEmpty else { return }

		if text.hasPrefix("/"), let command = LocalCommand(input: text) {
			await run(local: command)
			return
		}

		await send(prompt: text, attachments: attachments)
	}

	/// Interrupts the running turn.
	///
	/// The `isBusy` guard is load-bearing, not defensive: `⌘.` and `/abort` are
	/// reachable with nothing running, and OMP emits no `agent_end` for a turn
	/// that already finished — so `.aborting` would never be cleared. Every
	/// escape hatch (the idle reaper, mode switching, session switching) refuses
	/// to run while the state reads busy, so the app would be stuck until the
	/// next prompt.
	public func abort() async {
		guard transport.isRunning, runState.isBusy else { return }
		let interrupted = runState
		runState = .aborting
		do {
			_ = try await request(.abort, timeout: .seconds(10))
		} catch {
			// The abort never landed, so whatever was running still is.
			runState = interrupted
			append(.failure(FailureEntry(text: "Não foi possível abortar.", detail: error.localizedDescription)))
		}
	}

	/// `Cmd+K`. Clears the view and asks OMP for a fresh session so context
	/// does not leak between tasks.
	public func startNewSession() async {
		// A live turn keeps streaming into the transcript that is about to be
		// cleared, and `new_session` mid-run races the session file the old turn
		// is still writing. Aborting first is also what the user means by ⌘K
		// during a run — blocking on "wait for it to finish" would be worse.
		if runState.isBusy { await abort() }
		items.removeAll()
		discardStreamingText()
		pendingRequestIds.removeAll()
		guard transport.isRunning else {
			sessionFile = nil
			defaults.removeObject(forKey: AppConfiguration.DefaultsKey.lastSessionFile)
			return
		}
		do {
			_ = try await request(.newSession, timeout: .seconds(30))
			await refreshState()
		} catch {
			append(.failure(FailureEntry(text: "Falha ao iniciar sessão.", detail: error.localizedDescription)))
		}
	}

	/// `/cd`. OMP resolves its cwd at launch and cannot be moved afterwards, so
	/// the workspace change restarts the process on the new directory.
	public func changeWorkspace(to url: URL) async {
		let resolved = Workspace(url: url)
		var isDirectory: ObjCBool = false
		guard FileManager.default.fileExists(atPath: resolved.url.path, isDirectory: &isDirectory),
		      isDirectory.boolValue
		else {
			append(.failure(FailureEntry(text: "Diretório inexistente: \(resolved.displayName)")))
			return
		}

		// Same reason as `startNewSession`: a turn still streaming would repopulate
		// the transcript this method clears, and closing stdin under a running
		// tool is not a graceful stop.
		if runState.isBusy { await abort() }

		workspace = resolved
		defaults.set(resolved.url.path, forKey: AppConfiguration.DefaultsKey.workspacePath)
		// A session is bound to the directory it was created in; carrying the
		// old one into a new root would resolve every relative path wrongly.
		sessionFile = nil
		defaults.removeObject(forKey: AppConfiguration.DefaultsKey.lastSessionFile)

		// The transcript goes with it. Leaving it on screen while the model
		// starts a fresh session is the worst possible state: the history looks
		// present and the agent has none of it.
		items.removeAll()
		discardStreamingText()
		pendingRequestIds.removeAll()

		if transport.isRunning { await shutdown(reason: "workspace changed") }
		append(.notice(NoticeEntry(
			level: .info,
			text: "Workspace: \(resolved.displayName) — conversa nova, o contexto anterior não vem junto."
		)))
	}

	public func answer(requestId: String, with answer: ExtensionUIAnswer) {
		guard pendingRequestIds.remove(requestId) != nil else { return }
		markRequestAnswered(requestId)
		do {
			try transport.send(.extensionUIResponse(requestId: requestId, answer: answer), id: nil)
			touchActivity()
		} catch {
			append(.failure(FailureEntry(text: "Falha ao responder à solicitação.", detail: error.localizedDescription)))
		}
	}

	/// The message a retry would re-send, or nil when there is nothing to retry.
	///
	/// Nil when a turn is running, when nothing has been sent, or when the last
	/// message carried attachments: a `UserTurn` only keeps a summary of those,
	/// so re-sending would silently drop the image or file and produce a
	/// different request from the one that failed.
	public var retryableMessage: String? {
		guard !runState.isBusy else { return nil }
		for item in items.reversed() {
			guard case .user(let turn) = item else { continue }
			guard turn.attachments.isEmpty, !turn.text.isEmpty else { return nil }
			return turn.text
		}
		return nil
	}

	/// Re-sends the last user message after a terminal failure. The alternative
	/// is retyping what was just typed.
	public func retryLastMessage() async {
		guard let text = retryableMessage else { return }
		await send(prompt: text, attachments: [])
	}

	/// Text of the last assistant answer, for `Cmd+C` with no selection.
	public var lastAssistantText: String? {
		items.reversed().compactMap { item -> String? in
			guard case .assistant(let turn) = item, !turn.text.isEmpty else { return nil }
			return turn.text
		}.first
	}

	public func shutdownForAppExit() {
		idleTimer?.cancel()
		idleTimer = nil
		consumeTask?.cancel()
		transport.stopImmediately()
	}

	/// Opens the standard directory chooser and adopts the result.
	public func chooseWorkspace() {
		guard let picked = WorkspacePicker.chooseDirectory(
			startingAt: workspace.resolvedExistingURL(),
			host: hostWindow
		) else { return }
		Task { await changeWorkspace(to: picked) }
	}

	/// Lists past conversations and resumes the chosen one.
	public func presentSessionPicker() {
		Task { @MainActor in
			await refreshRecentSessions()
			SessionPicker.present(
				sessions: recentSessions,
				currentWorkspace: workspace.url,
				currentSessionPath: sessionFile,
				host: hostWindow,
				onNew: { [weak self] in
					guard let self else { return }
					Task { await self.startNewSession() }
				},
				onSelect: { [weak self] session in
					guard let self else { return }
					Task { await self.resume(session) }
				}
			)
		}
	}

	/// The floating panel, when it exists — the pickers suspend its auto-dismiss
	/// so it does not vanish behind their own dialog.
	private var hostWindow: FloatingPanel? {
		NSApp.windows.compactMap { $0 as? FloatingPanel }.first
	}

	/// Renders the saved conversation straight from its transcript file.
	///
	/// Called at launch and after resuming, so reopening the panel shows the
	/// history immediately. The RPC path only runs during a boot, which the
	/// first prompt triggers — so without this the panel looked empty after an
	/// app restart even though the session was on disk.
	public func restoreConversationFromDisk() async {
		guard items.isEmpty,
		      let path = sessionFile,
		      FileManager.default.fileExists(atPath: path)
		else { return }

		let restored = await Task.detached(priority: .userInitiated) {
			SessionStore.conversation(at: path)
		}.value

		// Re-checked after the hop: a prompt may have started in the meantime,
		// and overwriting live items with a stale snapshot would lose it.
		guard items.isEmpty, !restored.isEmpty else { return }
		items = restored
		sessionLog.info("restored \(restored.count, privacy: .public) items from transcript")
	}

	/// Reloads the on-disk transcript list off the main actor.
	public func refreshRecentSessions() async {
		let root = SessionStore.root(forSessionFile: sessionFile)
		let found = await Task.detached(priority: .userInitiated) {
			SessionStore.recentSessions(root: root)
		}.value
		recentSessions = found
	}

	/// Resumes a past conversation.
	///
	/// A transcript is bound to the directory it was recorded in, so resuming
	/// one from elsewhere moves the workspace with it — otherwise every relative
	/// path in that history would resolve against the wrong tree.
	public func resume(_ session: SessionSummary) async {
		guard !runState.isBusy else {
			append(.notice(NoticeEntry(
				level: .warning,
				text: "Termine ou aborte a execução antes de trocar de conversa."
			)))
			return
		}
		guard session.path != sessionFile || items.isEmpty else { return }

		let target = URL(fileURLWithPath: session.cwd).standardizedFileURL
		let needsWorkspaceChange = !session.cwd.isEmpty && target != workspace.url

		items.removeAll()
		discardStreamingText()
		pendingRequestIds.removeAll()

		if needsWorkspaceChange {
			workspace = Workspace(url: target)
			defaults.set(target.path, forKey: AppConfiguration.DefaultsKey.workspacePath)
			append(.notice(NoticeEntry(level: .info, text: "Workspace: \(workspace.displayName)")))
		}

		sessionFile = session.path
		defaults.set(session.path, forKey: AppConfiguration.DefaultsKey.lastSessionFile)

		// cwd is fixed at launch, so a directory change needs a fresh process;
		// otherwise the running one can just switch transcripts.
		if needsWorkspaceChange, transport.isRunning {
			await shutdown(reason: "resuming a session from another directory")
		}

		// Rendered from disk first so the conversation appears immediately;
		// starting or switching the process happens behind it.
		await restoreConversationFromDisk()

		do {
			try await ensureRunning()
			if !needsWorkspaceChange {
				let response = try await request(.switchSession(path: session.path), timeout: .seconds(30))
				guard response.data?["cancelled"]?.boolValue != true else {
					throw RpcError.commandFailed(
						command: "switch_session",
						message: "a troca de sessão foi cancelada",
						code: nil
					)
				}
				try await confirmSessionLoaded(expecting: session.path)
				await refreshState()
			}
		} catch {
			append(.failure(FailureEntry(
				text: "Não foi possível retomar a conversa.",
				detail: error.localizedDescription
			)))
		}
	}

	/// `Tab`. Refused mid-run: the tool registry cannot change under a turn
	/// that is already using it.
	@discardableResult
	public func toggleMode() -> Bool {
		setMode(mode.next)
	}

	@discardableResult
	public func setMode(_ newMode: AgentMode) -> Bool {
		guard !runState.isBusy else {
			append(.notice(NoticeEntry(
				level: .warning,
				text: "Termine ou aborte a execução antes de trocar de modo."
			)))
			return false
		}
		guard newMode != mode else { return true }

		mode = newMode
		defaults.set(newMode.rawValue, forKey: AppConfiguration.DefaultsKey.mode)
		lifecycleLog.info("mode -> \(newMode.rawValue, privacy: .public)")
		return true
	}

	// MARK: - Local commands

	enum LocalCommand: Equatable {
		case changeDirectory(String)
		case setAPIKey(String)
		case newSession
		case abort
		case status

		init?(input: String) {
			let parts = input.dropFirst().split(separator: " ", maxSplits: 1).map(String.init)
			guard let verb = parts.first?.lowercased() else { return nil }
			let argument = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
			switch verb {
			case "cd": self = .changeDirectory(argument)
			case "key": self = .setAPIKey(argument)
			case "new": self = .newSession
			case "abort": self = .abort
			case "status": self = .status
			default: return nil
			}
		}

		/// True when the raw input carries a secret and must never be echoed,
		/// logged, or kept in the transcript.
		var isSensitive: Bool {
			if case .setAPIKey(let value) = self { return !value.isEmpty }
			return false
		}
	}

	private func run(local command: LocalCommand) async {
		switch command {
		case .changeDirectory(let path):
			// Bare `/cd` opens the chooser rather than printing the current
			// path, which the status chip already shows.
			guard !path.isEmpty else {
				chooseWorkspace()
				return
			}
			await changeWorkspace(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
		case .setAPIKey(let value):
			await storeAPIKey(value)
		case .newSession:
			await startNewSession()
		case .abort:
			await abort()
		case .status:
			await reportStatus()
		}
	}

	/// `/key sk-…` — writes the OpenCode Zen key straight to the keychain.
	///
	/// The raw value never reaches the transcript, a log line, or `UserDefaults`:
	/// `submit` routes slash commands before any `UserTurn` is appended, the
	/// composer is cleared before this runs, and only a masked tail is echoed.
	private func storeAPIKey(_ raw: String) async {
		let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)

		guard !key.isEmpty else {
			let present = apiKeyProvider()?.isEmpty == false
			append(.notice(NoticeEntry(
				level: present ? .info : .warning,
				text: present
					? "Chave do OpenCode Zen configurada no Keychain."
					: "Nenhuma chave configurada. Use `/key sk-…` para gravar."
			)))
			return
		}

		do {
			try apiKeyWriter(key)
		} catch {
			// `error` here comes from Keychain Services and never contains the
			// value itself, so it is safe to surface.
			append(.failure(FailureEntry(
				text: "Não foi possível gravar a chave no Keychain.",
				detail: error.localizedDescription
			)))
			return
		}

		sessionLog.info("opencode api key updated")
		append(.notice(NoticeEntry(level: .info, text: "Chave gravada no Keychain (\(Self.masked(key))).")))

		// A live process still holds the old key in its environment, and the
		// environment of a running process cannot be changed. Stopping it makes
		// the next prompt boot with the new key.
		if transport.isRunning {
			await shutdown(reason: "api key changed")
			append(.notice(NoticeEntry(
				level: .info,
				text: "O OMP será reiniciado com a nova chave no próximo envio."
			)))
		}
	}

	/// Only the last four characters, enough to confirm *which* key was stored
	/// without leaving a usable fragment on screen.
	static func masked(_ key: String) -> String {
		guard key.count > 4 else { return String(repeating: "•", count: 8) }
		return "••••" + key.suffix(4)
	}

	private func reportStatus() async {
		var lines = [
			"\(AppConfiguration.versionedName)",
			"Modo: \(mode.label) — \(mode.summary)",
			"Estado: \(runState.label)",
			"Workspace: \(workspace.displayName)",
			"Modelo: \(activeModelDescription ?? AppConfiguration.primaryModelSelector) (não iniciado)",
			"Chave: \(apiKeyProvider()?.isEmpty == false ? "configurada" : "ausente — use `/key sk-…`")",
		]
		if transport.isRunning {
			await refreshState()
			lines[2] = "Modelo: \(activeModelDescription ?? "desconhecido") · effort \(thinkingLevel ?? "—")"
			if let contextPercent {
				lines.append("Contexto: \(String(format: "%.1f", contextPercent))%")
			}
			lines.append("Sessão: \(sessionFile.map(ToolSummaryFormatter.shortenPath) ?? "—")")
			lines.append("Imagens: \(modelSupportsImages ? "suportadas" : "não suportadas pelo modelo")")
		} else {
			lines.append("OMP: desligado (inicia no próximo prompt)")
		}
		let shortcut = AppConfiguration.defaultGlobalShortcut
		if GlobalHotKeyController.mayBeShadowedBySystem(shortcut) {
			lines.append("""
			Atalho: \(shortcut) pode estar tomado pela troca de fonte de entrada do macOS \
			(há mais de um teclado ativo) — use o ícone da barra
			""")
		}
		append(.notice(NoticeEntry(level: .info, text: lines.joined(separator: "\n"))))
	}

	// MARK: - Prompting

	private func send(prompt text: String, attachments: [PendingAttachment]) async {
		do {
			try await ensureRunning()
		} catch {
			append(.failure(FailureEntry(text: error.localizedDescription)))
			return
		}

		// An image only has nowhere to go when the active model cannot read one
		// *and* no vision model is configured. Otherwise OMP's `inspect_image`
		// picks it up and delegates to `modelRoles.vision`.
		let images = attachments.compactMap(\.image)
		if !images.isEmpty, !modelSupportsImages, AppConfiguration.visionModelSelector == nil {
			append(.failure(FailureEntry(
				text: "O modelo \(activeModelDescription ?? AppConfiguration.primaryModelSelector) não aceita imagens.",
				detail: "Defina AppConfiguration.visionModelSelector para habilitar um modelo de visão."
			)))
			return
		}

		let message = composeMessage(text: text, attachments: attachments)
		append(.user(UserTurn(text: text, attachments: attachments.map(\.summary))))

		// While OMP is already streaming, `prompt` without an explicit
		// behaviour is rejected. Steering is the right default for a message
		// typed mid-run (it reads as a correction); during compaction or an
		// abort the interrupt path is unavailable, so it queues as a follow-up.
		// Sampled before the state moves to `.thinking`, which would otherwise
		// make every prompt look busy.
		let behavior: StreamingBehavior?
		switch runState {
		case .compacting, .aborting: behavior = .followUp
		case .thinking, .usingTool: behavior = .steer
		case .stopped, .starting, .ready, .failed: behavior = nil
		}

		runState = .thinking
		touchActivity()

		do {
			let response = try await request(
				.prompt(message: message, images: images, streamingBehavior: behavior),
				timeout: .seconds(30)
			)
			// `agentInvoked: false` means a local-only prompt already finished
			// and no `agent_end` will follow.
			if response.data?["agentInvoked"]?.boolValue == false {
				finishStreaming()
				runState = .ready
			}
		} catch {
			runState = .ready
			finishStreaming()
			append(.failure(FailureEntry(text: "Falha ao enviar.", detail: error.localizedDescription)))
		}
	}

	/// Files and folders are passed as absolute paths, not inlined content:
	/// OMP has its own read/glob tools and knows how to budget the context.
	private func composeMessage(text: String, attachments: [PendingAttachment]) -> String {
		let paths = attachments.compactMap(\.fileURL)
		guard !paths.isEmpty else { return text }

		var lines = text.isEmpty ? [] : [text]
		lines.append("")
		lines.append("Itens anexados (caminhos absolutos no disco):")
		for url in paths {
			var isDirectory: ObjCBool = false
			FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
			lines.append("- \(isDirectory.boolValue ? "pasta" : "arquivo"): \(url.path)")
		}
		return lines.joined(separator: "\n")
	}

	// MARK: - Boot sequence

	/// Starts OMP on demand and brings it to a usable state. Concurrent callers
	/// share one boot.
	public func ensureRunning() async throws {
		// A boot already in flight wins over the `isRunning` check: the process
		// exists but is not yet negotiated or pointed at the right model.
		if let bootTask { return try await bootTask.value }
		if transport.isRunning {
			guard modeIsPending else { return }
			// The session file is kept, so the restart reloads the same
			// conversation — switching modes never loses context.
			lifecycleLog.info("restarting for mode change")
			await shutdown(reason: "mode changed")
		}

		let task = Task { [weak self] in
			guard let self else { return }
			try await self.boot()
		}
		bootTask = task
		defer { bootTask = nil }
		do {
			try await task.value
		} catch {
			runState = .failed(error.localizedDescription)
			transport.stop()
			throw error
		}
	}

	private func boot() async throws {
		guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
			throw AgentError.missingAPIKey
		}

		runState = .starting
		lifecycleLog.info("starting omp in \(self.workspace.url.path, privacy: .public)")

		let launchMode = mode
		let stream = try transport.start(
			workspace: workspace.resolvedExistingURL(),
			apiKey: apiKey,
			mode: launchMode
		)
		runningMode = launchMode
		processGeneration += 1
		let generation = processGeneration
		// Inherits main-actor isolation from `boot()`, so frames are applied in
		// arrival order with no hop between them. The generation check drops
		// anything still arriving from a process we already replaced.
		consumeTask = Task { [weak self] in
			for await event in stream {
				guard let self, self.processGeneration == generation else { continue }
				self.handle(event)
			}
			guard let self, self.processGeneration == generation else { return }
			self.handleStreamEnd()
		}

		let ready = try await awaitReadyFrame(timeout: .seconds(30))

		if ready.supportsV2 {
			_ = try await request(
				.negotiateProtocol(version: AppConfiguration.protocolVersion),
				timeout: .seconds(10)
			)
			transport.enableChunkReassembly(maxReassembledBytes: ready.maxReassembledFrameBytes)
			rpcLog.info("protocol v2 negotiated")
		} else {
			rpcLog.notice("server advertises v1 only; staying on unchunked framing")
		}

		try await selectModel()
		await restoreSessionIfPossible()
		await refreshState()

		runState = .ready
		touchActivity()
	}

	/// The `ready` frame is pushed by the server rather than answered to a
	/// command, so it cannot go through `RpcRequestStore`.
	private func awaitReadyFrame(timeout: Duration) async throws -> RpcReady {
		let timeoutTask = Task { [weak self] in
			try? await Task.sleep(for: timeout)
			guard !Task.isCancelled else { return }
			self?.failReadyWait(with: AgentError.readyTimeout)
		}
		defer { timeoutTask.cancel() }

		return try await withCheckedThrowingContinuation { continuation in
			readyContinuation = continuation
		}
	}

	private func failReadyWait(with error: Error) {
		guard let continuation = readyContinuation else { return }
		readyContinuation = nil
		continuation.resume(throwing: error)
	}

	/// Resolves the configured provider/model against the live catalogue.
	/// Never falls back to a different model silently.
	private func selectModel() async throws {
		let response = try await request(.getAvailableModels, timeout: .seconds(30))
		let models = response.data?["models"]?.arrayValue ?? []

		let providerModels = models.filter { $0["provider"]?.stringValue == AppConfiguration.providerId }
		guard !providerModels.isEmpty else {
			throw AgentError.providerUnavailable(AppConfiguration.providerId)
		}

		guard let match = providerModels.first(where: { $0["id"]?.stringValue == AppConfiguration.primaryModelId })
		else {
			// Dated variants (e.g. `-0731`) only exist if the catalogue says so;
			// report what is actually there instead of guessing an id.
			let candidates = providerModels
				.compactMap { $0["id"]?.stringValue }
				.filter { $0.contains(AppConfiguration.primaryModelId) }
			rpcLog.error("""
			model \(AppConfiguration.primaryModelSelector, privacy: .public) not in catalogue; \
			near matches: \(candidates.joined(separator: ", "), privacy: .public)
			""")
			throw AgentError.modelUnavailable(
				selector: AppConfiguration.primaryModelSelector,
				nearMatches: candidates
			)
		}

		let setResponse = try await request(
			.setModel(provider: AppConfiguration.providerId, modelId: AppConfiguration.primaryModelId),
			timeout: .seconds(30)
		)
		apply(model: setResponse.data ?? match)
		try await applyThinkingLevel(for: setResponse.data ?? match)
	}

	/// Requests the configured reasoning effort, clamped to what the model
	/// actually advertises. Asking for an unsupported effort fails the command,
	/// so an unknown catalogue shape degrades to the model's default rather
	/// than aborting a boot that would otherwise work.
	private func applyThinkingLevel(for model: JSONValue) async throws {
		let supported = model["thinking"]?["efforts"]?.arrayValue?.compactMap(\.stringValue) ?? []
		guard supported.isEmpty || supported.contains(AppConfiguration.thinkingLevel) else {
			rpcLog.notice("""
			thinking level \(AppConfiguration.thinkingLevel, privacy: .public) unsupported; \
			model offers \(supported.joined(separator: ", "), privacy: .public)
			""")
			append(.notice(NoticeEntry(
				level: .warning,
				text: "Effort `\(AppConfiguration.thinkingLevel)` indisponível neste modelo. Usando o padrão."
			)))
			return
		}

		do {
			_ = try await request(
				.setThinkingLevel(level: AppConfiguration.thinkingLevel),
				timeout: .seconds(15)
			)
			thinkingLevel = AppConfiguration.thinkingLevel
		} catch {
			rpcLog.error("set_thinking_level failed: \(error.localizedDescription, privacy: .public)")
			append(.notice(NoticeEntry(
				level: .warning,
				text: "Não foi possível fixar o effort `\(AppConfiguration.thinkingLevel)`."
			)))
		}
	}

	private func apply(model: JSONValue) {
		let provider = model["provider"]?.stringValue ?? AppConfiguration.providerId
		let id = model["id"]?.stringValue ?? AppConfiguration.primaryModelId
		activeModelDescription = "\(provider)/\(id)"
		// `input` lists the accepted content kinds; `deepseek-v4-flash`
		// advertises `["text"]` only, so images must not be sent to it.
		let inputs = model["input"]?.arrayValue?.compactMap(\.stringValue) ?? ["text"]
		modelSupportsImages = inputs.contains("image")
	}

	private func restoreSessionIfPossible() async {
		guard let sessionFile, FileManager.default.fileExists(atPath: sessionFile) else { return }
		do {
			let response = try await request(.switchSession(path: sessionFile), timeout: .seconds(30))
			// `switch_session` answers `success: true` with `cancelled: true`
			// when it declined to switch. Treating that as success is how the
			// panel ended up showing a conversation the model had never seen.
			guard response.data?["cancelled"]?.boolValue != true else {
				throw RpcError.commandFailed(
					command: "switch_session",
					message: "a troca de sessão foi cancelada",
					code: nil
				)
			}
			try await confirmSessionLoaded(expecting: sessionFile)
			sessionLog.info("session restored")
			if items.isEmpty { await restoreHistory() }
		} catch {
			sessionLog.notice("session restore failed, continuing with a fresh session")
			self.sessionFile = nil
			defaults.removeObject(forKey: AppConfiguration.DefaultsKey.lastSessionFile)
			// Loudly, and the transcript goes too: a visible history the model
			// cannot see is worse than an empty one.
			items.removeAll()
			discardStreamingText()
			append(.notice(NoticeEntry(
				level: .warning,
				text: "Não foi possível retomar a conversa anterior. Começando uma nova."
			)))
		}
	}

	/// Asks OMP which transcript it actually loaded.
	///
	/// The response to `switch_session` says the command was accepted, not that
	/// the session is the one requested — and a mismatch means every later
	/// prompt lands in a different conversation than the one on screen.
	private func confirmSessionLoaded(expecting path: String) async throws {
		let state = try await request(.getState, timeout: .seconds(15))
		let loaded = state.data?["sessionFile"]?.stringValue ?? ""
		guard loaded == path else {
			throw RpcError.commandFailed(
				command: "switch_session",
				message: "o omp continuou em outra sessão (\(URL(fileURLWithPath: loaded).lastPathComponent))",
				code: nil
			)
		}
	}

	private func restoreHistory() async {
		guard let response = try? await request(
			.getMessagesPage(cursor: nil, limit: 64),
			timeout: .seconds(30)
		), response.success else { return }

		let messages = response.data?["messages"]?.arrayValue ?? []
		var restored: [ConversationItem] = []
		for message in messages {
			guard let role = message["role"]?.stringValue else { continue }
			let blocks = message["content"]?.arrayValue ?? []
			let text = blocks
				.filter { $0["type"]?.stringValue == "text" }
				.compactMap { $0["text"]?.stringValue }
				.joined()
			switch role {
			case "user" where !text.isEmpty:
				restored.append(.user(UserTurn(text: text)))
			case "assistant":
				if !text.isEmpty {
					restored.append(.assistant(AssistantTurn(text: text, isStreaming: false)))
				}
				for block in blocks where block["type"]?.stringValue == "toolCall" {
					restored.append(.tool(ToolActivity(
						id: block["id"]?.stringValue ?? UUID().uuidString,
						name: block["name"]?.stringValue ?? "tool",
						arguments: block["arguments"] ?? .object([:]),
						status: .succeeded
					)))
				}
			default:
				break
			}
		}
		guard !restored.isEmpty else { return }
		items = restored
		append(.notice(NoticeEntry(level: .info, text: "Sessão anterior restaurada.")))
	}

	private func refreshState() async {
		guard let response = try? await request(.getState, timeout: .seconds(15)),
		      let data = response.data
		else { return }

		if let model = data["model"] { apply(model: model) }
		if let level = data["thinkingLevel"]?.stringValue { thinkingLevel = level }
		if let percent = data["contextUsage"]?["percent"]?.doubleValue { contextPercent = percent }
		if let file = data["sessionFile"]?.stringValue, !file.isEmpty {
			sessionFile = file
			defaults.set(file, forKey: AppConfiguration.DefaultsKey.lastSessionFile)
		}
		if data["isCompacting"]?.boolValue == true {
			runState = .compacting
		} else if data["isStreaming"]?.boolValue == false, !runState.isBusy {
			runState = .ready
		}
	}

	// MARK: - Request plumbing

	@discardableResult
	private func request(_ command: RpcCommand, timeout: Duration) async throws -> RpcResponse {
		let id = requests.nextId()
		try transport.send(command, id: id)
		let response = try await requests.response(forId: id, command: command.commandType, timeout: timeout)
		guard response.success else {
			throw RpcError.commandFailed(
				command: response.command,
				message: response.error ?? "unknown error",
				code: response.code
			)
		}
		return response
	}

	// MARK: - Event handling

	private func handle(_ event: OmpProcessEvent) {
		switch event {
		case .started:
			break
		case .frame(let frame):
			handle(frame)
		case .decodeFailure(let message):
			rpcLog.error("decode failure: \(message, privacy: .public)")
		case .stderr(let text):
			// OMP writes diagnostics here; surface only what looks like a real
			// failure so routine chatter does not pollute the conversation.
			let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
			guard !trimmed.isEmpty else { return }
			rpcLog.debug("omp stderr: \(trimmed, privacy: .private)")
		case .terminated(let status, let reason):
			handleTermination(status: status, reason: reason)
		}
	}

	private func handle(_ frame: RpcFrame) {
		switch frame {
		case .ready(let ready):
			readyContinuation?.resume(returning: ready)
			readyContinuation = nil

		case .response(let response):
			if !requests.resolve(response), !response.success {
				// Uncorrelated failure (parse errors and unknown commands come
				// back with `id: undefined`).
				append(.failure(FailureEntry(
					text: "Erro do OMP em \(response.command).",
					detail: response.error
				)))
			}

		case .agentEvent(let event):
			handle(agent: event)

		case .extensionUIRequest(let request):
			handle(uiRequest: request)

		case .promptResult(_, let agentInvoked):
			if !agentInvoked {
				finishStreaming()
				if !runState.isBusy { runState = .ready }
			}

		case .availableCommands(let commands):
			store(ompCommands: commands)

		case .commandOutput(let payload):
			// `/session`, `/context`, `/usage`, `/tools` and every other local
			// slash command answer here instead of through an agent turn.
			// Dropping these frames is why those commands used to do nothing.
			let text = payload["text"]?.stringValue ?? ""
			guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
			append(.output(CommandOutputEntry(text: text)))

		case .subagent, .unknown:
			break

		case .extensionError(let path, let event, let message):
			rpcLog.error("extension \(path, privacy: .public) failed on \(event, privacy: .public)")
			append(.failure(FailureEntry(text: "Extensão falhou: \(message)")))
		}
	}

	// swiftlint:disable:next cyclomatic_complexity
	private func handle(agent event: AgentEventFrame) {
		touchActivity()
		switch event {
		case .agentStart:
			runState = .thinking

		case .agentEnd(let isTerminal, _):
			// `isTerminal: false` means maintenance rescheduled more work; the
			// run has not actually settled yet.
			guard isTerminal else { return }
			finishStreaming()
			runState = .ready
			Task { await self.refreshState() }

		case .messageUpdate(let delta):
			apply(delta)

		case .messageEnd(let role, _):
			// `message_end` also fires for user and toolResult messages; only
			// the assistant's own message closes a streaming block.
			if role == "assistant" { finishStreaming() }

		case .toolExecutionStart(let id, let name, let arguments):
			finishStreaming()
			runState = .usingTool(name)
			append(.tool(ToolActivity(id: id, name: name, arguments: arguments)))

		case .toolExecutionUpdate:
			break

		case .toolExecutionEnd(let id, _, let result, let isError):
			completeTool(id: id, result: result, isError: isError)
			if case .usingTool = runState { runState = .thinking }

		case .compactionStart:
			runState = .compacting
			append(.notice(NoticeEntry(level: .info, text: "Compactando o contexto…")))

		case .compactionEnd(let aborted, _, let errorMessage):
			runState = .thinking
			if let errorMessage {
				append(.failure(FailureEntry(text: "Compactação falhou.", detail: errorMessage)))
			} else if !aborted {
				append(.notice(NoticeEntry(level: .info, text: "Contexto compactado.")))
			}

		case .retryStart(let attempt, let maxAttempts, let message):
			append(.notice(NoticeEntry(
				level: .warning,
				text: "Tentativa \(attempt)/\(maxAttempts) após erro: \(message)"
			)))

		case .retryEnd(let success, let finalError):
			if !success, let finalError {
				append(.failure(FailureEntry(text: "Falha após novas tentativas.", detail: finalError)))
			}

		case .modelChanged:
			Task { await self.refreshState() }

		case .notice(let level, let message, _):
			// `info` notices are mostly extension mount chatter; only warnings
			// and errors are worth interrupting the conversation for.
			guard level != "info" else { return }
			append(.notice(NoticeEntry(level: NoticeEntry.Level(rawValue: level) ?? .info, text: message)))

		case .turnStart, .turnEnd, .messageStart, .other:
			break
		}
	}

	private func apply(_ delta: AssistantDelta) {
		switch delta {
		case .textDelta(let text):
			appendAssistant(text)
		case .textEnd:
			break
		case .thinkingStarted:
			// Reasoning content is never rendered; only the state changes.
			if case .usingTool = runState {} else { runState = .thinking }
		case .failed(let reason):
			finishStreaming()
			append(.failure(FailureEntry(text: "A resposta terminou com erro (\(reason)).")))
			runState = .ready
		case .done:
			finishStreaming()
		case .start, .thinkingEnded, .toolCallStarted, .toolCallEnd, .other:
			break
		}
	}

	private func handle(uiRequest request: ExtensionUIRequest) {
		switch request.method {
		case .cancel(let targetId):
			pendingRequestIds.remove(targetId)
			markRequestAnswered(targetId)
		case .notify(let message, let level):
			append(.notice(NoticeEntry(level: NoticeEntry.Level(rawValue: level) ?? .info, text: message)))
		case .openURL(let url, let launchURL, let instructions):
			var text = "O OMP pediu para abrir: \(launchURL ?? url)"
			if let instructions { text += "\n\(instructions)" }
			// Not opened automatically — a URL from the agent is not a user action.
			append(.notice(NoticeEntry(level: .warning, text: text)))
		case .setStatus, .setWidget, .setTitle, .setEditorText, .unsupported:
			break
		case .select, .confirm, .input, .editor:
			pendingRequestIds.insert(request.id)
			append(.request(PendingRequest(request: request)))
			touchActivity()
		}
	}

	private func markRequestAnswered(_ id: String) {
		guard let index = items.firstIndex(where: {
			if case .request(let pending) = $0 { return pending.id == id }
			return false
		}), case .request(var pending) = items[index] else { return }
		pending.answered = true
		items[index] = .request(pending)
	}

	private func handleTermination(status: Int32, reason: String) {
		requests.failAll(with: RpcError.processTerminated(reason))
		readyContinuation?.resume(throwing: AgentError.processExited(reason))
		readyContinuation = nil
		finishStreaming()
		pendingRequestIds.removeAll()
		idleTimer?.cancel()
		idleTimer = nil

		let wasBusy = runState.isBusy
		let wasDeliberate = expectingShutdown
		expectingShutdown = false
		runState = .stopped
		runningMode = nil
		// `wasBusy` is true for the whole restart window of a mode switch or a
		// `/cd`, so without the deliberate-shutdown flag a clean exit(0) still
		// reported a crash.
		guard !wasDeliberate, status != 0 || wasBusy else { return }
		lifecycleLog.error("omp exited unexpectedly: \(reason, privacy: .public)")
		append(.failure(FailureEntry(
			text: "O OMP encerrou inesperadamente (\(reason)).",
			detail: "A sessão será retomada no próximo envio."
		)))
	}

	private func handleStreamEnd() {
		consumeTask = nil
		if runState.isRunning, !transport.isRunning { runState = .stopped }
	}

	// MARK: - Slash commands

	/// Merges OMP's advertised commands with the local ones and caches them.
	///
	/// A local command always wins a name collision: `/new` and `/status` exist
	/// on both sides, and the app's own handling is what actually runs.
	private func store(ompCommands: [RpcSlashCommand]) {
		let localNames = Set(SlashCommand.local.map(\.name))
		let forwarded = ompCommands
			.filter { !localNames.contains($0.name) }
			.map {
				SlashCommand(
					name: $0.name,
					summary: $0.description ?? "",
					source: .omp
				)
			}

		let merged = SlashCommand.local + forwarded
		guard merged != availableCommands else { return }
		availableCommands = merged

		if let data = try? JSONEncoder().encode(forwarded) {
			defaults.set(data, forKey: AppConfiguration.DefaultsKey.cachedCommands)
		}
	}

	private func loadCachedCommands() {
		guard let data = defaults.data(forKey: AppConfiguration.DefaultsKey.cachedCommands),
		      let cached = try? JSONDecoder().decode([SlashCommand].self, from: data)
		else { return }
		availableCommands = SlashCommand.local + cached
	}

	// MARK: - Conversation mutation

	private func append(_ item: ConversationItem) {
		// Anything appended has to land after text that is still buffered, or the
		// transcript reorders itself — a tool call would appear above the sentence
		// that announced it.
		if case .assistant = item {} else { flushStreamingText() }
		items.append(item)
	}

	/// Buffers a streamed delta instead of writing it straight into `items`.
	///
	/// Deltas arrive far faster than the panel can usefully redraw. Every one of
	/// them used to mutate `items`, and each mutation cost two full passes over
	/// the answer so far: copy-on-write duplicated the accumulated string (the
	/// enum payload still in the array kept the refcount at two), and the view
	/// re-parsed the whole thing as markdown. Both are O(n) per delta, so O(n²)
	/// per answer — a 100 KB answer copied ~100 MB of string bytes on the main
	/// actor. Coalescing turns that into roughly one mutation per frame.
	private func appendAssistant(_ text: String) {
		guard !text.isEmpty else { return }
		streamingBuffer += text
		guard flushTask == nil else { return }
		flushTask = Task { @MainActor [weak self] in
			try? await Task.sleep(for: AppConfiguration.streamFlushInterval)
			guard let self, !Task.isCancelled else { return }
			self.flushTask = nil
			self.flushStreamingText()
		}
	}

	private func flushStreamingText() {
		let pending = streamingBuffer
		streamingBuffer = ""
		guard !pending.isEmpty else { return }

		guard let index = streamingTurnIndex() else {
			let turn = AssistantTurn(text: pending)
			streamingAssistantId = turn.id
			items.append(.assistant(turn))
			return
		}

		// Taking the item out of the array before mutating leaves the extracted
		// turn as the sole owner of its text storage, so `+=` appends in place
		// rather than copy-on-writing the whole answer. The streaming turn is
		// almost always the last element, which makes this O(1).
		let removed = items.remove(at: index)
		guard case .assistant(var turn) = removed else {
			items.insert(removed, at: index)
			return
		}
		turn.text += pending
		items.insert(.assistant(turn), at: index)
	}

	private func streamingTurnIndex() -> Int? {
		guard let id = streamingAssistantId else { return nil }
		return items.lastIndex {
			if case .assistant(let turn) = $0 { return turn.id == id }
			return false
		}
	}

	/// Drops buffered text without rendering it. Used when the transcript itself
	/// is going away, so a pending flush cannot repopulate a cleared view.
	private func discardStreamingText() {
		flushTask?.cancel()
		flushTask = nil
		streamingBuffer = ""
		streamingAssistantId = nil
	}

	private func finishStreaming() {
		flushTask?.cancel()
		flushTask = nil
		flushStreamingText()
		defer { streamingAssistantId = nil }
		guard let index = streamingTurnIndex(),
		      case .assistant(var turn) = items[index]
		else { return }
		turn.isStreaming = false
		items[index] = .assistant(turn)
	}

	private func completeTool(id: String, result: JSONValue, isError: Bool) {
		guard let index = items.lastIndex(where: {
			if case .tool(let activity) = $0 { return activity.id == id }
			return false
		}), case .tool(var activity) = items[index] else { return }

		let text = ToolResultFormatter.text(from: result)
		activity.status = isError ? .failed : .succeeded
		activity.resultText = text
		activity.diff = isError ? nil : DiffParser.parse(text)
		items[index] = .tool(activity)
	}

	// MARK: - Idle shutdown

	/// Any activity pushes the shutdown deadline out. A single one-shot timer is
	/// used instead of polling so an idle app stays at ~0% CPU.
	private func touchActivity() {
		idleTimer?.cancel()
		guard transport.isRunning else {
			idleTimer = nil
			return
		}

		let timer = DispatchSource.makeTimerSource(queue: .main)
		let leeway: DispatchTimeInterval = idleInterval > 60 ? .seconds(30) : .milliseconds(10)
		timer.schedule(deadline: .now() + idleInterval, leeway: leeway)
		timer.setEventHandler { [weak self] in
			Task { @MainActor in await self?.idleDeadlineReached() }
		}
		timer.resume()
		idleTimer = timer
	}

	private func idleDeadlineReached() async {
		// Never reap mid-work: streaming, a running tool, compaction, an abort,
		// or an unanswered interactive request all keep the process alive.
		guard !runState.isBusy, pendingRequestIds.isEmpty, requests.pendingCount == 0 else {
			touchActivity()
			return
		}
		await shutdown(reason: "idle for \(Int(idleInterval))s")
	}

	private func shutdown(reason: String) async {
		guard transport.isRunning else { return }
		lifecycleLog.info("stopping omp: \(reason, privacy: .public)")
		await refreshState()
		idleTimer?.cancel()
		idleTimer = nil
		expectingShutdown = true
		transport.stop()

		// Wait for the child to be fully torn down before returning: the process
		// controller refuses to start a second one until the previous slot is
		// released, so a restart that did not wait would fail with
		// `alreadyRunning`. Waiting on `isRunning` was not enough — the OS marks
		// the process dead up to ~17 ms before the termination handler runs and
		// clears the slot, and a mode switch restarts inside that window.
		let deadline = Date().addingTimeInterval(AppConfiguration.terminationGraceSeconds + 2)
		while !transport.isStopped, Date() < deadline {
			try? await Task.sleep(for: .milliseconds(25))
		}

		runState = .stopped
		runningMode = nil
	}
}

// MARK: - Errors

public enum AgentError: Error, LocalizedError {
	case missingAPIKey
	case readyTimeout
	case processExited(String)
	case providerUnavailable(String)
	case modelUnavailable(selector: String, nearMatches: [String])

	public var errorDescription: String? {
		switch self {
		case .missingAPIKey:
			return KeychainStore.setupInstructions
		case .readyTimeout:
			return "O OMP não respondeu com o frame `ready` a tempo."
		case .processExited(let reason):
			return "O OMP encerrou durante a inicialização (\(reason))."
		case .providerUnavailable(let provider):
			return """
			Provedor `\(provider)` indisponível. \
			Verifique se a chave \(AppConfiguration.apiKeyEnvironmentVariable) é válida.
			"""
		case .modelUnavailable(let selector, let nearMatches):
			let hint = nearMatches.isEmpty
				? "Nenhum modelo semelhante encontrado no catálogo."
				: "Semelhantes disponíveis: \(nearMatches.joined(separator: ", "))."
			return "Modelo `\(selector)` indisponível. \(hint)"
		}
	}
}
