import Foundation
import Testing

@testable import RuneKit

@Suite("Free model fallback")
struct FreeModelFallbackTests {
	/// Mirrors the shape `get_available_models` actually returns — confirmed
	/// against omp 17.2.6, where `cost` carries four fields and `contextWindow`
	/// is sometimes absent.
	private func model(_ id: String, contextWindow: Double?, cost: Double) -> JSONValue {
		var fields: [String: JSONValue] = [
			"id": .string(id),
			"provider": .string(AppConfiguration.providerId),
			"cost": .object([
				"input": .number(cost),
				"output": .number(cost),
				"cacheRead": .number(0),
				"cacheWrite": .number(0),
			]),
		]
		if let contextWindow { fields["contextWindow"] = .number(contextWindow) }
		return .object(fields)
	}

	@Test("the roomiest free model wins")
	func picksLargestFreeContext() {
		let chosen = AgentCoordinator.freeFallback(in: [
			model("big-pickle", contextWindow: 200_000, cost: 0),
			model("nemotron-3-ultra-free", contextWindow: 1_000_000, cost: 0),
			model("ling-3.0-flash-free", contextWindow: 262_144, cost: 0),
		])
		#expect(chosen?["id"]?.stringValue == "nemotron-3-ultra-free")
	}

	@Test("a paid model is never chosen — a retired model must not become a bill")
	func ignoresPaidModels() {
		let chosen = AgentCoordinator.freeFallback(in: [
			model("claude-opus-5", contextWindow: 2_000_000, cost: 15),
			model("deepseek-v4-flash-free", contextWindow: 200_000, cost: 0),
		])
		#expect(chosen?["id"]?.stringValue == "deepseek-v4-flash-free")
	}

	@Test("output cost alone disqualifies a model")
	func outputCostCounts() {
		let mixed = JSONValue.object([
			"id": .string("half-free"),
			"cost": .object(["input": .number(0), "output": .number(2)]),
			"contextWindow": .number(9_000_000),
		])
		#expect(AgentCoordinator.freeFallback(in: [mixed]) == nil)
	}

	@Test("a missing context window sorts last instead of crashing")
	func missingContextWindow() {
		let chosen = AgentCoordinator.freeFallback(in: [
			model("longcat-2.0-free", contextWindow: nil, cost: 0),
			model("big-pickle", contextWindow: 200_000, cost: 0),
		])
		#expect(chosen?["id"]?.stringValue == "big-pickle")
	}

	@Test("ties break by id, so the choice is the same on every launch")
	func deterministicTieBreak() {
		let models = [
			model("zeta-free", contextWindow: 200_000, cost: 0),
			model("alpha-free", contextWindow: 200_000, cost: 0),
		]
		#expect(AgentCoordinator.freeFallback(in: models)?["id"]?.stringValue == "alpha-free")
		#expect(AgentCoordinator.freeFallback(in: models.reversed())?["id"]?.stringValue == "alpha-free")
	}

	@Test("nothing free means nothing to fall back to")
	func noFreeModel() {
		#expect(AgentCoordinator.freeFallback(in: [model("paid", contextWindow: 1000, cost: 3)]) == nil)
	}
}

@MainActor
@Suite("Boot with the configured model gone")
struct ModelRetirementTests {
	private func makeCoordinator(transport: FakeOmpTransport) -> AgentCoordinator {
		AgentCoordinator(
			transport: transport,
			defaults: UserDefaults(suiteName: "rune.fallback.\(UUID().uuidString)")!,
			idleInterval: 3600,
			apiKeyProvider: { "test-key" }
		)
	}

	@Test("the app still boots, on another free model, and says so")
	func fallsBackLoudly() async throws {
		let transport = FakeOmpTransport()
		// The configured model is gone; two free ones remain.
		transport.catalogue = ["big-pickle", "nemotron-3-ultra-free"]
		transport.contextWindows = ["big-pickle": 200_000, "nemotron-3-ultra-free": 1_000_000]
		let coordinator = makeCoordinator(transport: transport)

		try await coordinator.ensureRunning()

		#expect(coordinator.runState == .ready)
		#expect(coordinator.activeModelDescription?.hasSuffix("nemotron-3-ultra-free") == true)
		// Never silent: the answer quality changes and the user has to know.
		let notices = coordinator.items.compactMap { item -> NoticeEntry? in
			guard case .notice(let entry) = item else { return nil }
			return entry
		}
		#expect(notices.contains { $0.level == .warning && $0.text.contains("nemotron-3-ultra-free") })
	}

	@Test("a catalogue with no free model at all still fails the boot")
	func noFallbackAvailable() async throws {
		let transport = FakeOmpTransport()
		transport.catalogue = ["claude-opus-5"]
		transport.modelCost = 15
		let coordinator = makeCoordinator(transport: transport)

		await #expect(throws: AgentError.self) {
			try await coordinator.ensureRunning()
		}
	}

	@Test("when the configured model is present nothing changes")
	func normalBootIsUnaffected() async throws {
		let transport = FakeOmpTransport()
		let coordinator = makeCoordinator(transport: transport)

		try await coordinator.ensureRunning()

		#expect(coordinator.activeModelDescription == AppConfiguration.primaryModelSelector)
		#expect(!coordinator.items.contains { if case .notice = $0 { return true } else { return false } })
	}
}

@Suite("Dropped items")
struct DroppedItemsTests {
	@Test("a directory becomes a folder attachment, a file becomes a file")
	func classifiesByFileSystem() throws {
		let directory = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("rune-drop-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: directory) }

		let file = directory.appendingPathComponent("nota.txt")
		try "oi".write(to: file, atomically: true, encoding: .utf8)

		#expect(DroppedItems.attachment(forFileAt: directory).isFolder)
		#expect(DroppedItems.attachment(forFileAt: file).fileURL == file.standardizedFileURL)
		#expect(!DroppedItems.attachment(forFileAt: file).isFolder)
	}

	@Test("PNG bytes pass through untouched")
	func pngPassesThrough() {
		let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
		let attachment = DroppedItems.attachment(forImageData: png)
		#expect(attachment?.image?.mimeType == "image/png")
		#expect(attachment?.image?.base64Data == png.base64EncodedString())
	}

	@Test("JPEG bytes pass through untouched")
	func jpegPassesThrough() {
		let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
		#expect(DroppedItems.attachment(forImageData: jpeg)?.image?.mimeType == "image/jpeg")
	}

	@Test("bytes no image decoder understands are refused instead of sent as garbage")
	func unreadableDataIsRefused() {
		#expect(DroppedItems.attachment(forImageData: Data("nem imagem nem nada".utf8)) == nil)
	}

	@Test("the composer accepts exactly the two types the pipeline can handle")
	func acceptedTypes() {
		#expect(DroppedItems.acceptedTypes.count == 2)
	}
}

