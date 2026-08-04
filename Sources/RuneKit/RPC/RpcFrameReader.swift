import Foundation

/// Byte stream in, logical `RpcFrame`s out.
///
/// Owns the three stages that must stay in lockstep: newline framing, JSON
/// parsing, and (once protocol v2 is negotiated) `rpc_chunk` reassembly. Kept
/// as a value type with no I/O so the whole pipeline is unit-testable.
public struct RpcFrameReader: Sendable {
	public enum Output: Sendable {
		case frame(RpcFrame)
		/// Recoverable: a malformed line or a chunk-protocol violation. The
		/// stream stays alive, matching OMP's own parse-error behaviour.
		case failure(String)
	}

	private var lines: RpcJsonlDecoder
	private var assembler: RpcChunkAssembler?

	public init(maxLineBytes: Int = 128 * 1024 * 1024) {
		self.lines = RpcJsonlDecoder(maxLineBytes: maxLineBytes)
	}

	/// Enabled only after the `negotiate_protocol` success response. Before
	/// that a `rpc_chunk` frame would be a protocol violation by the server.
	public mutating func enableChunkReassembly(maxReassembledBytes: Int) {
		assembler = RpcChunkAssembler(maxReassembledBytes: maxReassembledBytes)
	}

	public var isReassemblingChunk: Bool { assembler?.isAssembling ?? false }

	public mutating func feed(_ data: Data) -> [Output] {
		var outputs: [Output] = []
		for line in lines.feed(data) {
			outputs += handle(line: line)
		}
		return outputs
	}

	/// Called at EOF. A leftover partial line means the process died mid-frame;
	/// it is reported and discarded rather than parsed.
	public mutating func finish() -> [Output] {
		var outputs: [Output] = []
		if let partial = lines.flush() {
			outputs.append(.failure("stream ended mid-frame, discarded \(partial.count) trailing bytes"))
		}
		if assembler?.isAssembling == true {
			outputs.append(.failure("stream ended during rpc_chunk reassembly"))
			assembler?.reset()
		}
		return outputs
	}

	private mutating func handle(line: Data) -> [Output] {
		guard let json = try? JSONDecoder().decode(JSONValue.self, from: line) else {
			return [.failure("invalid JSON line (\(line.count) bytes)")]
		}

		guard json["type"]?.stringValue == "rpc_chunk" else {
			return [.frame(RpcFrame.make(from: json))]
		}

		guard assembler != nil else {
			return [.failure("received rpc_chunk before protocol v2 was negotiated")]
		}
		guard let chunk = RpcChunk(json: json) else {
			assembler?.reset()
			return [.failure("malformed rpc_chunk frame")]
		}

		do {
			guard let payload = try assembler?.accept(chunk) else { return [] }
			guard let text = String(data: payload, encoding: .utf8) else {
				return [.failure("reassembled rpc_chunk payload is not valid UTF-8")]
			}
			guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
				return [.failure("reassembled rpc_chunk payload is not valid JSON")]
			}
			return [.frame(RpcFrame.make(from: value))]
		} catch {
			return [.failure(String(describing: error))]
		}
	}
}
