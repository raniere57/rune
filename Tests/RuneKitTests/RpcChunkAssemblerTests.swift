import Foundation
import Testing

@testable import RuneKit

@Suite("rpc_chunk reassembly")
struct RpcChunkAssemblerTests {
	private func chunks(
		id: String = "c1",
		payload: String,
		parts: Int
	) -> [RpcChunk] {
		let bytes = Array(payload.utf8)
		let size = Int((Double(bytes.count) / Double(parts)).rounded(.up))
		return (0..<parts).map { index in
			let start = index * size
			let end = min(start + size, bytes.count)
			let slice = start < end ? Data(bytes[start..<end]) : Data()
			return RpcChunk(
				chunkId: id,
				index: index,
				count: parts,
				byteLength: bytes.count,
				data: slice.base64EncodedString()
			)
		}
	}

	@Test("a valid sequence yields the payload only on the last chunk")
	func validSequence() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let payload = "{\"hello\":\"world\",\"n\":12345}"
		let sequence = chunks(payload: payload, parts: 3)

		#expect(try assembler.accept(sequence[0]) == nil)
		#expect(assembler.isAssembling)
		#expect(try assembler.accept(sequence[1]) == nil)
		let result = try assembler.accept(sequence[2])
		#expect(String(data: try #require(result), encoding: .utf8) == payload)
		#expect(!assembler.isAssembling)
	}

	@Test("a single-chunk sequence completes immediately")
	func singleChunk() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let payload = "{}"
		let result = try assembler.accept(chunks(payload: payload, parts: 1)[0])
		#expect(String(data: try #require(result), encoding: .utf8) == payload)
	}

	@Test("a skipped index is rejected instead of silently truncating")
	func missingChunk() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let sequence = chunks(payload: "abcdefghij", parts: 3)
		_ = try assembler.accept(sequence[0])
		#expect(throws: RpcChunkAssembler.Failure.outOfOrder(chunkId: "c1", expected: 1, received: 2)) {
			_ = try assembler.accept(sequence[2])
		}
		#expect(!assembler.isAssembling)
	}

	@Test("a repeated index is rejected")
	func duplicateIndex() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let sequence = chunks(payload: "abcdefghij", parts: 3)
		_ = try assembler.accept(sequence[0])
		_ = try assembler.accept(sequence[1])
		#expect(throws: RpcChunkAssembler.Failure.outOfOrder(chunkId: "c1", expected: 2, received: 1)) {
			_ = try assembler.accept(sequence[1])
		}
	}

	@Test("a second sequence interleaved mid-flight is rejected")
	func interleavedIds() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let first = chunks(id: "c1", payload: "abcdefghij", parts: 3)
		let second = chunks(id: "c2", payload: "klmnopqrst", parts: 3)
		_ = try assembler.accept(first[0])
		#expect(throws: RpcChunkAssembler.Failure.interleaved(active: "c1", incoming: "c2")) {
			_ = try assembler.accept(second[1])
		}
	}

	@Test("a new sequence starting before the active one finished is reported as interrupted")
	func interruptedSequence() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let first = chunks(id: "c1", payload: "abcdefghij", parts: 3)
		let second = chunks(id: "c2", payload: "klmnopqrst", parts: 3)
		_ = try assembler.accept(first[0])
		#expect(throws: RpcChunkAssembler.Failure.interrupted(chunkId: "c1", expectedIndex: 1)) {
			_ = try assembler.accept(second[0])
		}
	}

	@Test("a chunk with no active sequence is rejected as orphaned")
	func orphanChunk() {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let sequence = chunks(payload: "abcdefghij", parts: 3)
		#expect(throws: RpcChunkAssembler.Failure.orphanChunk(chunkId: "c1", index: 1)) {
			_ = try assembler.accept(sequence[1])
		}
	}

	@Test("a byteLength that disagrees with the assembled bytes is rejected")
	func sizeMismatch() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let data = Data("abcd".utf8).base64EncodedString()
		let chunk = RpcChunk(chunkId: "c1", index: 0, count: 1, byteLength: 99, data: data)
		#expect(throws: RpcChunkAssembler.Failure.sizeMismatch(chunkId: "c1", expected: 99, received: 4)) {
			_ = try assembler.accept(chunk)
		}
	}

	@Test("count or byteLength changing mid-sequence is rejected")
	func metadataMismatch() throws {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let sequence = chunks(payload: "abcdefghij", parts: 2)
		_ = try assembler.accept(sequence[0])
		let tampered = RpcChunk(
			chunkId: "c1",
			index: 1,
			count: 2,
			byteLength: 999,
			data: sequence[1].data
		)
		#expect(throws: RpcChunkAssembler.Failure.metadataMismatch(chunkId: "c1")) {
			_ = try assembler.accept(tampered)
		}
	}

	@Test("a payload above the advertised reassembly ceiling is rejected up front")
	func exceedsLimit() {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 16)
		let chunk = RpcChunk(chunkId: "c1", index: 0, count: 1, byteLength: 64, data: "")
		#expect(throws: RpcChunkAssembler.Failure.tooLarge(byteLength: 64, limit: 16)) {
			_ = try assembler.accept(chunk)
		}
	}

	@Test("non-base64 chunk data is rejected")
	func invalidBase64() {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let chunk = RpcChunk(chunkId: "c1", index: 0, count: 1, byteLength: 4, data: "!!!!not base64!!!!")
		#expect(throws: RpcChunkAssembler.Failure.invalidBase64(chunkId: "c1", index: 0)) {
			_ = try assembler.accept(chunk)
		}
	}

	@Test("a zero or negative count is rejected")
	func invalidCount() {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let chunk = RpcChunk(chunkId: "c1", index: 0, count: 0, byteLength: 4, data: "YWJjZA==")
		#expect(throws: RpcChunkAssembler.Failure.self) {
			_ = try assembler.accept(chunk)
		}
	}

	@Test("an index outside the declared count is rejected")
	func indexOutOfRange() {
		var assembler = RpcChunkAssembler(maxReassembledBytes: 1024)
		let chunk = RpcChunk(chunkId: "c1", index: 5, count: 2, byteLength: 4, data: "YWJjZA==")
		#expect(throws: RpcChunkAssembler.Failure.self) {
			_ = try assembler.accept(chunk)
		}
	}
}
