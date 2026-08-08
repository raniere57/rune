import AppKit
import SwiftUI

/// Collapsed by default: one line per tool call, expandable into arguments,
/// result text, and a diff when the result carries one. Raw JSON is never
/// dumped into the conversation — the expanded body is pretty-printed and
/// clamped.
struct ToolCallView: View {
	let activity: ToolActivity
	@State private var isExpanded = false
	@State private var isHovering = false

	var body: some View {
		VStack(alignment: .leading, spacing: 6) {
			Button {
				withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
			} label: {
				HStack(spacing: 7) {
					Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
						.font(.system(size: 9, weight: .semibold))
						.foregroundStyle(.tertiary)
						.frame(width: 9)

					statusMark

					Text(activity.summary)
						.font(.system(size: 12))
						.foregroundStyle(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)

					if let diff = activity.diff {
						Text(diff.statLine)
							.font(.system(size: 10, weight: .medium, design: .monospaced))
							.foregroundStyle(.tertiary)
					}

					Spacer(minLength: 0)
				}
				// Padded and inset so the hover highlight reads as a row rather
				// than a rectangle glued to the text.
				.padding(.horizontal, 6)
				.padding(.vertical, 3)
				.background(
					PanelStyle.rowHighlight(hovering: isHovering),
					in: RoundedRectangle(cornerRadius: 5, style: .continuous)
				)
				.padding(.horizontal, -6)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
			.onHover { isHovering = $0 }
			.animation(.easeOut(duration: 0.1), value: isHovering)

			if isExpanded {
				VStack(alignment: .leading, spacing: 8) {
					if let arguments = prettyArguments {
						LabelledBlock(title: "argumentos", text: arguments)
					}
					if let diff = activity.diff {
						DiffView(diff: diff, openTarget: openTarget)
					} else if !activity.resultText.isEmpty {
						LabelledBlock(title: "resultado", text: activity.resultText)
					}
				}
				.padding(.leading, 16)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private var statusMark: some View {
		Group {
			switch activity.status {
			case .running:
				ProgressView().controlSize(.mini).scaleEffect(0.65)
			case .succeeded:
				Image(systemName: "checkmark").foregroundStyle(.green)
			case .failed:
				Image(systemName: "xmark").foregroundStyle(.red)
			}
		}
		.font(.system(size: 9, weight: .bold))
		.frame(width: 12)
	}

	private var prettyArguments: String? {
		guard case .object(let fields) = activity.arguments, !fields.isEmpty else { return nil }
		let text = activity.arguments.displayText
		guard !text.isEmpty else { return nil }
		let limit = AppConfiguration.maxRenderedToolResultCharacters
		return text.count > limit ? String(text.prefix(limit)) + "\n…" : text
	}

	/// Opens the touched file in whatever the system has registered for it —
	/// no editor is embedded here.
	private var openTarget: URL? {
		for key in ["path", "file_path"] {
			if let path = activity.arguments[key]?.stringValue, !path.isEmpty {
				return URL(fileURLWithPath: path)
			}
		}
		return nil
	}
}

struct LabelledBlock: View {
	let title: String
	let text: String

	var body: some View {
		VStack(alignment: .leading, spacing: 3) {
			Text(title)
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(.tertiary)
				.textCase(.uppercase)
			ScrollView(.horizontal, showsIndicators: false) {
				Text(text)
					.font(.system(size: 11, design: .monospaced))
					.textSelection(.enabled)
					.padding(8)
			}
			.frame(maxHeight: 200)
			.background(PanelStyle.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}
