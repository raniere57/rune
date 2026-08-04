import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import MenuAgentKit

/// Scriptable pasteboard so interpretation can be tested without touching the
/// user's real clipboard.
struct StubPasteboard: PasteboardReading {
	var availableTypes: [NSPasteboard.PasteboardType] = []
	var payloads: [NSPasteboard.PasteboardType: Data] = [:]
	var text: String?
	var urls: [URL] = []

	func data(forType type: NSPasteboard.PasteboardType) -> Data? { payloads[type] }
	func string() -> String? { text }
	func fileURLs() -> [URL] { urls }
}

@Suite("Clipboard interpretation")
struct ClipboardInterpreterTests {
	private let interpreter = ClipboardInterpreter()

	private func pngData(size: Int = 4) -> Data {
		let image = NSImage(size: NSSize(width: size, height: size))
		image.lockFocus()
		NSColor.systemPink.setFill()
		NSRect(x: 0, y: 0, width: size, height: size).fill()
		image.unlockFocus()
		let tiff = image.tiffRepresentation!
		return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
	}

	private func tiffData(size: Int = 4) -> Data {
		let image = NSImage(size: NSSize(width: size, height: size))
		image.lockFocus()
		NSColor.systemTeal.setFill()
		NSRect(x: 0, y: 0, width: size, height: size).fill()
		image.unlockFocus()
		return image.tiffRepresentation!
	}

	@Test("an empty pasteboard yields nothing")
	func emptyPasteboard() {
		#expect(interpreter.interpret(StubPasteboard()) == .empty)
	}

	@Test("plain text is left for the text view to insert")
	func plainText() {
		let board = StubPasteboard(availableTypes: [.string], text: "olá")
		#expect(interpreter.interpret(board) == .text("olá"))
	}

	@Test("PNG data becomes an image attachment without re-encoding")
	func pngAttachment() throws {
		let data = pngData()
		let board = StubPasteboard(availableTypes: [.png], payloads: [.png: data])

		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected an attachment")
			return
		}
		#expect(staged.count == 1)
		let image = try #require(staged[0].image)
		#expect(image.mimeType == "image/png")
		#expect(Data(base64Encoded: image.base64Data) == data)
	}

	@Test("JPEG data is passed through with its own mime type")
	func jpegAttachment() throws {
		let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
		let rep = NSBitmapImageRep(data: tiffData())!
		let jpeg = rep.representation(using: .jpeg, properties: [:])!
		let board = StubPasteboard(availableTypes: [jpegType], payloads: [jpegType: jpeg])

		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected an attachment")
			return
		}
		#expect(staged[0].image?.mimeType == "image/jpeg")
	}

	@Test("TIFF from a screenshot is converted to PNG")
	func tiffConvertedToPNG() throws {
		let board = StubPasteboard(availableTypes: [.tiff], payloads: [.tiff: tiffData()])

		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected an attachment")
			return
		}
		let image = try #require(staged[0].image)
		#expect(image.mimeType == "image/png")
		let decoded = try #require(Data(base64Encoded: image.base64Data))
		// PNG magic number.
		#expect(decoded.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
	}

	@Test("image data wins over a filename the same paste may carry")
	func imageBeatsFileURL() {
		let board = StubPasteboard(
			availableTypes: [.png, .fileURL],
			payloads: [.png: pngData()],
			urls: [URL(fileURLWithPath: "/tmp/captura.png")]
		)
		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected an attachment")
			return
		}
		#expect(staged[0].image != nil)
	}

	@Test("a copied file becomes a file attachment carrying its absolute path")
	func fileAttachment() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("menuagent-\(UUID().uuidString).txt")
		try Data("x".utf8).write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }

		let board = StubPasteboard(availableTypes: [.fileURL], urls: [url])
		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected an attachment")
			return
		}
		#expect(staged.count == 1)
		#expect(!staged[0].isFolder)
		#expect(staged[0].fileURL == url.standardizedFileURL)
		#expect(staged[0].label == url.lastPathComponent)
	}

	@Test("a copied folder is recognised as a folder, not a file")
	func folderAttachment() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("menuagent-dir-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: url) }

		let board = StubPasteboard(availableTypes: [.fileURL], urls: [url])
		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected an attachment")
			return
		}
		#expect(staged[0].isFolder)
	}

	@Test("several copied files all become attachments")
	func multipleFiles() throws {
		let directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("menuagent-multi-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let urls = try (0..<3).map { index -> URL in
			let url = directory.appendingPathComponent("f\(index).txt")
			try Data("x".utf8).write(to: url)
			return url
		}

		let board = StubPasteboard(availableTypes: [.fileURL], urls: urls)
		guard case .attachments(let staged) = interpreter.interpret(board) else {
			Issue.record("expected attachments")
			return
		}
		#expect(staged.count == 3)
		#expect(staged.allSatisfy { !$0.isFolder })
	}

	@Test("a file paste wins over the text representation Finder also provides")
	func fileBeatsText() throws {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("menuagent-\(UUID().uuidString).txt")
		try Data("x".utf8).write(to: url)
		defer { try? FileManager.default.removeItem(at: url) }

		let board = StubPasteboard(availableTypes: [.fileURL, .string], text: url.path, urls: [url])
		guard case .attachments = interpreter.interpret(board) else {
			Issue.record("expected attachments, not text")
			return
		}
	}
}
