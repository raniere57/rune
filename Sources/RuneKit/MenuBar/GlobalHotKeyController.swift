import Carbon.HIToolbox
import Foundation
import os

/// Registers the system-wide shortcut.
///
/// `RegisterEventHotKey` is used rather than an `NSEvent` global monitor
/// because it needs no Accessibility permission — a global monitor would force
/// the user through a TCC prompt just to open a panel.
@MainActor
public final class GlobalHotKeyController {
	private static let signature: OSType = 0x4D_41_47_54 // 'MAGT'

	private let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "ui")
	private var hotKeyRef: EventHotKeyRef?
	private var eventHandler: EventHandlerRef?
	private var handler: (() -> Void)?

	// No `deinit` cleanup: the Carbon handles are non-Sendable, so releasing
	// them from a nonisolated deinit is not expressible without `isolated
	// deinit` (Swift 6.2+), which would pin the package to a very recent
	// toolchain. Every owner calls `unregister()` explicitly instead —
	// `AppDelegate.applicationWillTerminate` and `Diagnostics`.
	public init() {}

	@discardableResult
	public func register(
		_ shortcut: GlobalShortcut = AppConfiguration.defaultGlobalShortcut,
		onTrigger: @escaping () -> Void
	) -> Bool {
		unregister()
		handler = onTrigger

		var eventType = EventTypeSpec(
			eventClass: OSType(kEventClassKeyboard),
			eventKind: UInt32(kEventHotKeyPressed)
		)
		let selfPointer = Unmanaged.passUnretained(self).toOpaque()

		let installStatus = InstallEventHandler(
			GetApplicationEventTarget(),
			{ _, event, userData in
				guard let userData, let event else { return OSStatus(eventNotHandledErr) }
				var hotKeyID = EventHotKeyID()
				let status = GetEventParameter(
					event,
					EventParamName(kEventParamDirectObject),
					EventParamType(typeEventHotKeyID),
					nil,
					MemoryLayout<EventHotKeyID>.size,
					nil,
					&hotKeyID
				)
				guard status == noErr, hotKeyID.signature == GlobalHotKeyController.signature else {
					return OSStatus(eventNotHandledErr)
				}
				let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
				// Carbon delivers on the main run loop; hop explicitly so the
				// UI mutation is unambiguously main-actor isolated.
				DispatchQueue.main.async { MainActor.assumeIsolated { controller.fire() } }
				return noErr
			},
			1,
			&eventType,
			selfPointer,
			&eventHandler
		)
		guard installStatus == noErr else {
			logger.error("InstallEventHandler failed: \(installStatus, privacy: .public)")
			return false
		}

		let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
		let registerStatus = RegisterEventHotKey(
			shortcut.keyCode,
			shortcut.carbonModifiers,
			hotKeyID,
			GetApplicationEventTarget(),
			0,
			&hotKeyRef
		)
		guard registerStatus == noErr else {
			logger.error("RegisterEventHotKey failed: \(registerStatus, privacy: .public)")
			unregister()
			return false
		}
		return true
	}

	public func unregister() {
		if let hotKeyRef {
			UnregisterEventHotKey(hotKeyRef)
			self.hotKeyRef = nil
		}
		if let eventHandler {
			RemoveEventHandler(eventHandler)
			self.eventHandler = nil
		}
	}

	private func fire() { handler?() }
}

extension GlobalShortcut {
	/// Carbon modifier mask for `RegisterEventHotKey`.
	public var carbonModifiers: UInt32 {
		var mask: UInt32 = 0
		if controlKey { mask |= UInt32(controlKey_R__) }
		if optionKey { mask |= UInt32(optionKey_R__) }
		if shiftKey { mask |= UInt32(shiftKey_R__) }
		if commandKey { mask |= UInt32(cmdKey_R__) }
		return mask
	}
}

// Carbon exposes these as `Int` constants with names that collide with the
// `GlobalShortcut` property names, so they are aliased once here.
private let controlKey_R__ = controlKey
private let optionKey_R__ = optionKey
private let shiftKey_R__ = shiftKey
private let cmdKey_R__ = cmdKey
