import Foundation

/// One `rpc_chunk` frame from protocol v2.
public struct RpcChunk: Sendable, Equatable {
	public let chunkId: String
	public let index: Int
	public let count: Int
	public let byteLength: Int
	public let data: String

	public init(chunkId: String, index: Int, count: Int, byteLength: Int, data: String) {
		self.chunkId = chunkId
		self.index = index
		self.count = count
		self.byteLength = byteLength
		self.data = data
	}

	init?(json: JSONValue) {
		guard let chunkId = json["chunkId"]?.stringValue,
		      let index = json["index"]?.intValue,
		      let count = json["count"]?.intValue,
		      let byteLength = json["byteLength"]?.intValue,
		      let data = json["data"]?.stringValue
		else { return nil }
		self.init(chunkId: chunkId, index: index, count: count, byteLength: byteLength, data: data)
	}
}

/// Reassembles the `rpc_chunk` sequences protocol v2 uses for oversized stdout
/// objects.
///
/// The wire contract (docs/rpc.md, "Transport and Framing") says clients MUST
/// validate `chunkId`, `index`, `count`, and `byteLength`, reject interleaved
/// or interrupted sequences, and enforce the advertised reassembly limit. Every
/// one of those is a distinct error here rather than a silent reset, because a
/// silently dropped chunk would surface much later as a truncated JSON parse
/// failure with no way to attribute it.
public struct RpcChunkAssembler: Sendable {
	public enum Failure: Error, Equatable, CustomStringConvertible {
		case invalidMetadata(String)
		case orphanChunk(chunkId: String, index: Int)
		case interleaved(active: String, incoming: String)
		case interrupted(chunkId: String, expectedIndex: Int)
		case outOfOrder(chunkId: String, expected: Int, received: Int)
		case metadataMismatch(chunkId: String)
		case sizeMismatch(chunkId: String, expected: Int, received: Int)
		case tooLarge(byteLength: Int, limit: Int)
		case invalidBase64(chunkId: String, index: Int)

		public var description: String {
			switch self {
			case .invalidMetadata(let detail):
				return "rpc_chunk metadata invalid: \(detail)"
			case .orphanChunk(let chunkId, let index):
				return "rpc_chunk \(chunkId) index \(index) arrived with no active sequence"
			case .interleaved(let active, let incoming):
				return "rpc_chunk sequence \(incoming) interleaved with active \(active)"
			case .interrupted(let chunkId, let expectedIndex):
				return "rpc_chunk sequence \(chunkId) interrupted at index \(expectedIndex)"
			case .outOfOrder(let chunkId, let expected, let received):
				return "rpc_chunk \(chunkId) expected index \(expected), got \(received)"
			case .metadataMismatch(let chunkId):
				return "rpc_chunk \(chunkId) changed count/byteLength mid-sequence"
			case .sizeMismatch(let chunkId, let expected, let received):
				return "rpc_chunk \(chunkId) declared \(expected) bytes, assembled \(received)"
			case .tooLarge(let byteLength, let limit):
				return "rpc_chunk payload \(byteLength) exceeds reassembly limit \(limit)"
			case .invalidBase64(let chunkId, let index):
				return "rpc_chunk \(chunkId) index \(index) is not valid base64"
			}
		}
	}

	private struct Pending {
		let chunkId: String
		let count: Int
		let byteLength: Int
		var nextIndex: Int
		var payload: Data
	}

	private var pending: Pending?
	private let maxReassembledBytes: Int

	public init(maxReassembledBytes: Int) {
		self.maxReassembledBytes = maxReassembledBytes
	}

	public var isAssembling: Bool { pending != nil }

	/// Feeds one chunk. Returns the complete payload when the sequence closes,
	/// `nil` while more chunks are expected. Any protocol violation throws and
	/// clears the in-flight sequence.
	public mutating func accept(_ chunk: RpcChunk) throws -> Data? {
		guard chunk.count > 0 else {
			pending = nil
			throw Failure.invalidMetadata("count must be positive")
		}
		guard chunk.index >= 0, chunk.index < chunk.count else {
			pending = nil
			throw Failure.invalidMetadata("index \(chunk.index) out of range for count \(chunk.count)")
		}
		guard chunk.byteLength >= 0 else {
			pending = nil
			throw Failure.invalidMetadata("byteLength must be non-negative")
		}
		guard chunk.byteLength <= maxReassembledBytes else {
			pending = nil
			throw Failure.tooLarge(byteLength: chunk.byteLength, limit: maxReassembledBytes)
		}

		if var active = pending {
			guard active.chunkId == chunk.chunkId else {
				pending = nil
				// A different sequence starting mid-flight means the active one
				// can never complete; both conditions are reported distinctly.
				throw chunk.index == 0
					? Failure.interrupted(chunkId: active.chunkId, expectedIndex: active.nextIndex)
					: Failure.interleaved(active: active.chunkId, incoming: chunk.chunkId)
			}
			guard active.count == chunk.count, active.byteLength == chunk.byteLength else {
				pending = nil
				throw Failure.metadataMismatch(chunkId: chunk.chunkId)
			}
			guard active.nextIndex == chunk.index else {
				pending = nil
				throw Failure.outOfOrder(chunkId: chunk.chunkId, expected: active.nextIndex, received: chunk.index)
			}
			guard let decoded = Data(base64Encoded: chunk.data) else {
				pending = nil
				throw Failure.invalidBase64(chunkId: chunk.chunkId, index: chunk.index)
			}
			active.payload.append(decoded)
			active.nextIndex += 1
			guard active.payload.count <= active.byteLength else {
				pending = nil
				throw Failure.sizeMismatch(
					chunkId: chunk.chunkId,
					expected: active.byteLength,
					received: active.payload.count
				)
			}
			pending = active
		} else {
			guard chunk.index == 0 else {
				throw Failure.orphanChunk(chunkId: chunk.chunkId, index: chunk.index)
			}
			guard let decoded = Data(base64Encoded: chunk.data) else {
				throw Failure.invalidBase64(chunkId: chunk.chunkId, index: chunk.index)
			}
			guard decoded.count <= chunk.byteLength else {
				throw Failure.sizeMismatch(
					chunkId: chunk.chunkId,
					expected: chunk.byteLength,
					received: decoded.count
				)
			}
			pending = Pending(
				chunkId: chunk.chunkId,
				count: chunk.count,
				byteLength: chunk.byteLength,
				nextIndex: 1,
				payload: decoded
			)
		}

		guard let active = pending, active.nextIndex == active.count else { return nil }
		pending = nil
		guard active.payload.count == active.byteLength else {
			throw Failure.sizeMismatch(
				chunkId: active.chunkId,
				expected: active.byteLength,
				received: active.payload.count
			)
		}
		return active.payload
	}

	public mutating func reset() { pending = nil }
}
