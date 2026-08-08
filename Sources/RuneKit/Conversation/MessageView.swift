import SwiftUI

struct UserMessageView: View {
	let turn: UserTurn

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text(turn.text)
				.font(.system(size: 13))
				.textSelection(.enabled)
				.frame(maxWidth: .infinity, alignment: .leading)

			if !turn.attachments.isEmpty {
				HStack(spacing: 6) {
					ForEach(turn.attachments) { attachment in
						AttachmentChip(summary: attachment)
					}
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 9)
		.background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
		// Offset rather than centred so the user turn reads as an aside to the
		// answer instead of competing with it.
		.padding(.leading, 44)
	}
}

struct AssistantMessageView: View {
	let turn: AssistantTurn

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(MarkdownBlock.parse(turn.text)) { block in
				switch block {
				case .prose(_, let text):
					Text(AttributedString.inlineMarkdown(text))
						.font(.system(size: 13))
						.textSelection(.enabled)
						.fixedSize(horizontal: false, vertical: true)
						.frame(maxWidth: .infinity, alignment: .leading)
				case .code(_, let language, let text):
					CodeBlockView(language: language, code: text)
				}
			}

			if turn.isStreaming {
				StreamingIndicator()
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

struct CodeBlockView: View {
	let language: String?
	let code: String

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let language, !language.isEmpty {
				Text(language)
					.font(.system(size: 10, weight: .medium, design: .monospaced))
					.foregroundStyle(.tertiary)
					.padding(.horizontal, 10)
					.padding(.top, 6)
			}
			ScrollView(.horizontal, showsIndicators: false) {
				Text(code)
					.font(.system(size: 12, design: .monospaced))
					.textSelection(.enabled)
					.padding(.horizontal, 10)
					.padding(.vertical, 8)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(PanelStyle.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.strokeBorder(PanelStyle.faintHairline)
		)
	}
}

struct StreamingIndicator: View {
	@State private var phase = 0.0

	var body: some View {
		Circle()
			.fill(.primary)
			.frame(width: 6, height: 6)
			.opacity(0.25 + 0.55 * phase)
			.task {
				// A single repeating opacity animation on one 6pt layer — no
				// timer, no layout work, negligible while idle.
				withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
					phase = 1
				}
			}
	}
}

struct NoticeView: View {
	let entry: NoticeEntry

	var body: some View {
		HStack(alignment: .top, spacing: 8) {
			Image(systemName: symbol)
				.font(.system(size: 11))
				.foregroundStyle(tint)
			Text(entry.text)
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
				.textSelection(.enabled)
				.fixedSize(horizontal: false, vertical: true)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var symbol: String {
		switch entry.level {
		case .info: return "info.circle"
		case .warning: return "exclamationmark.triangle"
		case .error: return "xmark.octagon"
		}
	}

	private var tint: Color {
		switch entry.level {
		case .info: return .secondary
		case .warning: return .orange
		case .error: return .red
		}
	}
}

struct FailureView: View {
	let entry: FailureEntry
	@State private var isExpanded = false

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(alignment: .top, spacing: 8) {
				Image(systemName: "exclamationmark.octagon.fill")
					.font(.system(size: 11))
					.foregroundStyle(.red)
				Text(entry.text)
					.font(.system(size: 12, weight: .medium))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
				Spacer(minLength: 0)
				if entry.detail != nil {
					Button(isExpanded ? "menos" : "detalhes") { isExpanded.toggle() }
						.buttonStyle(.plain)
						.font(.system(size: 11))
						.foregroundStyle(.tertiary)
				}
			}
			if isExpanded, let detail = entry.detail {
				Text(detail)
					.font(.system(size: 11, design: .monospaced))
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
					.padding(.leading, 19)
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
	}
}

struct AttachmentChip: View {
	let summary: AttachmentSummary
	var onRemove: (() -> Void)?

	var body: some View {
		HStack(spacing: 5) {
			Image(systemName: symbol)
				.font(.system(size: 10))
			Text(summary.label)
				.font(.system(size: 11))
				.lineLimit(1)
				.truncationMode(.middle)
			if let onRemove {
				Button(action: onRemove) {
					Image(systemName: "xmark")
						.font(.system(size: 8, weight: .bold))
				}
				.buttonStyle(.plain)
				.foregroundStyle(.tertiary)
				.help("Remover anexo")
			}
		}
		.padding(.horizontal, 8)
		.padding(.vertical, 4)
		.background(.quaternary.opacity(0.6), in: Capsule())
		.frame(maxWidth: 220)
	}

	private var symbol: String {
		switch summary.kind {
		case .image: return "photo"
		case .file: return "doc"
		case .folder: return "folder"
		}
	}
}

/// Output from a local slash command.
///
/// Monospaced and whitespace-preserving because these are terminal-shaped
/// payloads — `/context` prints an aligned table, `/session` a key/value block.
/// Long output collapses so a `/tools` dump cannot bury the conversation.
struct CommandOutputView: View {
	let entry: CommandOutputEntry
	@State private var isExpanded = false

	private static let collapsedLineLimit = 12

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 6) {
				Image(systemName: "terminal")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Spacer(minLength: 0)
				if isTruncatable {
					Button(isExpanded ? "recolher" : "\(lines.count) linhas") {
						withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
					}
					.buttonStyle(.plain)
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				}
			}

			ScrollView(.horizontal, showsIndicators: false) {
				Text(visibleText)
					.font(.system(size: 11, design: .monospaced))
					.textSelection(.enabled)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 8)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(PanelStyle.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.strokeBorder(PanelStyle.faintHairline)
		)
	}

	private var lines: [Substring] {
		entry.text.split(separator: "\n", omittingEmptySubsequences: false)
	}

	private var isTruncatable: Bool { lines.count > Self.collapsedLineLimit }

	private var visibleText: String {
		guard isTruncatable, !isExpanded else { return entry.text }
		return lines.prefix(Self.collapsedLineLimit).joined(separator: "\n") + "\n…"
	}
}

/// Live activity row, shown at the end of the transcript while the agent is
/// working and has not produced visible output yet.
///
/// Without it the panel sits perfectly still between pressing Enter and the
/// first token — which on a `max`-effort model is many seconds — and then
/// everything appears at once. The footer hint alone is too quiet to read as
/// "it is working".
struct ActivityIndicatorView: View {
	let state: AgentRunState

	@State private var phase = 0.0

	var body: some View {
		HStack(spacing: 8) {
			HStack(spacing: 3) {
				ForEach(0..<3, id: \.self) { index in
					Circle()
						.fill(.secondary)
						.frame(width: 5, height: 5)
						// Staggered so the row reads as motion rather than as
						// three dots blinking in unison.
						.opacity(0.25 + 0.6 * pulse(offset: Double(index) * 0.22))
				}
			}
			Text(label)
				.font(.system(size: 12))
				.foregroundStyle(.secondary)
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.task {
			// One repeating animation drives all three dots; no timer.
			withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
				phase = 1
			}
		}
	}

	private func pulse(offset: Double) -> Double {
		let shifted = phase + offset
		return shifted > 1 ? 2 - shifted : shifted
	}

	private var label: String {
		switch state {
		case .starting: return "Iniciando o agente…"
		case .thinking: return "Pensando…"
		case .usingTool(let name): return "Executando \(name)…"
		case .compacting: return "Compactando o contexto…"
		case .aborting: return "Abortando…"
		case .stopped, .ready, .failed: return "…"
		}
	}
}
