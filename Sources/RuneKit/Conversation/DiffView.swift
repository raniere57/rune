import AppKit
import SwiftUI

/// Monospaced, whitespace-preserving diff. Line count is clamped upstream by
/// `DiffParser`, so an enormous patch renders its head plus a truncation note
/// rather than freezing the panel.
struct DiffView: View {
	let diff: DiffSummary
	let openTarget: URL?

	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			HStack(spacing: 8) {
				Text(diff.statLine)
					.font(.system(size: 10, weight: .semibold, design: .monospaced))
					.foregroundStyle(.tertiary)
				Spacer(minLength: 0)
				if let openTarget {
					Button("abrir arquivo") { NSWorkspace.shared.open(openTarget) }
						.buttonStyle(.plain)
						.font(.system(size: 11))
						.foregroundStyle(.tertiary)
				}
			}

			ScrollView([.horizontal, .vertical], showsIndicators: true) {
				VStack(alignment: .leading, spacing: 0) {
					ForEach(diff.lines) { line in
						Text(line.text.isEmpty ? " " : line.text)
							.font(.system(size: 11, design: .monospaced))
							.foregroundStyle(color(for: line.kind))
							.textSelection(.enabled)
							.padding(.horizontal, 8)
							.padding(.vertical, 0.5)
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(background(for: line.kind))
					}
				}
				.padding(.vertical, 6)
			}
			.frame(maxHeight: 260)
			.background(PanelStyle.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

			if diff.isTruncated {
				Text("+\(diff.truncatedLineCount) linhas não exibidas")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	private func color(for kind: DiffSummary.Line.Kind) -> Color {
		switch kind {
		case .added: return .green
		case .removed: return .red
		case .hunk: return .accentColor
		case .context: return .secondary
		}
	}

	private func background(for kind: DiffSummary.Line.Kind) -> Color {
		switch kind {
		case .added: return .green.opacity(0.10)
		case .removed: return .red.opacity(0.10)
		case .hunk, .context: return .clear
		}
	}
}
