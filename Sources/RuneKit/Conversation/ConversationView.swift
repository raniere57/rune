import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Root panel content: history above, composer below, nothing else.
///
/// No sidebar, tabs, file tree, editor, terminal, dashboard, model picker,
/// settings, toolbar, or attach button — every affordance is a keystroke or a
/// slash command.
public struct ConversationView: View {
	@Bindable var coordinator: AgentCoordinator
	@Bindable var composer: ComposerModel

	/// Whether streamed text should keep scrolling the view. False while the user
	/// is reading further up.
	@State private var isPinnedToBottom = true
	@State private var isDropTargeted = false

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
		// The whole panel is the drop target, not just the text field: aiming a
		// drag at a 44pt strip is needless precision when nothing else here wants
		// a drop.
		.onDrop(of: DroppedItems.acceptedTypes, isTargeted: $isDropTargeted) { providers in
			composer.handleDrop(providers)
		}
		.overlay {
			if isDropTargeted {
				RoundedRectangle(cornerRadius: 14, style: .continuous)
					.strokeBorder(Color.accentColor, lineWidth: 2)
					.background(Color.accentColor.opacity(0.06))
					.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
					.allowsHitTesting(false)
					.transition(.opacity)
			}
		}
		.animation(.easeOut(duration: 0.12), value: isDropTargeted)
		// Fixed width: the panel is borderless, so nothing else constrains the
		// horizontal axis and SwiftUI would otherwise collapse to its content.
		.frame(width: AppConfiguration.panelWidth)
		.background(.ultraThinMaterial)
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.strokeBorder(PanelStyle.hairline)
		)
	}

	private var history: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 12) {
					ForEach(coordinator.items) { item in
						row(for: item).id(item.id)
					}

					if showsActivityRow {
						ActivityIndicatorView(state: coordinator.runState)
							.transition(.opacity)
					}
					// Anchor for auto-scroll; scrolling to the last item would
					// stop short while its text is still growing.
					Color.clear.frame(height: 1)
						.id(Self.bottomAnchor)
						.background(distanceReporter)
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 14)
			}
			.coordinateSpace(name: Self.scrollSpace)
			.frame(maxHeight: AppConfiguration.historyMaxHeight)
			.onPreferenceChange(DistanceFromBottom.self) { distance in
				isPinnedToBottom = Self.isPinned(distanceFromBottom: distance)
			}
			.onChange(of: coordinator.items.count) {
				// A new item always follows: the user asked for it, or the agent
				// moved on to something they should see.
				isPinnedToBottom = true
				withAnimation(.easeOut(duration: 0.15)) {
					proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
				}
			}
			.onChange(of: streamingSignature) {
				// Growing text only follows while the user is already at the
				// bottom. Following unconditionally made it impossible to read
				// back through a long answer — every token yanked the view down.
				guard isPinnedToBottom else { return }
				proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
			}
			.onChange(of: showsActivityRow) {
				guard isPinnedToBottom else { return }
				withAnimation(.easeOut(duration: 0.15)) {
					proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
				}
			}
		}
	}

	/// Reports how far the end of the transcript sits below the visible area.
	///
	/// Measured in the scroll view's own coordinate space, whose origin is the
	/// top of the *viewport*, so the anchor's `minY` is its distance from there.
	/// Subtracting the viewport height gives zero when scrolled to the bottom and
	/// grows as the user scrolls up.
	///
	/// `historyMaxHeight` is the right height to subtract in both cases: when the
	/// transcript is tall the frame is exactly that, and when it is short the
	/// result goes negative — which reads as pinned, correctly, since there is
	/// nothing to scroll.
	private var distanceReporter: some View {
		GeometryReader { anchor in
			Color.clear.preference(
				key: DistanceFromBottom.self,
				value: anchor.frame(in: .named(Self.scrollSpace)).minY
					- AppConfiguration.historyMaxHeight
			)
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
		case .output(let entry):
			CommandOutputView(entry: entry)
		case .failure(let entry):
			// Retry is only offered on the failure that ends the conversation:
			// on an older one it would re-send a message the user has already
			// moved past.
			FailureView(
				entry: entry,
				onRetry: isLastItem(entry.id) && coordinator.retryableMessage != nil
					? { Task { await coordinator.retryLastMessage() } }
					: nil
			)
		case .request(let pending):
			ExtensionRequestView(pending: pending) { answer in
				coordinator.answer(requestId: pending.id, with: answer)
			}
		}
	}

	private var composerSection: some View {
		VStack(alignment: .leading, spacing: 8) {
			if composer.isSuggesting {
				SlashSuggestionsView(
					suggestions: composer.suggestions,
					selectedIndex: composer.selectedSuggestion,
					onSelect: { composer.select($0) }
				)
				.transition(.opacity.combined(with: .move(edge: .bottom)))
			}

			ComposerView(
				text: $composer.text,
				attachments: composer.attachments,
				placeholder: placeholder,
				// Enter and Esc are shared with the suggestion popup: while it is
				// open they act on the list, and only fall through to send/close
				// once it is not.
				onSubmit: {
					if composer.acceptSuggestion() { return }
					composer.submit()
				},
				onPaste: { composer.handlePaste() },
				onEscape: {
					if composer.dismissSuggestions() { return }
					composer.dismiss()
				},
				onMoveSelection: { composer.moveSelection(by: $0) },
				onCompleteSuggestion: { composer.acceptSuggestion() },
				onToggleMode: { coordinator.toggleMode() },
				onRemoveAttachment: { composer.remove($0) }
			)

			ComposerFooter(
				mode: coordinator.mode,
				isModePending: coordinator.modeIsPending,
				isBusy: coordinator.isBusy,
				workspaceName: coordinator.workspace.url.lastPathComponent,
				workspaceHelp: "Diretório de trabalho: \(coordinator.workspace.displayName)",
				statusHint: statusHint,
				canSend: composer.canSend,
				contextPercent: coordinator.contextPercent,
				onToggleMode: { coordinator.toggleMode() },
				onChooseWorkspace: { coordinator.chooseWorkspace() },
				onChooseSession: { coordinator.presentSessionPicker() },
				onAbort: { composer.abort() },
				onSubmit: { composer.submit() }
			)
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 12)
		.animation(.easeOut(duration: 0.12), value: composer.isSuggesting)
	}

	private func isLastItem(_ failureId: String) -> Bool {
		guard case .failure(let entry) = coordinator.items.last else { return false }
		return entry.id == failureId
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

	/// Shown while the agent is working and the last thing on screen is not
	/// already streaming text — otherwise the dots would sit under a paragraph
	/// that is visibly growing, which is noise.
	private var showsActivityRow: Bool {
		guard coordinator.runState.isBusy else { return false }
		if case .assistant(let turn) = coordinator.items.last, turn.isStreaming, !turn.text.isEmpty {
			return false
		}
		return true
	}

	/// Changes on every streamed delta so the scroll follows growing text, not
	/// just new items.
	private var streamingSignature: Int {
		guard case .assistant(let turn) = coordinator.items.last else { return coordinator.items.count }
		return turn.text.count
	}

	private static let bottomAnchor = "rune.bottom"
	private static let scrollSpace = "rune.history"
	/// Slack allowed before the view is considered "scrolled away". A couple of
	/// lines, so a rubber-band overshoot or a rounding difference does not stop
	/// the stream from following.
	private nonisolated static let pinThreshold: CGFloat = 40

	/// Whether the stream should keep following the end of the transcript.
	nonisolated static func isPinned(distanceFromBottom: CGFloat) -> Bool {
		distanceFromBottom <= pinThreshold
	}
}

/// Distance between the end of the transcript and the bottom of the viewport.
struct DistanceFromBottom: PreferenceKey {
	/// Deliberately "infinitely far", not zero. The anchor lives inside a
	/// `LazyVStack`, so scrolling far enough up discards it: no child supplies
	/// the preference and this default is what `onPreferenceChange` receives.
	/// A zero read as "resting at the bottom" and re-pinned the view, which is
	/// the very yanking 0.10.0 set out to stop — and only in long transcripts,
	/// where scrolling back actually matters.
	static let defaultValue: CGFloat = .greatestFiniteMagnitude

	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = nextValue()
	}
}

/// Composer-local state and the actions the text view triggers.
@MainActor
@Observable
public final class ComposerModel {
	public var text = "" {
		didSet { refreshSuggestions() }
	}

	public private(set) var attachments: [PendingAttachment] = []

	/// Slash commands matching what has been typed so far. Empty means the
	/// popup is closed.
	public private(set) var suggestions: [SlashCommand] = []
	public private(set) var selectedSuggestion = 0
	/// Set when the user dismissed the popup with Esc, so it does not pop back
	/// on the next keystroke of the same word.
	private var suggestionsDismissed = false

	public var isSuggesting: Bool { !suggestions.isEmpty }

	/// Whether there is anything to send. Owned here so the send button and the
	/// Enter key cannot disagree about it.
	public var canSend: Bool {
		!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
	}

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
		suggestions = []
		suggestionsDismissed = false
		Task { await coordinator.submit(text: payload, attachments: staged) }
	}

	// MARK: - Slash suggestions

	/// Suggestions appear while the command word itself is being typed. Once a
	/// space is entered the user has moved on to the argument, so the list gets
	/// out of the way.
	private func refreshSuggestions() {
		guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else {
			suggestions = []
			suggestionsDismissed = false
			return
		}
		guard !suggestionsDismissed else { return }

		let query = String(text.dropFirst())
		suggestions = SlashCommand.matches(query, in: coordinator.availableCommands)
		selectedSuggestion = 0
	}

	/// Returns `true` when the keystroke was consumed by the popup.
	public func moveSelection(by delta: Int) -> Bool {
		guard isSuggesting else { return false }
		let count = suggestions.count
		selectedSuggestion = (selectedSuggestion + delta % count + count) % count
		return true
	}

	public func acceptSuggestion() -> Bool {
		guard isSuggesting, suggestions.indices.contains(selectedSuggestion) else { return false }
		let command = suggestions[selectedSuggestion]
		suggestions = []
		// Assigning `text` re-enters `refreshSuggestions`, which closes the
		// popup on its own because the completion ends in a space.
		text = command.completion
		return true
	}

	public func select(_ command: SlashCommand) {
		suggestions = []
		text = command.completion
	}

	/// Returns `true` when Esc closed the popup rather than the panel.
	public func dismissSuggestions() -> Bool {
		guard isSuggesting else { return false }
		suggestions = []
		suggestionsDismissed = true
		return true
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

	/// Stages a drag-and-drop payload. Returns `true` when at least one provider
	/// was something the composer can take, which is what tells AppKit to accept
	/// the drop.
	public func handleDrop(_ providers: [NSItemProvider]) -> Bool {
		let usable = providers.filter {
			$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
				|| $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
		}
		guard !usable.isEmpty else { return false }

		// Providers resolve asynchronously and in no guaranteed order, so each
		// one stages itself as it arrives rather than the batch waiting on its
		// slowest member.
		for provider in usable {
			if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
				_ = provider.loadObject(ofClass: URL.self) { url, _ in
					guard let url, url.isFileURL else { return }
					Task { @MainActor [weak self] in
						self?.stage([DroppedItems.attachment(forFileAt: url)])
					}
				}
				continue
			}
			provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
				guard let data, let attachment = DroppedItems.attachment(forImageData: data) else { return }
				Task { @MainActor [weak self] in
					self?.stage([attachment])
				}
			}
		}
		return true
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

	/// Same path as `⌘.`; the button is an affordance for it, not a second
	/// mechanism.
	public func abort() {
		Task { await coordinator.abort() }
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
