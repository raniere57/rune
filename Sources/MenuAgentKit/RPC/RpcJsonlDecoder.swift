import Foundation

/// Incremental newline-delimited framing over a byte stream.
///
/// A `FileHandle` read returns an arbitrary byte slice: it can hold half a
/// line, several lines, or split a multi-byte UTF-8 scalar down the middle.
/// Splitting on the raw `0x0A` byte *before* attempting any text decoding is
/// what makes the UTF-8 case a non-issue — a scalar is only ever decoded once
/// its whole line has arrived.
public struct RpcJsonlDecoder: Sendable {
	private var buffer = Data()

	/// Hard ceiling on a single unterminated line. Protects against a runaway
	/// producer filling memory when no newline ever arrives.
	private let maxLineBytes: Int

	public private(set) var droppedOverlongLines = 0

	public init(maxLineBytes: Int = 128 * 1024 * 1024) {
		self.maxLineBytes = maxLineBytes
	}

	/// Appends `data` and returns every complete line it produced.
	/// Empty lines are dropped — RPC mode only parses non-empty JSONL lines.
	public mutating func feed(_ data: Data) -> [Data] {
		guard !data.isEmpty else { return [] }
		buffer.append(data)

		var lines: [Data] = []
		var searchStart = buffer.startIndex

		while let newlineIndex = buffer[searchStart...].firstIndex(of: 0x0A) {
			let line = buffer[searchStart..<newlineIndex]
			searchStart = buffer.index(after: newlineIndex)
			let trimmed = Self.trimmingTrailingCarriageReturn(line)
			if !trimmed.isEmpty { lines.append(Data(trimmed)) }
		}

		if searchStart == buffer.endIndex {
			buffer.removeAll(keepingCapacity: true)
		} else {
			buffer = Data(buffer[searchStart...])
			if buffer.count > maxLineBytes {
				buffer.removeAll(keepingCapacity: false)
				droppedOverlongLines += 1
			}
		}

		return lines
	}

	/// Returns any trailing bytes that never got a newline. Called once at EOF:
	/// OMP always terminates frames with `\n`, so a non-nil result here means
	/// the process died mid-frame and the partial line must be discarded by the
	/// caller rather than parsed.
	public mutating func flush() -> Data? {
		let trimmed = Self.trimmingTrailingCarriageReturn(buffer[...])
		buffer.removeAll(keepingCapacity: false)
		return trimmed.isEmpty ? nil : Data(trimmed)
	}

	public var pendingByteCount: Int { buffer.count }

	private static func trimmingTrailingCarriageReturn(_ slice: Data.SubSequence) -> Data.SubSequence {
		guard slice.last == 0x0D else { return slice }
		return slice.dropLast()
	}
}
