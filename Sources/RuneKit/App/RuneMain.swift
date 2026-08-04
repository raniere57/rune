import AppKit

/// Entry point kept in the library so the executable target is a single line
/// and every testable symbol lives in `RuneKit`.
public enum RuneMain {
	@MainActor
	public static func run() {
		let app = NSApplication.shared
		let delegate = AppDelegate()
		app.delegate = delegate
		// `.accessory` keeps the app out of the Dock and the ⌘-Tab switcher
		// without needing an `LSUIElement` bundle, so a bare `swift run` binary
		// behaves the same as the packaged `.app`.
		app.setActivationPolicy(.accessory)
		app.run()
	}
}
