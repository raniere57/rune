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
