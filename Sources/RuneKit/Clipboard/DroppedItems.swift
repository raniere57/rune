import AppKit
import Foundation
import UniformTypeIdentifiers

/// Turns a drag-and-drop payload into the same `PendingAttachment` values a
/// paste produces.
///
/// Dropping a file on the composer is the most natural gesture on this platform
/// and the whole attachment pipeline already existed for `⌘V` — only the second
/// entry point was missing. Nothing here runs unless a drag is in progress, so
/// idle cost is zero.
public enum DroppedItems {
	/// Types the composer accepts. `fileURL` covers files and folders from
	/// Finder; `image` covers a drag straight out of a screenshot tool or a
	/// browser, which carries pixels but no path.
	public static let acceptedTypes: [UTType] = [.fileURL, .image]

	/// Classifies a dropped file by asking the file system, the same way the
	/// clipboard path does — a folder becomes the workspace, a file becomes an
	/// attachment.
	public static func attachment(
		forFileAt url: URL,
		fileManager: FileManager = .default
	) -> PendingAttachment {
		var isDirectory: ObjCBool = false
		fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
		return .path(url.standardizedFileURL, isDirectory: isDirectory.boolValue)
	}

	/// Wraps raw image bytes, re-encoding anything that is not already PNG or
	/// JPEG — a drag from Preview arrives as TIFF, which no model accepts.
	public static func attachment(forImageData data: Data) -> PendingAttachment? {
		if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
			return .image(
				RpcImage(mimeType: "image/png", base64Data: data.base64EncodedString()),
				label: "Imagem PNG"
			)
		}
		if data.starts(with: [0xFF, 0xD8, 0xFF]) {
			return .image(
				RpcImage(mimeType: "image/jpeg", base64Data: data.base64EncodedString()),
				label: "Imagem JPEG"
			)
		}
		guard let png = ClipboardInterpreter.convertToPNG(data) else { return nil }
		return .image(
			RpcImage(mimeType: "image/png", base64Data: png.base64EncodedString()),
			label: "Imagem"
		)
	}
}
