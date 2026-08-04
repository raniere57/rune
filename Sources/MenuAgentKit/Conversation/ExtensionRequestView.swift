import SwiftUI

/// Renders an `extension_ui_request` inline in the conversation.
///
/// No modal sheet: an approval is part of the transcript, and blocking the
/// whole panel behind a dialog would hide the command being approved.
struct ExtensionRequestView: View {
	let pending: PendingRequest
	let onAnswer: (ExtensionUIAnswer) -> Void

	@State private var inputText = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			header

			switch pending.request.method {
			case .select(_, let options):
				controls(options: options)
			case .confirm:
				controls(options: ["Aprovar", "Recusar"], confirmStyle: true)
			case .input, .editor:
				textEntry
			default:
				EmptyView()
			}
		}
		.padding(11)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 9, style: .continuous)
				.strokeBorder(tint.opacity(0.35))
		)
		.opacity(pending.answered ? 0.5 : 1)
	}

	private var header: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: pending.request.isApprovalPrompt ? "hand.raised.fill" : "questionmark.circle")
				.font(.system(size: 11))
				.foregroundStyle(tint)
			Text(promptText)
				.font(.system(size: 12, design: pending.request.isApprovalPrompt ? .monospaced : .default))
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
			Spacer(minLength: 0)
		}
	}

	@ViewBuilder
	private func controls(options: [String], confirmStyle: Bool = false) -> some View {
		HStack(spacing: 8) {
			ForEach(Array(options.enumerated()), id: \.offset) { index, option in
				Button(option) {
					// `confirm` answers with a boolean; `select` echoes the
					// chosen option string verbatim.
					onAnswer(confirmStyle ? .confirmed(index == 0) : .value(option))
				}
				.buttonStyle(.borderedProminent)
				.tint(index == 0 ? .accentColor : .secondary)
				.controlSize(.small)
			}
			Button("Cancelar") { onAnswer(.cancelled(timedOut: false)) }
				.buttonStyle(.plain)
				.font(.system(size: 11))
				.foregroundStyle(.tertiary)
			Spacer(minLength: 0)
		}
		.disabled(pending.answered)
	}

	private var textEntry: some View {
		HStack(spacing: 8) {
			TextField(placeholder, text: $inputText)
				.textFieldStyle(.roundedBorder)
				.font(.system(size: 12))
				.onSubmit { onAnswer(.value(inputText)) }
			Button("Enviar") { onAnswer(.value(inputText)) }
				.controlSize(.small)
			Button("Cancelar") { onAnswer(.cancelled(timedOut: false)) }
				.buttonStyle(.plain)
				.font(.system(size: 11))
				.foregroundStyle(.tertiary)
		}
		.disabled(pending.answered)
	}

	private var tint: Color {
		pending.request.isApprovalPrompt ? .orange : .accentColor
	}

	private var promptText: String {
		switch pending.request.method {
		case .select(let title, _): return title
		case .confirm(let title, let message): return message.isEmpty ? title : "\(title)\n\(message)"
		case .input(let title, _): return title
		case .editor(let title, _): return title
		default: return ""
		}
	}

	private var placeholder: String {
		if case .input(_, let placeholder) = pending.request.method { return placeholder ?? "" }
		return ""
	}
}
