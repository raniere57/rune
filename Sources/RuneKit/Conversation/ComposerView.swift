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
	let onAbort: () -> Void
	let onPaste: () -> Bool
	let onEscape: () -> Void
	/// Arrow keys drive the slash-command popup when it is open; returns
	/// `true` when the keystroke was consumed there.
	let onMoveSelection: (Int) -> Bool
	let onCompleteSuggestion: () -> Bool
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
						onEscape: onEscape,
						onMoveSelection: onMoveSelection,
						onCompleteSuggestion: onCompleteSuggestion
					)
					.frame(height: height)
				}

				HStack(spacing: 6) {
					// Abort only exists while there is something to abort, so
					// the composer stays a single control when idle.
					if isBusy {
						ComposerButton(
							symbol: "stop.fill",
							role: .abort,
							help: "Abortar (⌘.)",
							action: onAbort
						)
						.transition(.opacity.combined(with: .scale(scale: 0.8)))
					}

					ComposerButton(
						symbol: "arrow.up",
						role: .send,
						help: isBusy ? "Enviar como correção (Enter)" : "Enviar (Enter)",
						isEnabled: canSend,
						action: onSubmit
					)
				}
				.animation(.easeOut(duration: 0.15), value: isBusy)
				.padding(.bottom, 3)
			}
		}
	}

	private var canSend: Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
	}
}

/// Small square action button.
///
/// Square rather than round on purpose: `stop.fill` reads as "stop" only when
/// the container does not fight the glyph, and matching the send button's shape
/// keeps the pair reading as one control group.
private struct ComposerButton: View {
	enum Role {
		case send
		case abort
	}

	let symbol: String
	let role: Role
	let help: String
	var isEnabled = true
	let action: () -> Void

	@State private var isHovering = false
	@State private var isPressed = false

	var body: some View {
		Button(action: action) {
			Image(systemName: symbol)
				.font(.system(size: role == .abort ? 9 : 11, weight: .bold))
				.foregroundStyle(foreground)
				.frame(width: 24, height: 24)
				.background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
				.overlay(
					RoundedRectangle(cornerRadius: 6, style: .continuous)
						.strokeBorder(.white.opacity(isHovering && isEnabled ? 0.18 : 0.07))
				)
				.scaleEffect(isPressed ? 0.9 : 1)
		}
		.buttonStyle(.plain)
		.disabled(!isEnabled)
		.help(help)
		.accessibilityLabel(help)
		.onHover { isHovering = $0 }
		.animation(.easeOut(duration: 0.12), value: isHovering)
		.animation(.easeOut(duration: 0.08), value: isPressed)
		// `onLongPressGesture` with a zero minimum duration is the cheapest way
		// to get a real pressed state out of a `.plain` button.
		.onLongPressGesture(minimumDuration: 0, pressing: { isPressed = $0 }, perform: {})
	}

	private var foreground: Color {
		guard isEnabled else { return .secondary.opacity(0.5) }
		switch role {
		case .send: return isHovering ? .white : .primary
		case .abort: return .red
		}
	}

	private var background: Color {
		guard isEnabled else { return .clear }
		switch role {
		case .send: return isHovering ? .accentColor : .primary.opacity(0.10)
		case .abort: return .red.opacity(isHovering ? 0.22 : 0.12)
		}
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
	let onMoveSelection: (Int) -> Bool
	let onCompleteSuggestion: () -> Bool

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let textView = InterceptingTextView()
		textView.delegate = context.coordinator
		textView.onSubmit = onSubmit
		textView.onPaste = onPaste
		textView.onEscape = onEscape
		textView.onMoveSelection = onMoveSelection
		textView.onCompleteSuggestion = onCompleteSuggestion
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
		textView.onMoveSelection = onMoveSelection
		textView.onCompleteSuggestion = onCompleteSuggestion
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
	var onMoveSelection: ((Int) -> Bool)?
	var onCompleteSuggestion: (() -> Bool)?

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
		case #selector(moveUp(_:)):
			// Only steal the arrows while the popup is open; otherwise they
			// must still move the caret through a multi-line draft.
			if onMoveSelection?(-1) != true { super.doCommand(by: selector) }
		case #selector(moveDown(_:)):
			if onMoveSelection?(1) != true { super.doCommand(by: selector) }
		case #selector(insertTab(_:)):
			if onCompleteSuggestion?() != true { super.doCommand(by: selector) }
		default:
			super.doCommand(by: selector)
		}
	}

	override func paste(_ sender: Any?) {
		if onPaste?() == true { return }
		pasteAsPlainText(sender)
	}
}
