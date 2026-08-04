import AppKit
import SwiftUI

/// `Rune --diagnose [saída.png]`
///
/// A menu bar app has no window to look at and is excluded from most app
/// enumerations, so "is it actually running?" is otherwise hard to answer.
/// This mode builds the real status item and the real panel, drives the real
/// boot handshake and frame pipeline with canned RPC frames, prints the
/// resulting geometry, and writes a PNG of the rendered panel.
public enum Diagnostics {
	@MainActor
	public static func run(outputPath: String?) -> Never {
		let app = NSApplication.shared
		app.setActivationPolicy(.accessory)
		// Without this the app never registers with the window server, so
		// activation and key-window handoff silently no-op and the report would
		// understate what a real launch does.
		app.finishLaunching()
		AppMenu.install()

		let report = Report()
		report.section("menu")
		let editActions = AppMenu.installedEditActions
		report.line("edit key equivalents", editActions.isEmpty ? "MISSING — ⌘V vai apitar" : "\(editActions.count)")
		for action in editActions { report.line("", action) }

		report.section("status item")

		let statusItem = StatusItemController()
		statusItem.update(state: .ready)
		report.line("button", statusItem.hasButton ? "present" : "MISSING")
		report.line("image", statusItem.hasImage ? "present" : "MISSING")
		report.line("visible", statusItem.isVisible ? "yes" : "no")

		let transport = PreviewTransport()
		let coordinator = AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.diagnose") ?? .standard,
			idleInterval: 3600,
			apiKeyProvider: { "diagnose-placeholder" }
		)
		let composer = ComposerModel(coordinator: coordinator)

		let hosting = NSHostingController(
			rootView: ConversationView(coordinator: coordinator, composer: composer)
		)
		hosting.sizingOptions = [.preferredContentSize]

		let panel = FloatingPanel(contentRect: NSRect(
			x: 0, y: 0,
			width: AppConfiguration.panelWidth,
			height: AppConfiguration.composerMinHeight + 34
		))
		panel.contentViewController = hosting
		panel.present()

		// Runs the production boot path, then replays a scripted turn through
		// the production frame decoder — nothing here is a mock view. Driven
		// under a real `NSApp.run()` rather than a bare run loop, because
		// activation and key-window handoff only happen inside the full app
		// lifecycle; measuring outside it would report false negatives.
		Task { @MainActor in
			try? await coordinator.ensureRunning()
			composer.text = "por que a sessão cai depois de 1h?"
			composer.submit()
			try? await Task.sleep(for: .milliseconds(150))
			// `RUNE_DIAGNOSE_BUSY=1` stops the replay before `agent_end`,
			// so the render captures the running state — abort button visible,
			// send acting as steer.
			let environment = ProcessInfo.processInfo.environment
			let stayBusy = environment["RUNE_DIAGNOSE_BUSY"] == "1"
			transport.replayScriptedTurn(settle: !stayBusy)
			if stayBusy { composer.text = "na verdade, confere também o refresh token" }
			// `RUNE_DIAGNOSE_SLASH=/co` renders the command popup for that query.
			if let query = environment["RUNE_DIAGNOSE_SLASH"] { composer.text = query }
			try? await Task.sleep(for: .milliseconds(600))
			finish(report: report, panel: panel, coordinator: coordinator, outputPath: outputPath)
		}
		app.run()
		exit(0)
	}

	@MainActor
	private static func finish(
		report: Report,
		panel: FloatingPanel,
		coordinator: AgentCoordinator,
		outputPath: String?
	) -> Never {
		let line = report.line
		report.section("panel")
		line("visible", panel.isVisible ? "yes" : "no")
		// Activation is refused for a process not launched through
		// LaunchServices, so running this binary straight from a shell reports
		// `app active: no` and, consequently, no key window. Launched with
		// `open`, both flip to yes.
		line("app active", NSApp.isActive ? "yes" : "no (launched outside LaunchServices?)")
		line("key window", panel.isKeyWindow ? "yes" : "no")
		line("can become key", panel.canBecomeKey ? "yes" : "NO — WRONG")
		line("frame", NSStringFromRect(panel.frame))
		line("first responder", String(describing: type(of: panel.firstResponder ?? panel)))
		line("in Dock", NSApp.activationPolicy() == .accessory ? "no (accessory)" : "YES — WRONG")

		report.section("agent")
		line("state", coordinator.runState.label)
		line("model", coordinator.activeModelDescription ?? "—")
		line("effort", coordinator.thinkingLevel ?? "—")
		line("items", coordinator.items.count)

		report.section("comandos")
		line("conhecidos", coordinator.availableCommands.count)
		line("locais", coordinator.availableCommands.filter { $0.source == .local }.count)

		report.section("shortcut")
		let hotKey = GlobalHotKeyController()
		line("ctrl+opt+space", hotKey.register {} ? "registered" : "FAILED")
		hotKey.unregister()

		report.section("omp")
		line("binary", OmpLocator.find()?.path ?? "NOT FOUND in PATH")

		if let outputPath, let view = panel.contentView {
			report.section("render")
			line("png", writePNG(of: view, to: URL(fileURLWithPath: outputPath)) ? outputPath : "FAILED")
		}

		report.emit()
		exit(0)
	}

	/// Accumulator so the report can be built before `NSApp.run()` and finished
	/// from inside it — an `inout [String]` cannot cross that boundary.
	@MainActor
	private final class Report {
		private var lines: [String] = []

		func section(_ title: String) { lines.append("[\(title)]") }

		lazy var line: (String, Any) -> Void = { [weak self] key, value in
			let label = key.padding(toLength: 22, withPad: " ", startingAt: 0)
			self?.lines.append("  \(label) \(value)")
		}

		func emit() { print(lines.joined(separator: "\n")) }
	}

	@MainActor
	private static func writePNG(of view: NSView, to url: URL) -> Bool {
		guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
		view.cacheDisplay(in: view.bounds, to: rep)
		guard let data = rep.representation(using: .png, properties: [:]) else { return false }
		return (try? data.write(to: url)) != nil
	}
}

/// Answers the boot handshake and replays a scripted turn, so diagnostics
/// exercise the same decoding and rendering path as a live session.
private final class PreviewTransport: OmpTransport, @unchecked Sendable {
	private let lock = NSLock()
	private var continuation: AsyncStream<OmpProcessEvent>.Continuation?
	private var running = false
	private(set) var launchedMode: AgentMode?

	var isRunning: Bool {
		lock.lock()
		defer { lock.unlock() }
		return running
	}

	func start(
		workspace: URL,
		apiKey: String?,
		mode: AgentMode
	) throws -> AsyncStream<OmpProcessEvent> {
		launchedMode = mode
		let (stream, continuation) = AsyncStream<OmpProcessEvent>.makeStream(bufferingPolicy: .unbounded)
		lock.lock()
		running = true
		self.continuation = continuation
		lock.unlock()
		emit("""
		{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1,2],\
		"maxFrameBytes":1048576,"maxReassembledFrameBytes":67108864}
		""")
		emit(Self.availableCommandsFrame)
		return stream
	}

	func send(_ command: RpcCommand, id: String?) throws {
		let identifier = id.map { "\"id\":\"\($0)\"," } ?? ""
		let model = """
		{"id":"\(AppConfiguration.primaryModelId)","name":"DeepSeek V4 Flash Free",\
		"provider":"\(AppConfiguration.providerId)","input":["text"],"contextWindow":200000,\
		"maxTokens":128000,"thinking":{"mode":"effort","efforts":["high","max"]}}
		"""
		switch command {
		case .negotiateProtocol:
			emit("""
			{\(identifier)"type":"response","command":"negotiate_protocol","success":true,\
			"data":{"protocolVersion":2}}
			""")
		case .getAvailableModels:
			emit("""
			{\(identifier)"type":"response","command":"get_available_models","success":true,\
			"data":{"models":[\(model)]}}
			""")
		case .setModel:
			emit("""
			{\(identifier)"type":"response","command":"set_model","success":true,"data":\(model)}
			""")
		case .getMessagesPage:
			emit("""
			{\(identifier)"type":"response","command":"get_messages_page","success":true,\
			"data":{"messages":[],"totalMessages":0}}
			""")
		case .getState:
			emit("""
			{\(identifier)"type":"response","command":"get_state","success":true,\
			"data":{"model":\(model),"isStreaming":false,"isCompacting":false,"sessionId":"diag",\
			"thinkingLevel":"\(AppConfiguration.thinkingLevel)","messageCount":0,\
			"queuedMessageCount":0,"todoPhases":[],"autoCompactionEnabled":true,\
			"fastModeEnabled":false,"fastModeActive":false,"tokensPerSecond":null,\
			"steeringMode":"one-at-a-time","followUpMode":"one-at-a-time","interruptMode":"immediate"}}
			""")
		case .extensionUIResponse:
			break
		default:
			emit("""
			{\(identifier)"type":"response","command":"\(command.commandType)","success":true}
			""")
		}
	}

	func enableChunkReassembly(maxReassembledBytes: Int) {}

	func stop() {
		lock.lock()
		running = false
		let continuation = self.continuation
		self.continuation = nil
		lock.unlock()
		continuation?.finish()
	}

	func stopImmediately() { stop() }

	func replayScriptedTurn(settle: Bool = true) {
		for json in Self.scriptedFrames { emit(json) }
		if settle { emit(#"{"type":"agent_end","messages":[],"isTerminal":true}"#) }
	}

	private func emit(_ json: String) {
		guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)) else { return }
		lock.lock()
		let continuation = self.continuation
		lock.unlock()
		continuation?.yield(.frame(RpcFrame.make(from: value)))
	}

	/// A slice of the real `available_commands_update` payload, so `--diagnose`
	/// renders the popup with the same shape a live session produces.
	private static let availableCommandsFrame = """
	{"type":"available_commands_update","commands":[\
	{"name":"compact","description":"Compact the conversation"},\
	{"name":"context","description":"Show context usage"},\
	{"name":"code-review","description":"Code review — local changes or GitHub PR"},\
	{"name":"cost-report","description":"Generate a local cost report"},\
	{"name":"computer","description":"Toggle computer use"},\
	{"name":"usage","description":"Show token usage"},\
	{"name":"model","description":"Show current model selection"},\
	{"name":"vision","description":"Toggle vision delegation"},\
	{"name":"tools","description":"Show available tools"},\
	{"name":"export","description":"Export session to HTML file"}]}
	"""

	private static let scriptedFrames: [String] = [
		#"{"type":"agent_start"}"#,
		#"{"type":"tool_execution_start","toolCallId":"t1","toolName":"grep","args":{"pattern":"AuthService"}}"#,
		"""
		{"type":"tool_execution_end","toolCallId":"t1","toolName":"grep",\
		"result":{"content":[{"type":"text","text":"src/auth/AuthService.swift:14"}]}}
		""",
		"""
		{"type":"tool_execution_start","toolCallId":"t2","toolName":"edit",\
		"args":{"path":"/Users/x/Dev/app/src/auth/AuthService.swift"}}
		""",
		"""
		{"type":"tool_execution_end","toolCallId":"t2","toolName":"edit",\
		"result":{"content":[{"type":"text","text":"@@ -14,7 +14,7 @@\\n func refresh() {\\n\
		-    if expiry < now {\\n+    if expiry <= now {\\n         renew()\\n     }\\n }"}]}}
		""",
		"""
		{"type":"message_update","message":{"role":"assistant"},\
		"assistantMessageEvent":{"type":"text_delta","delta":"O problema está em `AuthService.refresh()`: \
		a checagem de validade usava `<` em vez de `<=`, então um token que expira exatamente agora ainda \
		passava como válido.\\n\\n```swift\\nif expiry <= now { renew() }\\n```\\n\\nCorrigido — os testes de \
		sessão voltaram a passar."}}
		""",
	]
}
