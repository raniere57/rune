import AppKit
import SwiftUI

/// The only input surface: a text view plus attachment chips.
///
/// Backed by `NSTextView` rather than SwiftUI's `TextEditor` because the key
/// handling this needs — Enter to send, Shift+Enter for a newline, and an
/// intercepted `Cmd+V` — is not expressible with the SwiftUI control.
struct ComposerView: View {
	@Binding var text: String
	let attachments: [PendingAttachment]
	let placeholder: String
	let isBusy: Bool

	let onSubmit: () -> Void
	let onPaste: () -> Bool
	let onEscape: () -> Void
	let onRemoveAttachment: (PendingAttachment) -> Void

	@State private var height = AppConfiguration.composerMinHeight

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			if !attachments.isEmpty {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: 6) {
						ForEach(attachments) { attachment in
							AttachmentChip(summary: attachment.summary) {
								onRemoveAttachment(attachment)
							}
						}
					}
					.padding(.horizontal, 2)
				}
				.frame(height: 26)
			}

			HStack(alignment: .bottom, spacing: 8) {
				ZStack(alignment: .topLeading) {
					if text.isEmpty {
						Text(placeholder)
							.font(.system(size: 14))
							.foregroundStyle(.tertiary)
							.padding(.leading, 5)
							.padding(.top, 3)
							.allowsHitTesting(false)
					}
					ComposerTextView(
						text: $text,
						height: $height,
						onSubmit: onSubmit,
						onPaste: onPaste,
						onEscape: onEscape
					)
					.frame(height: height)
				}

				SubmitHint(isBusy: isBusy)
			}
		}
	}
}

private struct SubmitHint: View {
	let isBusy: Bool

	var body: some View {
		Group {
			if isBusy {
				ProgressView().controlSize(.small).scaleEffect(0.7)
			} else {
				Image(systemName: "return")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.tertiary)
			}
		}
		.frame(width: 20, height: 20)
		.padding(.bottom, 4)
	}
}

// MARK: - NSTextView bridge

private struct ComposerTextView: NSViewRepresentable {
	@Binding var text: String
	@Binding var height: CGFloat
	let onSubmit: () -> Void
	/// Returns `true` when the paste was consumed (image or file), `false` to
	/// let the text view insert plain text normally.
	let onPaste: () -> Bool
	let onEscape: () -> Void

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let textView = InterceptingTextView()
		textView.delegate = context.coordinator
		textView.onSubmit = onSubmit
		textView.onPaste = onPaste
		textView.onEscape = onEscape
		textView.font = .systemFont(ofSize: 14)
		textView.isRichText = false
		textView.allowsUndo = true
		textView.drawsBackground = false
		textView.textContainerInset = NSSize(width: 2, height: 3)
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.textContainer?.widthTracksTextView = true
		textView.autoresizingMask = [.width]

		let scrollView = NSScrollView()
		scrollView.documentView = textView
		scrollView.drawsBackground = false
		scrollView.hasVerticalScroller = false
		scrollView.verticalScrollElasticity = .none

		return scrollView
	}

	func updateNSView(_ scrollView: NSScrollView, context: Context) {
		guard let textView = scrollView.documentView as? InterceptingTextView else { return }
		textView.onSubmit = onSubmit
		textView.onPaste = onPaste
		textView.onEscape = onEscape
		if textView.string != text {
			let wasCleared = text.isEmpty && !textView.string.isEmpty
			textView.string = text
			// After a submit the undo history is stale anyway, and for `/key`
			// it would hold the secret — a ⌘Z would put it back on screen.
			if wasCleared { textView.undoManager?.removeAllActions() }
			context.coordinator.recomputeHeight(for: textView)
		}
	}

	// AppKit delivers text-view delegate callbacks on the main thread; the
	// annotation makes that contract explicit instead of leaving the
	// `parent.height` writes unchecked.
	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		private let parent: ComposerTextView

		init(_ parent: ComposerTextView) {
			self.parent = parent
		}

		func textDidChange(_ notification: Notification) {
			guard let textView = notification.object as? NSTextView else { return }
			parent.text = textView.string
			recomputeHeight(for: textView)
		}

		/// Grows with the content up to a ceiling, then scrolls — so a long
		/// paste cannot push the composer off screen.
		func recomputeHeight(for textView: NSTextView) {
			guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
			layoutManager.ensureLayout(for: container)
			let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
			let clamped = min(
				max(used, AppConfiguration.composerMinHeight),
				AppConfiguration.composerMaxHeight
			)
			guard abs(clamped - parent.height) > 0.5 else { return }
			parent.height = clamped
		}
	}
}

/// `NSTextView` that routes Enter, Esc, and `Cmd+V` to the host before the
/// default editing behaviour.
final class InterceptingTextView: NSTextView {
	var onSubmit: (() -> Void)?
	var onPaste: (() -> Bool)?
	var onEscape: (() -> Void)?

	/// Claims focus as soon as the view has a window. `makeNSView` runs before
	/// the panel is ordered front, so asking for first responder there would
	/// target a nil window and the composer would open unfocused.
	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard let window else { return }
		DispatchQueue.main.async { window.makeFirstResponder(self) }
	}

	override func doCommand(by selector: Selector) {
		switch selector {
		case #selector(insertNewline(_:)):
			onSubmit?()
		case #selector(cancelOperation(_:)):
			onEscape?()
		case #selector(insertNewlineIgnoringFieldEditor(_:)):
			// Shift+Enter — the one path that actually inserts a line break.
			super.insertNewline(self)
		default:
			super.doCommand(by: selector)
		}
	}

	override func paste(_ sender: Any?) {
		if onPaste?() == true { return }
		pasteAsPlainText(sender)
	}
}
