import Foundation
import ServiceManagement
import os

/// Registers the app with `launchd` so it is back in the menu bar after a
/// reboot.
///
/// `SMAppService.mainApp` needs no helper app, no login item bundle, and no
/// process of its own — `launchd` does the work — so an enabled toggle costs
/// nothing while the app is idle. That is the only reason this belongs in an app
/// with a 29 MB budget.
///
/// Only meaningful from a real bundle: the SPM binary and the test runner have
/// nothing for `launchd` to register, so everything here reports unavailable
/// rather than trapping.
public enum LaunchAtLogin {
	private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "lifecycle")

	public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

	public static var isEnabled: Bool {
		guard isAvailable else { return false }
		return SMAppService.mainApp.status == .enabled
	}

	/// Flips the registration. Returns the state afterwards, which is what the
	/// menu item shows — a failed request must not leave a checkmark lying about
	/// what `launchd` actually knows.
	@discardableResult
	public static func toggle() -> Bool {
		guard isAvailable else { return false }
		do {
			if isEnabled {
				try SMAppService.mainApp.unregister()
			} else {
				try SMAppService.mainApp.register()
			}
		} catch {
			logger.error("launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
		}
		return isEnabled
	}
}
