import AppKit

/// Native Finder dialogs for the two things the panel cannot express as text:
/// which directory to work in, and which past conversation to resume.
@MainActor
enum WorkspacePicker {
	/// Standard open panel restricted to directories.
	///
	/// The floating panel closes when it stops being key, which is exactly what
	/// the dialog causes — so auto-dismiss is suspended for the duration and the
	/// user is not left choosing a folder for an app that appears to have quit.
	static func chooseDirectory(startingAt current: URL, host: FloatingPanel?) -> URL? {
		guard let host else { return runOpenPanel(startingAt: current) }
		return host.keepingVisible { runOpenPanel(startingAt: current) }
	}

	private static func runOpenPanel(startingAt current: URL) -> URL? {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.canCreateDirectories = true
		panel.directoryURL = current
		panel.prompt = "Usar esta pasta"
		panel.message = "Escolha o diretório onde o agente vai trabalhar"

		NSApp.activate(ignoringOtherApps: true)
		guard panel.runModal() == .OK else { return nil }
		return panel.url
	}
}

/// Menu listing recent conversations, plus a way to start a fresh one.
@MainActor
enum SessionPicker {
	/// Pops a menu at `view`. Sessions from the current workspace come first,
	/// because resuming one from a different directory would put the agent in a
	/// tree that no longer matches its transcript.
	static func present(
		sessions: [SessionSummary],
		currentWorkspace: URL,
		currentSessionPath: String?,
		host: FloatingPanel?,
		onNew: @escaping () -> Void,
		onSelect: @escaping (SessionSummary) -> Void
	) {
		let menu = NSMenu()
		menu.autoenablesItems = false

		let newItem = NSMenuItem(title: "Nova conversa", action: nil, keyEquivalent: "")
		newItem.image = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: nil)
		newItem.target = MenuTarget.shared
		newItem.action = #selector(MenuTarget.fire(_:))
		newItem.representedObject = MenuAction(run: onNew)
		menu.addItem(newItem)

		let workspacePath = currentWorkspace.standardizedFileURL.path
		let (here, elsewhere) = sessions.reduce(into: ([SessionSummary](), [SessionSummary]())) {
			URL(fileURLWithPath: $1.cwd).standardizedFileURL.path == workspacePath
				? $0.0.append($1)
				: $0.1.append($1)
		}

		addSection(title: "Neste diretório", sessions: here, to: menu,
		           currentSessionPath: currentSessionPath, onSelect: onSelect)
		addSection(title: "Outros diretórios", sessions: elsewhere, to: menu,
		           currentSessionPath: currentSessionPath, onSelect: onSelect, showWorkspace: true)

		if sessions.isEmpty {
			menu.addItem(.separator())
			let empty = NSMenuItem(title: "Nenhuma conversa anterior", action: nil, keyEquivalent: "")
			empty.isEnabled = false
			menu.addItem(empty)
		}

		// Popped at the cursor rather than anchored to a view: the chip lives in
		// a SwiftUI hierarchy with no stable `NSView` to hand AppKit, and the
		// pointer is on the chip anyway since the user just clicked it.
		// Menu tracking takes key status, so auto-dismiss is suspended too.
		if let host {
			host.keepingVisible { menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
		} else {
			menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
		}
	}

	private static func addSection(
		title: String,
		sessions: [SessionSummary],
		to menu: NSMenu,
		currentSessionPath: String?,
		onSelect: @escaping (SessionSummary) -> Void,
		showWorkspace: Bool = false
	) {
		guard !sessions.isEmpty else { return }
		menu.addItem(.separator())
		let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
		header.isEnabled = false
		menu.addItem(header)

		for session in sessions.prefix(12) {
			let suffix = showWorkspace ? "  ·  \(session.workspaceName)" : ""
			let item = NSMenuItem(
				title: "\(session.title)   \(session.age())\(suffix)",
				action: #selector(MenuTarget.fire(_:)),
				keyEquivalent: ""
			)
			item.target = MenuTarget.shared
			item.representedObject = MenuAction { onSelect(session) }
			// The live session is listed but not selectable — switching to the
			// one already loaded would be a pointless restart.
			if session.path == currentSessionPath {
				item.state = .on
				item.isEnabled = false
			}
			menu.addItem(item)
		}
	}
}

/// `NSMenuItem` needs an ObjC target/action pair; this carries the Swift
/// closure across that boundary.
private final class MenuAction: NSObject {
	let run: () -> Void
	init(run: @escaping () -> Void) { self.run = run }
}

@MainActor
private final class MenuTarget: NSObject {
	static let shared = MenuTarget()

	@objc func fire(_ sender: NSMenuItem) {
		(sender.representedObject as? MenuAction)?.run()
	}
}
