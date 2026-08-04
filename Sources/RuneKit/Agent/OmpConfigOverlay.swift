import Foundation
import os

/// Writes the one-run config overlay handed to `omp --config`.
///
/// Only carries settings that have no CLI flag. Today that is the `vision`
/// model role, which is what lets an image reach a model when the primary one
/// is text-only: OMP exposes its `inspect_image` tool automatically for a model
/// with no native image input, and that tool resolves `modelRoles.vision`.
/// Without the role it fails with *"does not support image input"*.
///
/// Written fresh on every launch, into caches — it is derived from
/// `AppConfiguration`, never edited by hand, and must not survive a change to
/// the constants it came from.
enum OmpConfigOverlay {
	private static let logger = Logger(subsystem: AppConfiguration.bundleIdentifier, category: "process")

	/// Returns the overlay path, or `nil` when there is nothing to configure.
	static func write(
		visionModelSelector: String? = AppConfiguration.visionModelSelector,
		fileManager: FileManager = .default
	) -> URL? {
		guard let visionModelSelector, !visionModelSelector.isEmpty else { return nil }

		guard let caches = try? fileManager.url(
			for: .cachesDirectory,
			in: .userDomainMask,
			appropriateFor: nil,
			create: true
		) else { return nil }

		let directory = caches.appendingPathComponent(AppConfiguration.bundleIdentifier, isDirectory: true)
		let file = directory.appendingPathComponent("omp-overlay.yml")

		do {
			try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
			try body(visionModelSelector: visionModelSelector).write(to: file, atomically: true, encoding: .utf8)
			return file
		} catch {
			// A missing overlay only costs image support, so the launch goes on.
			logger.error("could not write the omp config overlay: \(error.localizedDescription, privacy: .public)")
			return nil
		}
	}

	/// The selector is quoted because it contains a `/`, which bare YAML would
	/// still parse but which reads ambiguously.
	static func body(visionModelSelector: String) -> String {
		[
			"# Gerado pelo \(AppConfiguration.appName) a cada lançamento — não edite.",
			"modelRoles:",
			"  vision: \"\(visionModelSelector)\"",
			"",
		].joined(separator: "\n")
	}
}
