import AppKit
import Testing

@testable import RuneKit

@MainActor
@Suite("Composer key handling")
struct ComposerKeyTests {
	private func makeTextView() -> InterceptingTextView {
		InterceptingTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
	}

	private func returnEvent(shift: Bool, keyCode: UInt16 = 36, characters: String = "\r") -> NSEvent {
		NSEvent.keyEvent(
			with: .keyDown,
			location: .zero,
			modifierFlags: shift ? [.shift] : [],
			timestamp: 0,
			windowNumber: 0,
			context: nil,
			characters: characters,
			charactersIgnoringModifiers: characters,
			isARepeat: false,
			keyCode: keyCode
		)!
	}

	@Test("Shift+Return inserts a line break instead of sending")
	func shiftReturnInsertsNewline() {
		let textView = makeTextView()
		var submitted = false
		textView.onSubmit = { submitted = true }
		textView.string = "primeira"
		textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

		textView.keyDown(with: returnEvent(shift: true))

		#expect(textView.string == "primeira\n")
		#expect(!submitted)
	}

	@Test("Shift plus the keypad's Enter behaves the same")
	func shiftKeypadEnterInsertsNewline() {
		let textView = makeTextView()
		var submitted = false
		textView.onSubmit = { submitted = true }

		textView.keyDown(with: returnEvent(shift: true, keyCode: 76, characters: "\u{3}"))

		#expect(textView.string == "\n")
		#expect(!submitted)
	}

	@Test("a bare Return still sends")
	func plainReturnSubmits() {
		let textView = makeTextView()
		var submitted = false
		textView.onSubmit = { submitted = true }
		textView.string = "pergunta"

		// The bare key press reaches `doCommand(by:)` through the input context,
		// which needs a window; the selector is asserted directly instead.
		textView.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewline(_:)))

		#expect(submitted)
		#expect(textView.string == "pergunta")
	}

	@Test("Option+Return also inserts a line break")
	func optionReturnInsertsNewline() {
		let textView = makeTextView()
		var submitted = false
		textView.onSubmit = { submitted = true }
		textView.string = "linha"
		textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))

		textView.doCommand(by: #selector(NSStandardKeyBindingResponding.insertNewlineIgnoringFieldEditor(_:)))

		#expect(textView.string == "linha\n")
		#expect(!submitted)
	}

	@Test("Shift is only special on Return — other keys keep their normal path")
	func shiftOnOtherKeysIsNotIntercepted() {
		#expect(!returnEvent(shift: true, keyCode: 0, characters: "a").isReturnKey)
		#expect(returnEvent(shift: false).isReturnKey)
	}
}
