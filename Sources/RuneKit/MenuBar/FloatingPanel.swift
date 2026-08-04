import AppKit
import SwiftUI

/// Spotlight-style panel: borderless, floating, no title bar, no Dock presence.
///
/// Closing only orders it out — the coordinator and any in-flight run live in
/// the app delegate, so hiding the panel never cancels work.
public final class FloatingPanel: NSPanel {
	/// Invoked for key equivalents the SwiftUI hierarchy should not own
	/// (`Esc`, `⌘K`, `⌘.`, `⌘C` with no selection).
	public var onKeyEquivalent: ((PanelShortcut) -> Bool)?

	public init(contentRect: NSRect) {
		super.init(
			contentRect: contentRect,
			styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
			backing: .buffered,
			defer: false
		)

		isFloatingPanel = true
		level = .floating
		// Follows the user across Spaces and shows over full-screen apps, like
		// Spotlight does.
		collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
		titleVisibility = .hidden
		titlebarAppearsTransparent = true
		isMovableByWindowBackground = true
		isOpaque = false
		backgroundColor = .clear
		hasShadow = true
		// Clicking away dismisses, matching the launcher metaphor.
		hidesOnDeactivate = true
		animationBehavior = .utilityWindow
		isReleasedWhenClosed = false
	}

	// A borderless panel refuses key status by default; the composer needs it.
	public override var canBecomeKey: Bool { true }
	public override var canBecomeMain: Bool { false }

	public override func cancelOperation(_ sender: Any?) {
		_ = onKeyEquivalent?(.escape)
	}

	public override func performKeyEquivalent(with event: NSEvent) -> Bool {
		guard event.modifierFlags.contains(.command) else {
			return super.performKeyEquivalent(with: event)
		}
		let characters = event.charactersIgnoringModifiers?.lowercased()
		let shortcut: PanelShortcut?
		switch characters {
		case "k": shortcut = .newSession
		case ".": shortcut = .abort
		case "c": shortcut = .copy
		default: shortcut = nil
		}
		if let shortcut, onKeyEquivalent?(shortcut) == true { return true }
		return super.performKeyEquivalent(with: event)
	}

	/// Centres horizontally and sits in the upper third of the screen holding
	/// the pointer, so the panel follows the display the user is looking at.
	public func positionOnActiveScreen() {
		let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
			?? NSScreen.main
		guard let visible = screen?.visibleFrame else { return }
		let size = frame.size
		let origin = NSPoint(
			x: visible.midX - size.width / 2,
			y: visible.maxY - visible.height / 3 - size.height / 2
		)
		setFrameOrigin(origin)
	}

	public func present() {
		positionOnActiveScreen()
		NSApp.activate(ignoringOtherApps: true)
		makeKeyAndOrderFront(nil)
	}

	public func dismiss() {
		orderOut(nil)
	}
}

public enum PanelShortcut: Sendable {
	case escape
	case newSession
	case abort
	case copy
}
