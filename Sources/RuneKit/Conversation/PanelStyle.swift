import AppKit
import SwiftUI

/// Chrome colours for the panel, derived from `Color.primary` so they follow the
/// system appearance.
///
/// The panel is painted on `.ultraThinMaterial`, which is adaptive — but the
/// chrome on top of it was not: fixed white overlays for chips and borders,
/// fixed black for sunken blocks. In dark mode that reads correctly by accident,
/// because white-on-dark and black-under-dark happen to be the right direction.
/// In light mode the chips lost their outline entirely and the code blocks
/// turned into dark slabs with dark text.
///
/// `Color.primary` is the label colour — black in light mode, white in dark — so
/// a low-opacity tint of it is "slightly more contrast than the background" in
/// both, which is what every one of these surfaces actually wants.
enum PanelStyle {
	/// Recessed surface for code, diffs, and command output.
	static let sunken = Color.primary.opacity(0.06)

	/// Divider-weight outline.
	static let hairline = Color.primary.opacity(0.10)

	/// Even fainter outline, for blocks that already read as separate.
	static let faintHairline = Color.primary.opacity(0.07)

	/// Small inline label — the `app` badge, a shortcut hint.
	static let badge = Color.primary.opacity(0.10)

	static func chipFill(hovering: Bool) -> Color {
		Color.primary.opacity(hovering ? 0.10 : 0.05)
	}

	static func chipStroke(hovering: Bool) -> Color {
		Color.primary.opacity(hovering ? 0.20 : 0.10)
	}

	static func rowHighlight(hovering: Bool) -> Color {
		hovering ? Color.primary.opacity(0.07) : .clear
	}
}

// MARK: - Copy affordance

extension View {
	/// Reveals a copy button in the top-trailing corner while the pointer is over
	/// the block.
	///
	/// A code block is the most-copied thing a coding agent produces, and the only
	/// way to get one used to be selecting it by hand — inside a horizontally
	/// scrolling view, where the drag fights the scroll for the same axis.
	/// Revealed on hover so the resting transcript stays clean.
	func copyable(_ text: String) -> some View {
		modifier(CopyableBlock(text: text))
	}
}

private struct CopyableBlock: ViewModifier {
	let text: String
	@State private var isHovering = false

	func body(content: Content) -> some View {
		content
			.overlay(alignment: .topTrailing) {
				CopyButton(text: text)
					.padding(5)
					.opacity(isHovering ? 1 : 0)
					.animation(.easeOut(duration: 0.12), value: isHovering)
					// Hidden from hit testing while invisible, so it cannot
					// intercept a click meant for the text underneath.
					.allowsHitTesting(isHovering)
			}
			.onHover { isHovering = $0 }
	}
}

struct CopyButton: View {
	let text: String

	@State private var hasCopied = false
	@State private var isHovering = false

	var body: some View {
		Button(action: copy) {
			Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
				.font(.system(size: 10, weight: .medium))
				.foregroundStyle(hasCopied ? .green : .secondary)
				.frame(width: 20, height: 20)
				.background(PanelStyle.chipFill(hovering: isHovering), in: RoundedRectangle(
					cornerRadius: 5,
					style: .continuous
				))
				.overlay(
					RoundedRectangle(cornerRadius: 5, style: .continuous)
						.strokeBorder(PanelStyle.chipStroke(hovering: isHovering))
				)
		}
		.buttonStyle(.plain)
		.onHover { isHovering = $0 }
		.help(hasCopied ? "Copiado" : "Copiar")
		.accessibilityLabel("Copiar bloco")
	}

	private func copy() {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		hasCopied = true
		// A short confirmation rather than a persistent state: the tick is
		// feedback for the click, not a mode. One `Task.sleep`, no timer.
		Task {
			try? await Task.sleep(for: .seconds(1.5))
			hasCopied = false
		}
	}
}
