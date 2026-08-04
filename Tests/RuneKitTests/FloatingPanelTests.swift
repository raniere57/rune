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
