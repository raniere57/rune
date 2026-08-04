import Foundation
import Testing

@testable import MenuAgentKit

@Suite("JSONL framing")
struct RpcJsonlDecoderTests {
	private func text(_ lines: [Data]) -> [String] {
		lines.map { String(data: $0, encoding: .utf8) ?? "<invalid>" }
	}

	@Test("a single complete line is emitted once")
	func completeLine() {
		var decoder = RpcJsonlDecoder()
		let lines = decoder.feed(Data((#"{"type":"ready"}"# + "\n").utf8))
		#expect(text(lines) == [#"{"type":"ready"}"#])
		#expect(decoder.pendingByteCount == 0)
	}

	@Test("a line split across several reads is buffered until its newline")
	func splitLine() {
		var decoder = RpcJsonlDecoder()
		#expect(decoder.feed(Data(#"{"type":"re"# .utf8)).isEmpty)
		#expect(decoder.feed(Data(#"ady","protocolVersion":1"# .utf8)).isEmpty)
		let lines = decoder.feed(Data("}\n".utf8))
		#expect(text(lines) == [#"{"type":"ready","protocolVersion":1}"#])
	}

	@Test("several lines in one read are emitted in order")
	func multipleLinesInOneChunk() {
		var decoder = RpcJsonlDecoder()
		let payload = "{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"
		#expect(text(decoder.feed(Data(payload.utf8))) == [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
	}

	@Test("a trailing partial line survives a batch that also closed earlier lines")
	func mixedCompleteAndPartial() {
		var decoder = RpcJsonlDecoder()
		#expect(text(decoder.feed(Data("{\"a\":1}\n{\"b\":".utf8))) == [#"{"a":1}"#])
		#expect(decoder.pendingByteCount > 0)
		#expect(text(decoder.feed(Data("2}\n".utf8))) == [#"{"b":2}"#])
	}

	@Test("a multi-byte UTF-8 scalar split across reads is reassembled intact")
	func splitUTF8Scalar() {
		var decoder = RpcJsonlDecoder()
		// "ção" — the ç is two bytes (0xC3 0xA7); cut between them.
		let full = Array(#"{"m":"ação"}"# .utf8)
		let cut = full.firstIndex(of: 0xC3)!
		#expect(decoder.feed(Data(full[..<(cut + 1)])).isEmpty)
		let lines = decoder.feed(Data(full[(cut + 1)...]) + Data("\n".utf8))
		#expect(text(lines) == [#"{"m":"ação"}"#])
	}

	@Test("a 4-byte emoji split across three reads survives")
	func splitEmoji() {
		var decoder = RpcJsonlDecoder()
		let bytes = Array(#"{"m":"🚀"}"# .utf8)
		#expect(decoder.feed(Data(bytes[..<7])).isEmpty)
		#expect(decoder.feed(Data(bytes[7..<9])).isEmpty)
		let lines = decoder.feed(Data(bytes[9...]) + Data("\n".utf8))
		#expect(text(lines) == [#"{"m":"🚀"}"#])
	}

	@Test("empty lines are dropped, matching RPC mode's non-empty-line parsing")
	func emptyLinesDropped() {
		var decoder = RpcJsonlDecoder()
		#expect(text(decoder.feed(Data("\n\n{\"a\":1}\n\n".utf8))) == [#"{"a":1}"#])
	}

	@Test("CRLF terminators are normalised")
	func carriageReturnStripped() {
		var decoder = RpcJsonlDecoder()
		#expect(text(decoder.feed(Data("{\"a\":1}\r\n".utf8))) == [#"{"a":1}"#])
	}

	@Test("flush returns the unterminated remainder exactly once")
	func flushReturnsPartial() {
		var decoder = RpcJsonlDecoder()
		_ = decoder.feed(Data("{\"a\":1}\n{\"b\"".utf8))
		#expect(String(data: decoder.flush()!, encoding: .utf8) == #"{"b""#)
		#expect(decoder.flush() == nil)
	}

	@Test("an oversized unterminated line is dropped instead of growing forever")
	func overlongLineDropped() {
		var decoder = RpcJsonlDecoder(maxLineBytes: 32)
		#expect(decoder.feed(Data(String(repeating: "x", count: 100).utf8)).isEmpty)
		#expect(decoder.droppedOverlongLines == 1)
		#expect(decoder.pendingByteCount == 0)
	}
}

@Suite("Frame reader")
struct RpcFrameReaderTests {
	@Test("an invalid line is reported and the next valid line still parses")
	func recoversFromInvalidLine() {
		var reader = RpcFrameReader()
		let outputs = reader.feed(Data("not json\n{\"type\":\"agent_start\"}\n".utf8))
		#expect(outputs.count == 2)
		guard case .failure = outputs[0] else { Issue.record("expected failure"); return }
		guard case .frame(.agentEvent(.agentStart)) = outputs[1] else {
			Issue.record("expected agent_start")
			return
		}
	}

	@Test("EOF with a partial line in the buffer reports a truncated stream")
	func eofWithPartialLine() {
		var reader = RpcFrameReader()
		_ = reader.feed(Data("{\"type\":\"age".utf8))
		let outputs = reader.finish()
		#expect(outputs.count == 1)
		guard case .failure(let message) = outputs[0] else { Issue.record("expected failure"); return }
		#expect(message.contains("mid-frame"))
	}

	@Test("a ready frame exposes the advertised protocol versions and limits")
	func parsesReady() {
		var reader = RpcFrameReader()
		let line = #"{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1,2],"maxFrameBytes":1048576,"maxReassembledFrameBytes":67108864}"#
		let outputs = reader.feed(Data((line + "\n").utf8))
		guard case .frame(.ready(let ready)) = outputs.first else { Issue.record("expected ready"); return }
		#expect(ready.supportsV2)
		#expect(ready.maxFrameBytes == 1_048_576)
		#expect(ready.maxReassembledFrameBytes == 67_108_864)
	}

	@Test("a chunk arriving before v2 negotiation is rejected")
	func chunkBeforeNegotiation() {
		var reader = RpcFrameReader()
		let line = #"{"type":"rpc_chunk","chunkId":"c1","index":0,"count":1,"byteLength":2,"data":"e30="}"#
		let outputs = reader.feed(Data((line + "\n").utf8))
		guard case .failure(let message) = outputs.first else { Issue.record("expected failure"); return }
		#expect(message.contains("before protocol v2"))
	}

	@Test("a chunked response is reassembled into one logical frame")
	func reassemblesChunkedResponse() throws {
		var reader = RpcFrameReader()
		reader.enableChunkReassembly(maxReassembledBytes: 1024)

		let payload = #"{"id":"req_1","type":"response","command":"get_state","success":true}"#
		let bytes = Array(payload.utf8)
		let split = bytes.count / 2
		let parts = [Data(bytes[..<split]), Data(bytes[split...])]

		var outputs: [RpcFrameReader.Output] = []
		for (index, part) in parts.enumerated() {
			let line = """
			{"type":"rpc_chunk","chunkId":"c1","index":\(index),"count":2,\
			"byteLength":\(bytes.count),"data":"\(part.base64EncodedString())"}
			"""
			outputs += reader.feed(Data((line + "\n").utf8))
		}

		#expect(outputs.count == 1)
		guard case .frame(.response(let response)) = outputs[0] else { Issue.record("expected response"); return }
		#expect(response.command == "get_state")
		#expect(response.success)
	}
}
