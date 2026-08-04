import AppKit

/// Installs the main menu.
///
/// An `.accessory` app shows no menu bar, which makes it tempting to skip the
/// menu entirely — but `⌘X`/`⌘C`/`⌘V`/`⌘A`/`⌘Z` are not built into `NSTextView`.
/// They are *menu key equivalents*: `NSApplication` routes a command keystroke
/// that no window claims to `NSApp.mainMenu`, and with no menu there is nothing
/// to claim `paste:`, so the keystroke fails and macOS plays the funk alert.
///
/// The menu is therefore invisible but load-bearing.
enum AppMenu {
	@MainActor
	static func install() {
		let mainMenu = NSMenu()
		mainMenu.addItem(applicationMenuItem())
		mainMenu.addItem(editMenuItem())
		NSApp.mainMenu = mainMenu
	}

	@MainActor
	private static func applicationMenuItem() -> NSMenuItem {
		let item = NSMenuItem()
		let menu = NSMenu(title: AppConfiguration.appName)

		menu.addItem(
			withTitle: "Ocultar \(AppConfiguration.appName)",
			action: #selector(NSApplication.hide(_:)),
			keyEquivalent: "h"
		)
		menu.addItem(.separator())
		menu.addItem(
			withTitle: "Sair de \(AppConfiguration.appName)",
			action: #selector(NSApplication.terminate(_:)),
			keyEquivalent: "q"
		)

		item.submenu = menu
		return item
	}

	@MainActor
	private static func editMenuItem() -> NSMenuItem {
		let item = NSMenuItem()
		let menu = NSMenu(title: "Editar")

		// Targets stay nil so each action travels the responder chain and lands
		// on whatever text view currently has focus — including the composer's
		// `paste(_:)` override, which is what routes ⌘V into the clipboard
		// interpreter.
		menu.addItem(withTitle: "Desfazer", action: Selector(("undo:")), keyEquivalent: "z")
		let redo = menu.addItem(withTitle: "Refazer", action: Selector(("redo:")), keyEquivalent: "z")
		redo.keyEquivalentModifierMask = [.command, .shift]

		menu.addItem(.separator())
		menu.addItem(withTitle: "Recortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
		menu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
		menu.addItem(withTitle: "Colar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
		menu.addItem(
			withTitle: "Selecionar Tudo",
			action: #selector(NSText.selectAll(_:)),
			keyEquivalent: "a"
		)

		item.submenu = menu
		return item
	}

	/// Reported by `--diagnose`; without it a regression here is invisible
	/// until someone presses ⌘V and hears the beep.
	@MainActor
	static var installedEditActions: [String] {
		guard let edit = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "Editar" })?.submenu
		else { return [] }
		return edit.items.compactMap { item in
			guard let action = item.action, !item.keyEquivalent.isEmpty else { return nil }
			return "⌘\(item.keyEquivalent.uppercased())=\(NSStringFromSelector(action))"
		}
	}
}
