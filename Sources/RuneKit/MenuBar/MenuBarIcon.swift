import AppKit

/// The Algiz rune drawn as a menu bar template image.
///
/// Drawn at runtime rather than bundled as a PNG so the executable stays a
/// single file with no resource bundle, and so the mark renders crisply at
/// whatever point size the menu bar asks for. `isTemplate` lets AppKit handle
/// light/dark and the highlighted (menu-open) state.
enum MenuBarIcon {
	static let shared: NSImage = make(pointSize: 16)

	static func make(pointSize: CGFloat) -> NSImage {
		let size = NSSize(width: pointSize, height: pointSize)
		let image = NSImage(size: size, flipped: false) { rect in
			guard let context = NSGraphicsContext.current?.cgContext else { return true }
			context.setShouldAntialias(true)

			// Slightly heavier than the app icon: a hairline mark disappears
			// against a busy menu bar.
			let stroke = rect.width * 0.115
			let centerX = rect.midX
			let top = rect.minY + rect.height * 0.82
			let bottom = rect.minY + rect.height * 0.16
			let fork = rect.minY + rect.height * 0.46
			let spread = rect.width * 0.26

			let path = CGMutablePath()
			path.move(to: CGPoint(x: centerX, y: bottom))
			path.addLine(to: CGPoint(x: centerX, y: top))
			path.move(to: CGPoint(x: centerX - spread, y: top))
			path.addLine(to: CGPoint(x: centerX, y: fork))
			path.addLine(to: CGPoint(x: centerX + spread, y: top))

			context.setLineWidth(stroke)
			context.setLineCap(.round)
			context.setLineJoin(.round)
			context.setStrokeColor(NSColor.black.cgColor)
			context.addPath(path)
			context.strokePath()
			return true
		}
		image.isTemplate = true
		image.accessibilityDescription = AppConfiguration.appName
		return image
	}
}
