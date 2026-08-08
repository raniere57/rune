import Foundation
import UserNotifications
import os

/// Tells the user a run finished when they are not looking at the panel.
///
/// The menu bar mark covers the case where they glance up; this covers the case
/// where they do not. Both exist because closing the panel deliberately does not
/// cancel the run, so "fire it and go do something else" is the intended flow.
///
/// Costs nothing while idle: `UserNotifications` loads lazily, there is no
/// timer, and the trigger is the same `runState` observation the icon already
/// uses.
@MainActor
public enum CompletionNotifier {
	// `nonisolated` because the completion handlers below are `Sendable` and run
	// off the main actor. `Logger` is itself `Sendable`, so this is free.
	private nonisolated static let logger = Logger(
		subsystem: AppConfiguration.bundleIdentifier,
		category: "ui"
	)

	/// `UNUserNotificationCenter.current()` raises when the process has no bundle
	/// — which is every `swift run` and every test run — and the raise is an
	/// ObjC exception Swift cannot catch. So the bundle is checked first, always.
	public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

	private static var didRequestAuthorization = false

	/// Asks once, provisionally: a provisional grant delivers quietly to
	/// Notification Centre with no permission dialog, so the app never
	/// interrupts to ask for something the user did not request.
	public static func prepare() {
		guard isAvailable, !didRequestAuthorization else { return }
		didRequestAuthorization = true
		UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, error in
			if let error {
				logger.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	/// The banner text for a run that just stopped being busy.
	///
	/// Both the state reached and the one left behind matter. `.stopped` is what
	/// `handleTermination` sets when the child dies mid-turn, so on its own the
	/// generic "concluída" reported a crash as a success. And an abort resolves
	/// to a perfectly ordinary `.ready` — only `.aborting` in the previous slot
	/// tells it apart from a turn that actually finished.
	///
	/// The switch is exhaustive on purpose: a new run state should not silently
	/// inherit the success wording.
	nonisolated static func body(
		for state: AgentRunState,
		previous: AgentRunState?,
		workspaceName: String
	) -> String {
		if case .aborting = previous { return "Interrompido em \(workspaceName)." }
		switch state {
		case .failed(let message): return "Falhou em \(workspaceName): \(message)"
		case .stopped: return "Interrompido em \(workspaceName)."
		case .ready: return "Tarefa concluída em \(workspaceName)."
		// Not reachable — the caller only announces transitions *out* of busy —
		// but naming them keeps a future state from defaulting to "concluída".
		case .starting, .thinking, .usingTool, .compacting, .aborting:
			return "Tarefa concluída em \(workspaceName)."
		}
	}

	public static func notifyFinished(
		state: AgentRunState,
		previous: AgentRunState?,
		workspaceName: String
	) {
		guard isAvailable else { return }
		let content = UNMutableNotificationContent()
		content.title = AppConfiguration.appName
		content.body = body(for: state, previous: previous, workspaceName: workspaceName)
		content.sound = .default

		// `trigger: nil` delivers immediately. The identifier is stable so a
		// second completion replaces the first instead of stacking a pile of
		// banners the user has to dismiss one by one.
		let request = UNNotificationRequest(
			identifier: "\(AppConfiguration.bundleIdentifier).run-finished",
			content: content,
			trigger: nil
		)
		UNUserNotificationCenter.current().add(request) { error in
			if let error {
				logger.error("notification delivery failed: \(error.localizedDescription, privacy: .public)")
			}
		}
	}

	/// Clears a delivered notification once the user has opened the panel.
	public static func clearDelivered() {
		guard isAvailable else { return }
		UNUserNotificationCenter.current().removeDeliveredNotifications(
			withIdentifiers: ["\(AppConfiguration.bundleIdentifier).run-finished"]
		)
	}
}
