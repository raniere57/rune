import AppKit
import Observation
import SwiftUI
import os

/// Wires the menu bar item, the floating panel, and the global shortcut to a
/// single long-lived `AgentCoordinator`.
///
/// The coordinator outlives the panel on purpose: dismissing the window must
/// never cancel a run.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
	private let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "lifecycle")

	private let coordinator = AgentCoordinator()
	private lazy var composer = ComposerModel(coordinator: coordinator)
	private let statusItem = StatusItemController()
	private let hotKey = GlobalHotKeyController()

	private var panel: FloatingPanel?
	private var stateObservation: Task<Void, Never>?

	func applicationDidFinishLaunching(_ notification: Notification) {
		// Must come before the panel exists: without a main menu the standard
		// edit key equivalents have no responder and every ⌘ keystroke beeps.
		AppMenu.install()

		composer.onDismiss = { [weak self] in self?.hidePanel() }

		statusItem.onToggle = { [weak self] in self?.togglePanel() }
		statusItem.onNewSession = { [weak self] in
			guard let self else { return }
			Task { await self.coordinator.startNewSession() }
		}
		statusItem.onQuit = { NSApp.terminate(nil) }
		statusItem.statusProvider = { [weak self] in
			guard let self else { return "" }
			return "\(self.coordinator.runState.label) · \(self.coordinator.workspace.displayName)"
		}

		if !hotKey.register(onTrigger: { [weak self] in self?.togglePanel() }) {
			logger.error("global shortcut registration failed; menu bar click still works")
		}

		observeRunState()
		logger.info("\(AppConfiguration.appName, privacy: .public) ready")
	}

	func applicationWillTerminate(_ notification: Notification) {
		// Stop OMP synchronously so no child survives the app. Even a SIGKILL
		// here would be safe — closing our end of the pipe gives OMP stdin EOF,
		// which is its documented clean-exit path — but an explicit stop makes
		// the common case immediate.
		stateObservation?.cancel()
		hotKey.unregister()
		coordinator.shutdownForAppExit()
	}

	// MARK: - Panel

	private func togglePanel() {
		let panel = ensurePanel()
		if panel.isVisible, panel.isKeyWindow {
			hidePanel()
		} else {
			showPanel(panel)
		}
	}

	private func showPanel(_ panel: FloatingPanel) {
		panel.present()
		// On the first show the text view claims focus from
		// `viewDidMoveToWindow`; on every later show the view already has its
		// window, so focus is restored explicitly here.
		if let field = panel.contentView.flatMap(Self.firstTextView) {
			panel.makeFirstResponder(field)
		}
	}

	private static func firstTextView(in view: NSView) -> NSTextView? {
		if let textView = view as? InterceptingTextView { return textView }
		for subview in view.subviews {
			if let found = firstTextView(in: subview) { return found }
		}
		return nil
	}

	private func hidePanel() {
		panel?.dismiss()
	}

	private func ensurePanel() -> FloatingPanel {
		if let panel { return panel }

		let root = ConversationView(coordinator: coordinator, composer: composer)
		let hosting = NSHostingController(rootView: root)
		// `.preferredContentSize` makes AppKit resize the window to SwiftUI's
		// ideal height on every content change — the panel grows with the
		// transcript and shrinks back after ⌘K. Reading `fittingSize` once at
		// construction would size the panel before SwiftUI has laid out, which
		// yields a zero-height (invisible) window.
		hosting.sizingOptions = [.preferredContentSize]

		let panel = FloatingPanel(contentRect: NSRect(
			x: 0,
			y: 0,
			width: AppConfiguration.panelWidth,
			height: AppConfiguration.composerMinHeight + 34
		))
		panel.contentViewController = hosting
		panel.onKeyEquivalent = { [weak self] shortcut in
			self?.handle(shortcut) ?? false
		}
		self.panel = panel
		return panel
	}

	// MARK: - Shortcuts

	private func handle(_ shortcut: PanelShortcut) -> Bool {
		switch shortcut {
		case .escape:
			hidePanel()
			return true

		case .newSession:
			// Only confirm when there is context worth losing.
			if coordinator.hasConversation, !confirmNewSession() { return true }
			composer.clear()
			Task { await coordinator.startNewSession() }
			return true

		case .abort:
			Task { await coordinator.abort() }
			return true

		case .copy:
			// Only hijack ⌘C when nothing is selected; otherwise the normal
			// copy must win.
			guard !hasSelection(), let text = coordinator.lastAssistantText else { return false }
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(text, forType: .string)
			return true
		}
	}

	private func hasSelection() -> Bool {
		guard let responder = panel?.firstResponder as? NSTextView else { return false }
		return responder.selectedRange().length > 0
	}

	private func confirmNewSession() -> Bool {
		let alert = NSAlert()
		alert.messageText = "Iniciar nova conversa?"
		alert.informativeText = "O histórico atual sai da tela e a sessão do OMP é reiniciada."
		alert.alertStyle = .warning
		alert.addButton(withTitle: "Nova conversa")
		alert.addButton(withTitle: "Cancelar")
		return alert.runModal() == .alertFirstButtonReturn
	}

	// MARK: - State mirroring

	/// Mirrors run state into the menu bar icon. Driven by Observation's change
	/// tracking rather than a polling timer, so an idle app schedules no work.
	private func observeRunState() {
		statusItem.update(state: coordinator.runState)
		scheduleRunStateObservation()
	}

	private func scheduleRunStateObservation() {
		withObservationTracking {
			_ = coordinator.runState
		} onChange: {
			Task { @MainActor [weak self] in
				guard let self else { return }
				self.statusItem.update(state: self.coordinator.runState)
				self.scheduleRunStateObservation()
			}
		}
	}
}
