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

	/// Set while a modal dialog or a menu owns the interaction.
	///
	/// The panel dismisses itself when it stops being the key window, which is
	/// exactly what happens when `NSOpenPanel` or the conversation menu opens —
	/// without this the panel would vanish behind its own dialog.
	public var suppressesAutoDismiss = false

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
		// Deliberately NOT `hidesOnDeactivate`. That flag ties visibility to app
		// activation, and clicking an `NSStatusItem` does not activate the app —
		// so the panel got ordered front and hidden again in the same breath,
		// and only the (deferred) global shortcut appeared to work. Dismissal is
		// driven by losing key status instead, which is both the behaviour a
		// launcher actually wants and something this class controls.
		hidesOnDeactivate = false
		animationBehavior = .utilityWindow
		isReleasedWhenClosed = false
	}

	// A borderless panel refuses key status by default; the composer needs it.
	public override var canBecomeKey: Bool { true }
	public override var canBecomeMain: Bool { false }

	public override func cancelOperation(_ sender: Any?) {
		_ = onKeyEquivalent?(.escape)
	}

	/// Modifiers that distinguish one shortcut from another. Caps lock and the
	/// function key are excluded so they cannot break an exact match.
	private static let significantModifiers: NSEvent.ModifierFlags = [
		.command, .shift, .option, .control,
	]

	public override func performKeyEquivalent(with event: NSEvent) -> Bool {
		// Exact modifiers, not `contains(.command)`: matching loosely meant ⌘⌥C
		// or ⌘⌃K were swallowed here instead of reaching whoever owns them.
		let modifiers = event.modifierFlags.intersection(Self.significantModifiers)
		let characters = event.charactersIgnoringModifiers?.lowercased()
		let shortcut: PanelShortcut?
		switch (modifiers, characters) {
		case (.command, "k"): shortcut = .newSession
		case (.command, "."): shortcut = .abort
		// ⌘⇧C, not ⌘C. ⌘C has to keep meaning "copy the selection": the panel
		// cannot see a SwiftUI text selection (only an `NSTextView` one), so
		// hijacking it put the whole last answer on the clipboard whenever the
		// user had selected a fragment of the transcript.
		case ([.command, .shift], "c"): shortcut = .copyLastAnswer
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
		// `activate()` rather than the deprecated `activate(ignoringOtherApps:)`,
		// which macOS 14+ often refuses when the request comes from an app that
		// is not already frontmost — which is every status-item click.
		NSApp.activate()
		makeKeyAndOrderFront(nil)
	}

	public func dismiss() {
		orderOut(nil)
	}

	/// Clicking away closes the panel, matching the launcher metaphor.
	///
	/// The check is deferred by one run-loop pass because key status flickers
	/// during ordinary transitions — opening a menu, or the moment between
	/// ordering front and actually becoming key — and dismissing on that flicker
	/// would close the panel the user just opened.
	public override func resignKey() {
		super.resignKey()
		guard !suppressesAutoDismiss else { return }
		DispatchQueue.main.async { [weak self] in
			guard let self, self.isVisible, !self.isKeyWindow, !self.suppressesAutoDismiss else { return }
			self.dismiss()
		}
	}

	/// Runs `body` with auto-dismiss suspended, for modal pickers and menus.
	@discardableResult
	public func keepingVisible<T>(during body: () -> T) -> T {
		let previous = suppressesAutoDismiss
		suppressesAutoDismiss = true
		defer {
			// Restored on the next pass: the key-status change from closing the
			// dialog arrives after this scope returns.
			DispatchQueue.main.async { [weak self] in self?.suppressesAutoDismiss = previous }
		}
		return body()
	}
}

public enum PanelShortcut: Sendable, Equatable {
	case escape
	case newSession
	case abort
	case copyLastAnswer
}
