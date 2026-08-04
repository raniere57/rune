import Foundation

/// Loss-tolerant JSON tree.
///
/// The RPC surface is a large discriminated union whose payloads keep growing
/// (`compat` alone carries ~40 booleans). Modelling every branch as a Swift
/// struct would break on the next OMP release, so frames are parsed once into
/// this tree and read by key. Typed wrappers live in `RpcFrame`; this is the
/// substrate they read from and the escape hatch for anything unmodelled.
public enum JSONValue: Sendable, Equatable {
	case null
	case bool(Bool)
	case number(Double)
	case string(String)
	case array([JSONValue])
	case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
	public subscript(key: String) -> JSONValue? {
		guard case .object(let dict) = self else { return nil }
		return dict[key]
	}

	public subscript(index: Int) -> JSONValue? {
		guard case .array(let items) = self, items.indices.contains(index) else { return nil }
		return items[index]
	}

	public var stringValue: String? {
		guard case .string(let value) = self else { return nil }
		return value
	}

	public var boolValue: Bool? {
		guard case .bool(let value) = self else { return nil }
		return value
	}

	public var doubleValue: Double? {
		guard case .number(let value) = self else { return nil }
		return value
	}

	public var intValue: Int? {
		guard case .number(let value) = self, value.isFinite else { return nil }
		return Int(value)
	}

	public var arrayValue: [JSONValue]? {
		guard case .array(let items) = self else { return nil }
		return items
	}

	public var objectValue: [String: JSONValue]? {
		guard case .object(let dict) = self else { return nil }
		return dict
	}

	public var isNull: Bool {
		if case .null = self { return true }
		return false
	}

	/// Best-effort human-readable rendering, used for tool arguments and
	/// results that have no dedicated view.
	public var displayText: String {
		switch self {
		case .null: return ""
		case .bool(let value): return value ? "true" : "false"
		case .number(let value):
			if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
			return String(value)
		case .string(let value): return value
		case .array, .object:
			guard let data = try? JSONEncoder.prettySorted.encode(self),
			      let text = String(data: data, encoding: .utf8)
			else { return "" }
			return text
		}
	}
}

// MARK: - Codable

extension JSONValue: Codable {
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
		} else if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else if let value = try? container.decode(String.self) {
			self = .string(value)
		} else if let value = try? container.decode([JSONValue].self) {
			self = .array(value)
		} else if let value = try? container.decode([String: JSONValue].self) {
			self = .object(value)
		} else {
			throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .null: try container.encodeNil()
		case .bool(let value): try container.encode(value)
		case .number(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		case .array(let value): try container.encode(value)
		case .object(let value): try container.encode(value)
		}
	}
}

extension JSONValue: ExpressibleByStringLiteral {
	public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
	public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
	public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONEncoder {
	static let prettySorted: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		return encoder
	}()

	/// Compact, no escaped slashes — one JSON object per stdin line.
	static let jsonl: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.withoutEscapingSlashes]
		return encoder
	}()
}
