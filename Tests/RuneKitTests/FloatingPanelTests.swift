import AppKit
import Testing

@testable import RuneKit

@MainActor
@Suite("Floating panel")
struct FloatingPanelTests {
	private func makePanel() -> FloatingPanel {
		FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 80))
	}

	@Test("hidesOnDeactivate stays off — it is what broke the menu bar click")
	func doesNotHideOnDeactivate() {
		// Clicking an `NSStatusItem` does not activate the app. With this flag on,
		// AppKit ordered the panel out in the same run-loop pass that ordered it
		// in, so only the global shortcut appeared to work.
		#expect(makePanel().hidesOnDeactivate == false)
	}

	@Test("the panel can take key status, so the composer can receive typing")
	func canBecomeKey() {
		let panel = makePanel()
		#expect(panel.canBecomeKey)
		#expect(!panel.canBecomeMain)
	}

	@Test("it floats above ordinary windows and follows the user across Spaces")
	func windowLevelAndBehaviour() {
		let panel = makePanel()
		#expect(panel.level == .floating)
		#expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
		#expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
	}

	@Test("auto-dismiss is armed by default")
	func autoDismissDefaultsOn() {
		#expect(makePanel().suppressesAutoDismiss == false)
	}

	@Test("keepingVisible suspends auto-dismiss for the duration of a dialog")
	func keepingVisibleSuspends() {
		let panel = makePanel()
		var observed = false
		panel.keepingVisible { observed = panel.suppressesAutoDismiss }
		#expect(observed, "a dialog must run with auto-dismiss suspended")
	}

	@Test("keepingVisible returns what the body produced")
	func keepingVisiblePassesThroughResult() {
		#expect(makePanel().keepingVisible { 42 } == 42)
	}

	// MARK: - Key equivalents

	private func keyEvent(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: modifiers,
			timestamp: 0,
			windowNumber: 0,
			context: nil,
			characters: character,
			charactersIgnoringModifiers: character,
			isARepeat: false,
			keyCode: 8
		)!
	}

	/// Returns the shortcut the panel resolved, or nil when it claimed nothing.
	private func resolve(_ character: String, _ modifiers: NSEvent.ModifierFlags) -> PanelShortcut? {
		let panel = makePanel()
		var seen: PanelShortcut?
		panel.onKeyEquivalent = { shortcut in
			seen = shortcut
			return true
		}
		_ = panel.performKeyEquivalent(with: keyEvent(character, modifiers))
		return seen
	}

	@Test("⌘C is left to the system, so a transcript selection still copies itself")
	func plainCommandCIsNotHijacked() {
		// The panel can only see an `NSTextView` selection; SwiftUI's own
		// `.textSelection` is invisible to it. Claiming ⌘C therefore replaced a
		// selected fragment with the whole last answer.
		#expect(resolve("c", .command) == nil)
	}

	@Test("⌘⇧C copies the last answer")
	func shiftCommandCCopiesLastAnswer() {
		#expect(resolve("c", [.command, .shift]) == .copyLastAnswer)
	}

	@Test("extra modifiers do not match — ⌘⌥K belongs to whoever else wants it")
	func modifiersMustMatchExactly() {
		#expect(resolve("k", .command) == .newSession)
		#expect(resolve("k", [.command, .option]) == nil)
		#expect(resolve("k", [.command, .control]) == nil)
	}

	@Test("caps lock does not break an otherwise exact match")
	func capsLockIsIgnored() {
		#expect(resolve("k", [.command, .capsLock]) == .newSession)
	}

	@Test("positioning lands in the upper third of a screen, horizontally centred")
	func positioning() throws {
		let screen = try #require(NSScreen.main)
		let panel = makePanel()
		panel.positionOnActiveScreen()

		let visible = screen.visibleFrame
		// Only assert when the pointer is on the main screen; otherwise the panel
		// legitimately positioned itself somewhere else.
		guard visible.contains(NSEvent.mouseLocation) || NSScreen.screens.count == 1 else { return }
		#expect(abs(panel.frame.midX - visible.midX) < 2)
		#expect(panel.frame.midY > visible.midY)
	}
}
