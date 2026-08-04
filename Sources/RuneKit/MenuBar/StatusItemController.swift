import AppKit
import os

/// The menu bar presence.
///
/// A left click toggles the panel directly (no menu in the way); a right click
/// opens the only menu in the app, which exists so the workspace, shortcut, and
/// quit are discoverable without a settings screen.
@MainActor
public final class StatusItemController {
	private let statusItem: NSStatusItem
	private let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "ui")

	public var onToggle: (() -> Void)?
	public var onNewSession: (() -> Void)?
	public var onQuit: (() -> Void)?
	public var statusProvider: (() -> String)?

	public init() {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
		configureButton()
	}

	// Read by `--diagnose`, which has no other way to confirm the item was
	// actually placed in the menu bar.
	public var hasButton: Bool { statusItem.button != nil }
	public var hasImage: Bool { statusItem.button?.image != nil }
	public var isVisible: Bool { statusItem.isVisible }

	private func configureButton() {
		guard let button = statusItem.button else { return }
		button.image = MenuBarIcon.shared
		button.target = self
		button.action = #selector(handleClick)
		button.sendAction(on: [.leftMouseUp, .rightMouseUp])
	}

	/// Reflects run state in the icon so the user can tell at a glance whether
	/// the agent is working, without opening the panel. Idle shows the app's
	/// own mark; active states borrow SF Symbols, which read faster than a
	/// badge on a 16pt glyph.
	public func update(state: AgentRunState) {
		guard let button = statusItem.button else { return }
		let symbol: String?
		switch state {
		case .stopped, .ready: symbol = nil
		case .starting: symbol = "circle.dotted"
		case .thinking, .compacting: symbol = "sparkles"
		case .usingTool: symbol = "wrench.and.screwdriver"
		case .aborting: symbol = "stop.circle"
		case .failed: symbol = "exclamationmark.triangle"
		}

		if let symbol,
		   let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label) {
			image.isTemplate = true
			button.image = image
		} else {
			button.image = MenuBarIcon.shared
		}
		button.toolTip = "\(AppConfiguration.versionedName) — \(state.label)"
	}

	@objc private func handleClick() {
		let event = NSApp.currentEvent
		let wantsMenu = event?.type == .rightMouseUp
			|| event?.modifierFlags.contains(.control) == true

		guard !wantsMenu else {
			showMenu()
			return
		}

		// Deferred one run-loop pass: this action fires from inside the status
		// button's mouse tracking, and presenting a window there races the
		// activation the panel needs. The global shortcut path always hopped
		// through the main queue, which is the only reason it appeared to work
		// when the click did not.
		DispatchQueue.main.async { [weak self] in self?.onToggle?() }
	}

	private func showMenu() {
		let menu = NSMenu()

		let version = NSMenuItem(title: AppConfiguration.versionedName, action: nil, keyEquivalent: "")
		version.isEnabled = false
		menu.addItem(version)

		let status = NSMenuItem(title: statusProvider?() ?? "", action: nil, keyEquivalent: "")
		status.isEnabled = false
		menu.addItem(status)
		menu.addItem(.separator())

		let newSession = NSMenuItem(
			title: "Nova conversa",
			action: #selector(triggerNewSession),
			keyEquivalent: "k"
		)
		newSession.target = self
		menu.addItem(newSession)

		let toggle = NSMenuItem(title: "Abrir painel", action: #selector(triggerToggle), keyEquivalent: "")
		toggle.target = self
		menu.addItem(toggle)

		menu.addItem(.separator())
		let quit = NSMenuItem(title: "Sair", action: #selector(triggerQuit), keyEquivalent: "q")
		quit.target = self
		menu.addItem(quit)

		statusItem.menu = menu
		statusItem.button?.performClick(nil)
		// The menu is transient: leaving it attached would swallow left clicks.
		statusItem.menu = nil
	}

	@objc private func triggerToggle() { onToggle?() }
	@objc private func triggerNewSession() { onNewSession?() }
	@objc private func triggerQuit() { onQuit?() }
}
