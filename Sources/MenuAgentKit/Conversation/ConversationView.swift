import AppKit
import SwiftUI

/// Root panel content: history above, composer below, nothing else.
///
/// No sidebar, tabs, file tree, editor, terminal, dashboard, model picker,
/// settings, toolbar, or attach button — every affordance is a keystroke or a
/// slash command.
public struct ConversationView: View {
	@Bindable var coordinator: AgentCoordinator
	@Bindable var composer: ComposerModel

	public init(coordinator: AgentCoordinator, composer: ComposerModel) {
		self.coordinator = coordinator
		self.composer = composer
	}

	public var body: some View {
		VStack(spacing: 0) {
			if coordinator.hasConversation {
				history
				Divider().opacity(0.5)
			}
			composerSection
		}
		// Fixed width: the panel is borderless, so nothing else constrains the
		// horizontal axis and SwiftUI would otherwise collapse to its content.
		.frame(width: AppConfiguration.panelWidth)
		.background(.ultraThinMaterial)
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.strokeBorder(.white.opacity(0.10))
		)
	}

	private var history: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 12) {
					ForEach(coordinator.items) { item in
						row(for: item).id(item.id)
					}
					// Anchor for auto-scroll; scrolling to the last item would
					// stop short while its text is still growing.
					Color.clear.frame(height: 1).id(Self.bottomAnchor)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 14)
			}
			.frame(maxHeight: AppConfiguration.historyMaxHeight)
			.onChange(of: coordinator.items.count) {
				withAnimation(.easeOut(duration: 0.15)) {
					proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
				}
			}
			.onChange(of: streamingSignature) {
				proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
			}
		}
	}

	@ViewBuilder
	private func row(for item: ConversationItem) -> some View {
		switch item {
		case .user(let turn):
			UserMessageView(turn: turn)
		case .assistant(let turn):
			AssistantMessageView(turn: turn)
		case .tool(let activity):
			ToolCallView(activity: activity)
		case .notice(let entry):
			NoticeView(entry: entry)
		case .failure(let entry):
			FailureView(entry: entry)
		case .request(let pending):
			ExtensionRequestView(pending: pending) { answer in
				coordinator.answer(requestId: pending.id, with: answer)
			}
		}
	}

	private var composerSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			ComposerView(
				text: $composer.text,
				attachments: composer.attachments,
				placeholder: placeholder,
				isBusy: coordinator.isBusy,
				onSubmit: { composer.submit() },
				onPaste: { composer.handlePaste() },
				onEscape: { composer.dismiss() },
				onRemoveAttachment: { composer.remove($0) }
			)

			if let hint = statusHint {
				Text(hint)
					.font(.system(size: 11))
					.foregroundStyle(.tertiary)
					.lineLimit(1)
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 11)
	}

	private var placeholder: String {
		coordinator.hasConversation ? "Continue…" : "Escreva uma mensagem…"
	}

	/// Only shown when it carries information the user does not already have
	/// from the transcript — idle "Pronto" is noise.
	private var statusHint: String? {
		switch coordinator.runState {
		case .ready, .stopped: return nil
		case .failed(let message): return message
		default: return coordinator.runState.label
		}
	}

	/// Changes on every streamed delta so the scroll follows growing text, not
	/// just new items.
	private var streamingSignature: Int {
		guard case .assistant(let turn) = coordinator.items.last else { return coordinator.items.count }
		return turn.text.count
	}

	private static let bottomAnchor = "menuagent.bottom"
}

/// Composer-local state and the actions the text view triggers.
@MainActor
@Observable
public final class ComposerModel {
	public var text = ""
	public private(set) var attachments: [PendingAttachment] = []

	private let coordinator: AgentCoordinator
	private let interpreter = ClipboardInterpreter()
	private let pasteboard: () -> PasteboardReading

	public var onDismiss: (() -> Void)?

	public init(
		coordinator: AgentCoordinator,
		pasteboard: @escaping () -> PasteboardReading = { SystemPasteboard() }
	) {
		self.coordinator = coordinator
		self.pasteboard = pasteboard
	}

	public func submit() {
		let payload = text
		let staged = attachments
		guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty else { return }
		text = ""
		attachments = []
		Task { await coordinator.submit(text: payload, attachments: staged) }
	}

	/// Returns `true` when the paste became an attachment and the text view
	/// should not also insert anything.
	public func handlePaste() -> Bool {
		switch interpreter.interpret(pasteboard()) {
		case .empty:
			return true
		case .text:
			return false
		case .attachments(let staged):
			stage(staged)
			return true
		case .mixed(_, let staged):
			stage(staged)
			return true
		}
	}

	private func stage(_ staged: [PendingAttachment]) {
		attachments.append(contentsOf: staged)
		// A pasted folder is the strongest available signal of intent to work
		// in that project, so it becomes the workspace instead of a path in the
		// prompt. No project picker exists by design.
		if let folder = staged.first(where: \.isFolder)?.fileURL {
			attachments.removeAll { $0.fileURL == folder }
			Task { await coordinator.changeWorkspace(to: folder) }
		}
	}

	public func remove(_ attachment: PendingAttachment) {
		attachments.removeAll { $0.id == attachment.id }
	}

	public func clear() {
		text = ""
		attachments = []
	}

	public func dismiss() { onDismiss?() }
}
