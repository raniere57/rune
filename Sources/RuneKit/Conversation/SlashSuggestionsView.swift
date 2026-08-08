import SwiftUI

/// The `/` command list, shown above the composer.
///
/// Not a menu and not a sheet: it sits inline so the panel keeps its single
/// column and the composer never loses focus while the list is open.
struct SlashSuggestionsView: View {
	let suggestions: [SlashCommand]
	let selectedIndex: Int
	let onSelect: (SlashCommand) -> Void

	private static let maxVisibleRows = 7
	private static let rowHeight: CGFloat = 32

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 0) {
					ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
						SuggestionRow(
							command: command,
							isSelected: index == selectedIndex,
							onSelect: { onSelect(command) }
						)
						.id(command.id)
					}
				}
			}
			.frame(maxHeight: Self.rowHeight * CGFloat(min(suggestions.count, Self.maxVisibleRows)))
			// Keyboard selection must stay visible when it walks past the fold.
			.onChange(of: selectedIndex) {
				guard suggestions.indices.contains(selectedIndex) else { return }
				withAnimation(.easeOut(duration: 0.1)) {
					proxy.scrollTo(suggestions[selectedIndex].id, anchor: .center)
				}
			}
		}
		.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 9, style: .continuous)
				.strokeBorder(PanelStyle.faintHairline)
		)
		.overlay(alignment: .bottom) {
			if suggestions.count > Self.maxVisibleRows {
				Text("\(suggestions.count) comandos · ↑↓ navega · ⇥ completa")
					.font(.system(size: 9))
					.foregroundStyle(.tertiary)
					.padding(.horizontal, 8)
					.padding(.vertical, 2)
					.background(PanelStyle.badge, in: Capsule())
					.padding(.bottom, 4)
			}
		}
	}
}

private struct SuggestionRow: View {
	let command: SlashCommand
	let isSelected: Bool
	let onSelect: () -> Void

	@State private var isHovering = false

	var body: some View {
		Button(action: onSelect) {
			HStack(spacing: 8) {
				Text("/\(command.name)")
					.font(.system(size: 12, weight: .medium, design: .monospaced))
					.foregroundStyle(isSelected ? .primary : .secondary)
					.lineLimit(1)

				if let hint = command.hint {
					Text(hint)
						.font(.system(size: 11, design: .monospaced))
						.foregroundStyle(.tertiary)
						.lineLimit(1)
				}

				if !command.summary.isEmpty {
					Text(command.summary)
						.font(.system(size: 11))
						.foregroundStyle(.tertiary)
						.lineLimit(1)
						.truncationMode(.tail)
				}

				Spacer(minLength: 0)

				// Only the app's own commands get a marker; the OMP ones are the
				// overwhelming majority and would turn a badge into noise.
				if command.source == .local {
					Text("app")
						.font(.system(size: 9, weight: .medium))
						.foregroundStyle(.tertiary)
						.padding(.horizontal, 5)
						.padding(.vertical, 1)
						.background(PanelStyle.badge, in: Capsule())
				}
			}
			.padding(.horizontal, 10)
			.frame(height: 32)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(rowBackground)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
	}

	private var rowBackground: Color {
		if isSelected { return .accentColor.opacity(0.28) }
		return PanelStyle.rowHighlight(hovering: isHovering)
	}
}
