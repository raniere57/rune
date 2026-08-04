import AppKit
import Foundation
import UniformTypeIdentifiers

/// The subset of `NSPasteboard` this feature needs, so interpretation is
/// testable without a live pasteboard.
public protocol PasteboardReading: Sendable {
	var availableTypes: [NSPasteboard.PasteboardType] { get }
	func data(forType type: NSPasteboard.PasteboardType) -> Data?
	func string() -> String?
	func fileURLs() -> [URL]
}

/// What `Cmd+V` produced.
public enum ClipboardContent: Sendable, Equatable {
	case empty
	case text(String)
	case attachments([PendingAttachment])
	/// A file/folder paste that also carried a text representation.
	case mixed(text: String, attachments: [PendingAttachment])
}

/// Decides what a paste means.
///
/// Order matters: file URLs win over the text representation Finder also puts
/// on the pasteboard, and image data wins over the filename a screenshot tool
/// may include, so `Cmd+V` on a screenshot stages an image rather than a path.
public struct ClipboardInterpreter {
	private var fileManager: FileManager { .default }

	public init() {}

	public func interpret(_ pasteboard: PasteboardReading) -> ClipboardContent {
		if let image = imageAttachment(from: pasteboard) {
			return .attachments([image])
		}

		let urls = pasteboard.fileURLs()
		if !urls.isEmpty {
			let attachments = urls.map { url -> PendingAttachment in
				var isDirectory: ObjCBool = false
				fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
				return .path(url.standardizedFileURL, isDirectory: isDirectory.boolValue)
			}
			return .attachments(attachments)
		}

		if let text = pasteboard.string(), !text.isEmpty {
			return .text(text)
		}

		return .empty
	}

	// MARK: - Images

	/// Produces `{ type: "image", mimeType, data }` content. PNG and JPEG pass
	/// through untouched; anything else `NSBitmapImageRep` can read (TIFF from
	/// a screenshot, PDF from Preview) is re-encoded as PNG.
	private func imageAttachment(from pasteboard: PasteboardReading) -> PendingAttachment? {
		let types = Set(pasteboard.availableTypes)

		if types.contains(.png), let data = pasteboard.data(forType: .png) {
			return .image(
				RpcImage(mimeType: "image/png", base64Data: data.base64EncodedString()),
				label: "Imagem PNG"
			)
		}

		let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
		if types.contains(jpegType), let data = pasteboard.data(forType: jpegType) {
			return .image(
				RpcImage(mimeType: "image/jpeg", base64Data: data.base64EncodedString()),
				label: "Imagem JPEG"
			)
		}

		for type in [NSPasteboard.PasteboardType.tiff,
		             NSPasteboard.PasteboardType(UTType.pdf.identifier)] where types.contains(type) {
			guard let data = pasteboard.data(forType: type),
			      let png = Self.convertToPNG(data)
			else { continue }
			return .image(
				RpcImage(mimeType: "image/png", base64Data: png.base64EncodedString()),
				label: "Imagem"
			)
		}

		return nil
	}

	static func convertToPNG(_ data: Data) -> Data? {
		guard let representation = NSBitmapImageRep(data: data) else { return nil }
		return representation.representation(using: .png, properties: [:])
	}
}

// MARK: - Live pasteboard

public struct SystemPasteboard: PasteboardReading, @unchecked Sendable {
	private let pasteboard: NSPasteboard

	public init(pasteboard: NSPasteboard = .general) {
		self.pasteboard = pasteboard
	}

	public var availableTypes: [NSPasteboard.PasteboardType] { pasteboard.types ?? [] }

	public func data(forType type: NSPasteboard.PasteboardType) -> Data? {
		pasteboard.data(forType: type)
	}

	public func string() -> String? {
		pasteboard.string(forType: .string)
	}

	public func fileURLs() -> [URL] {
		let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
		guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
		else { return [] }
		return objects.filter(\.isFileURL)
	}
}
