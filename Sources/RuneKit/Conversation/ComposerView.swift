import AppKit
import SwiftUI

/// Shared geometry for every control in the composer.
///
/// Centralised because the footer mixes capsules and squares from three
/// different views: without one source for height and spacing they drift apart
/// by a point or two and the row stops reading as a row.
enum ComposerMetrics {
	/// Every footer control is exactly this tall, so they share a centre line.
	static let controlHeight: CGFloat = 22
	static let iconSize: CGFloat = 10
	static let labelSize: CGFloat = 11
	/// Gap inside a group (chip to chip, button to button).
	static let innerGap: CGFloat = 6
	/// Gap between the left group and the right group.
	static let groupGap: CGFloat = 10
	static let buttonCornerRadius: CGFloat = 6
	/// Horizontal inset shared by the text view and the footer, so the left
	/// edge of the first chip lines up with the first character typed.
	static let horizontalInset: CGFloat = 4
}

/// The text input. Attachment chips ride above it; every other control lives in
/// `ComposerFooter`.
///
/// Backed by `NSTextView` rather than SwiftUI's `TextEditor` because the key
/// handling this needs — Enter to send, Shift+Enter for a newline, Tab for
/// completion and mode, and an intercepted `Cmd+V` — is not expressible with
/// the SwiftUI control.
struct ComposerView: View {
	@Binding var text: String
	let attachments: [PendingAttachment]
	let placeholder: String

	let onSubmit: () -> Void
	let onPaste: () -> Bool
	let onEscape: () -> Void
	/// Arrow keys drive the slash-command popup when it is open; returns
	/// `true` when the keystroke was consumed there.
	let onMoveSelection: (Int) -> Bool
	let onCompleteSuggestion: () -> Bool
	/// Tab falls through to this when no suggestion is open.
	let onToggleMode: () -> Bool
	let onRemoveAttachment: (PendingAttachment) -> Void

	@State private var height = AppConfiguration.composerMinHeight

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if !attachments.isEmpty {
				ScrollView(.horizontal, showsIndicators: false) {
					HStack(spacing: ComposerMetrics.innerGap) {
						ForEach(attachments) { attachment in
							AttachmentChip(summary: attachment.summary) {
								onRemoveAttachment(attachment)
							}
						}
					}
					.padding(.horizontal, ComposerMetrics.horizontalInset)
				}
				.frame(height: 24)
			}

			ZStack(alignment: .topLeading) {
				if text.isEmpty {
					Text(placeholder)
						.font(.system(size: 14))
						.foregroundStyle(.tertiary)
						.padding(.leading, ComposerMetrics.horizontalInset + 1)
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
					onCompleteSuggestion: onCompleteSuggestion,
					onToggleMode: onToggleMode
				)
				.frame(height: height)
				.padding(.leading, ComposerMetrics.horizontalInset)
			}
		}
	}
}

/// One row: context on the left, actions on the right.
///
/// Everything shares `ComposerMetrics.controlHeight` and one centre line. The
/// previous layout put send/abort beside the text and the chips on a separate
/// line below, which left two control rows with no common baseline — the
/// asymmetry was structural, not a spacing bug.
struct ComposerFooter: View {
	let mode: AgentMode
	let isModePending: Bool
	let isBusy: Bool
	let workspaceName: String
	let workspaceHelp: String
	let statusHint: String?
	let canSend: Bool
	/// Fraction of the model's context window in use, when it is high enough to
	/// matter.
	let contextPercent: Double?

	let onToggleMode: () -> Void
	let onChooseWorkspace: () -> Void
	let onChooseSession: () -> Void
	let onAbort: () -> Void
	let onSubmit: () -> Void

	var body: some View {
		HStack(spacing: ComposerMetrics.groupGap) {
			HStack(spacing: ComposerMetrics.innerGap) {
				ModePill(
					mode: mode,
					isPending: isModePending,
					isLocked: isBusy,
					onToggle: onToggleMode
				)

				StatusChip(symbol: "folder", label: workspaceName, help: workspaceHelp,
				           action: onChooseWorkspace)

				StatusChip(symbol: "bubble.left.and.bubble.right", label: "Conversas",
				           help: "Retomar uma conversa anterior ou começar outra",
				           action: onChooseSession)

				if let contextPercent, contextPercent >= Self.contextWarningPercent {
					ContextGauge(percent: contextPercent)
				}
			}

			if let statusHint {
				Text(statusHint)
					.font(.system(size: ComposerMetrics.labelSize))
					.foregroundStyle(.tertiary)
					.lineLimit(1)
					.truncationMode(.tail)
			}

			Spacer(minLength: ComposerMetrics.groupGap)

			HStack(spacing: ComposerMetrics.innerGap) {
				if isBusy {
					ComposerButton(symbol: "stop.fill", role: .abort,
					               help: "Abortar (⌘.)", action: onAbort)
						.transition(.opacity.combined(with: .scale(scale: 0.85)))
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
		}
		.frame(height: ComposerMetrics.controlHeight)
		.padding(.horizontal, ComposerMetrics.horizontalInset)
	}

	/// Below this the number is noise; above it the user should see compaction
	/// coming, because a full context degrades the answer silently.
	static let contextWarningPercent: Double = 60
	static let contextCriticalPercent: Double = 85
}

/// How much of the context window is spent. Rendered only past the warning
/// threshold, so the common case costs nothing and adds no clutter.
struct ContextGauge: View {
	let percent: Double

	var body: some View {
		Text("\(Int(percent.rounded()))% ctx")
			.font(.system(size: ComposerMetrics.labelSize, design: .rounded))
			.monospacedDigit()
			.foregroundStyle(tint)
			.help("Contexto usado — o `omp` compacta sozinho perto do limite")
			.accessibilityLabel("Contexto em \(Int(percent.rounded())) por cento")
	}

	private var tint: Color {
		percent >= ComposerFooter.contextCriticalPercent ? .orange : .secondary
	}
}

/// Square action button. Square rather than round so `stop.fill` reads as a
/// stop, and matched in height to the chips so the footer stays level.
struct ComposerButton: View {
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
				.font(.system(size: role == .abort ? 8 : 10, weight: .bold))
				.foregroundStyle(foreground)
				.frame(width: ComposerMetrics.controlHeight, height: ComposerMetrics.controlHeight)
				.background(
					background,
					in: RoundedRectangle(cornerRadius: ComposerMetrics.buttonCornerRadius, style: .continuous)
				)
				.overlay(
					RoundedRectangle(cornerRadius: ComposerMetrics.buttonCornerRadius, style: .continuous)
						.strokeBorder(PanelStyle.chipStroke(hovering: isHovering && isEnabled))
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
		guard isEnabled else { return .secondary.opacity(0.45) }
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

/// Current agent mode, and the affordance for `Tab`.
struct ModePill: View {
	let mode: AgentMode
	/// A live process is still running the previous mode; the switch lands on
	/// the next send.
	let isPending: Bool
	/// Mid-run the tool registry cannot change, so the control is inert.
	let isLocked: Bool
	let onToggle: () -> Void

	@State private var isHovering = false

	var body: some View {
		Button(action: onToggle) {
			HStack(spacing: 5) {
				// The glyph is the whole point: a keystroke nobody can see is a
				// keystroke nobody uses.
				Text("⇥")
					.font(.system(size: ComposerMetrics.iconSize, weight: .semibold))
					.foregroundStyle(.tertiary)
				Image(systemName: mode.symbol)
					.font(.system(size: ComposerMetrics.iconSize - 1, weight: .semibold))
				Text(mode.label)
					.font(.system(size: ComposerMetrics.labelSize, weight: .medium))
				if isPending {
					Circle().fill(.orange).frame(width: 4, height: 4)
				}
			}
			.foregroundStyle(isLocked ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
			.padding(.horizontal, 8)
			.frame(height: ComposerMetrics.controlHeight)
			.background(
				(isLocked ? Color.clear : tint.opacity(isHovering ? 0.20 : 0.12)),
				in: Capsule()
			)
			.overlay(Capsule().strokeBorder(tint.opacity(isLocked ? 0.15 : 0.30)))
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.disabled(isLocked)
		.help(helpText)
		.accessibilityLabel("Modo \(mode.label). \(mode.summary)")
		.fixedSize()
		.onHover { isHovering = $0 }
		.animation(.easeOut(duration: 0.12), value: isHovering)
		.animation(.easeOut(duration: 0.12), value: mode)
	}

	private var tint: Color {
		mode == .plan ? .teal : .accentColor
	}

	private var helpText: String {
		if isLocked { return "Termine ou aborte a execução para trocar de modo" }
		if isPending { return "\(mode.summary) — o omp reinicia no próximo envio (⇥)" }
		return "\(mode.summary) — ⇥ alterna"
	}
}

/// Labelled control in the footer's left group.
struct StatusChip: View {
	let symbol: String
	let label: String
	let help: String
	let action: () -> Void

	@State private var isHovering = false

	var body: some View {
		Button(action: action) {
			HStack(spacing: 5) {
				Image(systemName: symbol)
					.font(.system(size: ComposerMetrics.iconSize - 1, weight: .medium))
				Text(label)
					.font(.system(size: ComposerMetrics.labelSize))
					.lineLimit(1)
					.truncationMode(.middle)
					// Capped on the label alone: a frame on the whole chip would
					// stretch it to the cap and scatter the row.
					.frame(maxWidth: 140)
					.fixedSize()
			}
			.foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
			.padding(.horizontal, 8)
			.frame(height: ComposerMetrics.controlHeight)
			.background(PanelStyle.chipFill(hovering: isHovering), in: Capsule())
			.overlay(Capsule().strokeBorder(PanelStyle.chipStroke(hovering: isHovering)))
			.contentShape(Capsule())
		}
		.buttonStyle(.plain)
		.help(help)
		.accessibilityLabel(help)
		.fixedSize()
		.onHover { isHovering = $0 }
		.animation(.easeOut(duration: 0.12), value: isHovering)
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
	let onToggleMode: () -> Bool

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> NSScrollView {
		let textView = InterceptingTextView()
		textView.delegate = context.coordinator
		textView.onSubmit = onSubmit
		textView.onPaste = onPaste
		textView.onEscape = onEscape
		textView.onMoveSelection = onMoveSelection
		textView.onCompleteSuggestion = onCompleteSuggestion
		textView.onToggleMode = onToggleMode
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
		textView.onToggleMode = onToggleMode
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
	var onToggleMode: (() -> Bool)?

	/// Claims focus as soon as the view has a window. `makeNSView` runs before
	/// the panel is ordered front, so asking for first responder there would
	/// target a nil window and the composer would open unfocused.
	override func viewDidMoveToWindow() {
		super.viewDidMoveToWindow()
		guard let window else { return }
		DispatchQueue.main.async { window.makeFirstResponder(self) }
	}

	/// Splits Shift+Return off from a bare Return before the key bindings do.
	///
	/// AppKit's `StandardKeyBinding.dict` has no entry for Shift+Return: it
	/// resolves to the same `insertNewline:` as a plain Return, so by the time
	/// `doCommand(by:)` runs the modifier is gone and every line break looked
	/// like a send. `insertNewlineIgnoringFieldEditor:` is bound to *Option*
	/// +Return (`~\r`), not Shift — which is why routing it there did nothing.
	override func keyDown(with event: NSEvent) {
		// While an input method has marked text — a CJK candidate being composed —
		// every key belongs to the IME, and Return is how the candidate is
		// committed. Intercepting it here would insert a line break into the
		// middle of the composition instead.
		if hasMarkedText() {
			super.keyDown(with: event)
			return
		}
		if event.isReturnKey, event.modifierFlags.contains(.shift) {
			super.insertNewline(self)
			return
		}
		super.keyDown(with: event)
	}

	override func doCommand(by selector: Selector) {
		switch selector {
		case #selector(insertNewline(_:)):
			onSubmit?()
		case #selector(cancelOperation(_:)):
			onEscape?()
		case #selector(insertNewlineIgnoringFieldEditor(_:)):
			// Option+Enter, the other way to get a line break.
			super.insertNewline(self)
		case #selector(moveUp(_:)):
			// Only steal the arrows while the popup is open; otherwise they
			// must still move the caret through a multi-line draft.
			if onMoveSelection?(-1) != true { super.doCommand(by: selector) }
		case #selector(moveDown(_:)):
			if onMoveSelection?(1) != true { super.doCommand(by: selector) }
		case #selector(insertTab(_:)), #selector(insertBacktab(_:)):
			// Tab completes the open suggestion first; with no popup it toggles
			// plan/build, the way OpenCode's mode switch works. A literal tab
			// character in a prompt is not worth a third meaning.
			if onCompleteSuggestion?() == true { return }
			if onToggleMode?() == true { return }
			super.doCommand(by: selector)
		default:
			super.doCommand(by: selector)
		}
	}

	override func paste(_ sender: Any?) {
		if onPaste?() == true { return }
		pasteAsPlainText(sender)
	}
}

extension NSEvent {
	/// True for Return and for the keypad's Enter (which reports `\u{3}`).
	var isReturnKey: Bool {
		guard let characters = charactersIgnoringModifiers else { return false }
		return characters == "\r" || characters == "\n" || characters == "\u{3}"
	}
}
