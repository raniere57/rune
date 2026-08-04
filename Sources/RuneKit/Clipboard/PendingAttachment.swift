import Foundation

/// Something staged in the composer, waiting to be sent with the next message.
public struct PendingAttachment: Identifiable, Sendable, Equatable {
	public enum Payload: Sendable, Equatable {
		/// Already converted to a format `ImageContent` accepts.
		case image(RpcImage)
		case file(URL)
		case folder(URL)
	}

	public let id: String
	public let payload: Payload
	public let label: String

	public init(id: String = UUID().uuidString, payload: Payload, label: String) {
		self.id = id
		self.payload = payload
		self.label = label
	}

	public var image: RpcImage? {
		guard case .image(let value) = payload else { return nil }
		return value
	}

	/// Absolute path handed to OMP so it can use its own read/glob tools rather
	/// than having the file inlined into the prompt.
	public var fileURL: URL? {
		switch payload {
		case .file(let url), .folder(let url): return url
		case .image: return nil
		}
	}

	public var isFolder: Bool {
		if case .folder = payload { return true }
		return false
	}

	public var summary: AttachmentSummary {
		let kind: AttachmentSummary.Kind
		switch payload {
		case .image: kind = .image
		case .file: kind = .file
		case .folder: kind = .folder
		}
		return AttachmentSummary(id: id, kind: kind, label: label)
	}

	static func image(_ image: RpcImage, label: String) -> PendingAttachment {
		PendingAttachment(payload: .image(image), label: label)
	}

	static func path(_ url: URL, isDirectory: Bool) -> PendingAttachment {
		PendingAttachment(
			payload: isDirectory ? .folder(url) : .file(url),
			label: url.lastPathComponent
		)
	}
}
