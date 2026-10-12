import Foundation

// Wire format for the Anthropic Messages API (raw HTTPS; there is no official Swift SDK).
// Everything here is internal: the public surface is `ClaudeService` and the types in ClaudeTypes.swift.

// MARK: - JSON value

/// Minimal JSON tree used to build request bodies (JSON schemas are arbitrary JSON).
enum JSONValue: Sendable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes] // deterministic → cache-friendly
        return try encoder.encode(self)
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(Int64(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Request building

enum MessagesAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let version = "2023-06-01"

    static let ephemeralCache: JSONValue = ["type": "ephemeral"]

    /// Cached system prompt as a single text block.
    static func system(_ text: String) -> JSONValue {
        [["type": "text", "text": .string(text), "cache_control": ephemeralCache]]
    }

    static func textBlock(_ text: String, cached: Bool = false) -> JSONValue {
        var block: [String: JSONValue] = ["type": "text", "text": .string(text)]
        if cached { block["cache_control"] = ephemeralCache }
        return .object(block)
    }

    static func jsonSchemaFormat(_ schema: JSONValue) -> JSONValue {
        ["type": "json_schema", "schema": schema]
    }

    static func urlRequest(body: Data, apiKey: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(version, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = body
        return request
    }
}

// MARK: - Schemas (structured outputs: every object needs additionalProperties: false)

enum ClaudeSchemas {
    static let categoryEnum: JSONValue = .array(CategoryID.allCases.map { .string($0.rawValue) })
    /// The model may only answer safe/review/keep; `protected` is decided locally.
    static let labelEnum: JSONValue = ["safe", "review", "keep"]

    static let aiLabel: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["path", "title", "explanation", "ownerApp", "regenerates", "category", "label"],
        "properties": [
            "path": ["type": "string", "description": "Copied exactly from the input."],
            "title": ["type": "string"],
            "explanation": ["type": "string"],
            "ownerApp": ["anyOf": [["type": "string"], ["type": "null"]]],
            "regenerates": ["type": "boolean"],
            "category": ["type": "string", "enum": categoryEnum],
            "label": ["type": "string", "enum": labelEnum],
        ],
    ]

    static let labels: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["labels"],
        "properties": ["labels": ["type": "array", "items": aiLabel]],
    ]

    static let cleanupPlan: JSONValue = [
        "type": "object",
        "additionalProperties": false,
        "required": ["headline", "steps"],
        "properties": [
            "headline": ["type": "string"],
            "steps": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["title", "reasoning", "paths", "estimatedBytes", "risk"],
                    "properties": [
                        "title": ["type": "string"],
                        "reasoning": ["type": "string"],
                        "paths": ["type": "array", "items": ["type": "string"]],
                        "estimatedBytes": ["type": "integer"],
                        "risk": ["type": "string", "enum": ["safe", "review"]],
                    ],
                ],
            ],
        ],
    ]
}

// MARK: - Prompt payload DTOs (what the model sees about the disk)

/// Human-readable decimal size, matching Finder ("17.2 GB").
func humanSize(_ bytes: Int64) -> String {
    let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
    var value = Double(max(bytes, 0))
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    if unit == 0 { return "\(Int(value)) bytes" }
    return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
}

func isoDate(_ date: Date?) -> String? { date.map { $0.formatted(.iso8601) } }

/// One item as sent to the model: metadata only, never contents.
struct WireItem: Encodable {
    let path: String
    let size: String
    let bytes: Int64
    let kind: String
    let itemCount: Int
    let modified: String?
    let accessed: String?
    let topChildren: [String]

    init(_ item: ItemMetadata, home: String) {
        path = Redactor.redact(item.path, home: home)
        size = humanSize(item.sizeBytes)
        bytes = item.sizeBytes
        kind = item.isDirectory ? "folder" : "file"
        itemCount = item.itemCount
        modified = isoDate(item.modified)
        accessed = isoDate(item.accessed)
        topChildren = item.topChildren.map { Redactor.redactText($0, home: home) }
    }
}

struct WireSummary: Encodable {
    struct Volume: Encodable {
        let name: String
        let total: String
        let used: String
        let available: String
        let totalBytes: Int64
        let availableBytes: Int64
    }
    struct Category: Encodable {
        let category: String
        let size: String
        let bytes: Int64
        let safeSize: String
        let safeBytes: Int64
    }
    struct Finding: Encodable {
        let path: String
        let title: String
        let size: String
        let bytes: Int64
        let label: String
        let category: String
        let lastModified: String?
    }

    let volume: Volume
    let scannedAt: String?
    let categories: [Category]
    let topFindings: [Finding]
    let unknownLarge: [WireItem]

    init(_ s: DiskSummary, home: String) {
        volume = Volume(
            name: s.volume.name, total: humanSize(s.volume.totalBytes), used: humanSize(s.volume.usedBytes),
            available: humanSize(s.volume.availableBytes), totalBytes: s.volume.totalBytes,
            availableBytes: s.volume.availableBytes)
        scannedAt = isoDate(s.scannedAt)
        categories = s.categories.map {
            Category(category: $0.category.rawValue, size: humanSize($0.bytes), bytes: $0.bytes,
                     safeSize: humanSize($0.safeBytes), safeBytes: $0.safeBytes)
        }
        topFindings = s.topFindings.map {
            Finding(path: Redactor.redact($0.path, home: home), title: $0.title, size: humanSize($0.bytes),
                    bytes: $0.bytes, label: $0.label.rawValue, category: $0.category.rawValue,
                    lastModified: isoDate($0.lastModified))
        }
        unknownLarge = s.unknownLarge.map { WireItem($0, home: home) }
    }
}

func compactJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

// MARK: - Responses

struct APIUsage: Decodable, Sendable {
    var input_tokens: Int?
    var output_tokens: Int?
    var cache_creation_input_tokens: Int?
    var cache_read_input_tokens: Int?
}

struct StopDetails: Decodable, Sendable {
    var category: String?
    var explanation: String?
}

struct APIContentBlock: Decodable, Sendable {
    var type: String
    var text: String?
}

struct APIMessage: Decodable, Sendable {
    var content: [APIContentBlock]?
    var stop_reason: String?
    var stop_details: StopDetails?
    var usage: APIUsage?

    /// All text blocks joined, read by block type (thinking blocks may come first).
    var text: String { (content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined() }
}

struct APIErrorEnvelope: Decodable, Sendable {
    struct Body: Decodable, Sendable {
        var type: String?
        var message: String?
    }
    var error: Body?
}

/// One SSE `data:` payload. Only the fields Freespan needs.
struct StreamEvent: Decodable, Sendable {
    struct Delta: Decodable, Sendable {
        var type: String?
        var text: String?
        var stop_reason: String?
        var stop_details: StopDetails?
    }
    var type: String
    var message: APIMessage?
    var delta: Delta?
    var usage: APIUsage?
    var error: APIErrorEnvelope.Body?
}

/// Throws the right `ClaudeError` for a non-success stop reason. Call before reading content.
func checkStopReason(_ reason: String?, details: StopDetails?) throws {
    switch reason {
    case "refusal": throw ClaudeError.refused(details?.explanation ?? details?.category)
    case "max_tokens": throw ClaudeError.truncated
    default: return
    }
}

// MARK: - Server-sent events

struct SSEMessage: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Line-oriented SSE parser (https://html.spec.whatwg.org/multipage/server-sent-events.html).
/// Feed it complete lines without their terminator; a blank line dispatches the pending event.
struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(line: String) -> SSEMessage? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil } // comment / keep-alive
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break // id, retry: unused
        }
        return nil
    }

    /// Dispatches whatever is pending when the stream ends without a trailing blank line.
    mutating func finish() -> SSEMessage? { dispatch() }

    private mutating func dispatch() -> SSEMessage? {
        defer { event = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return SSEMessage(event: event, data: dataLines.joined(separator: "\n"))
    }
}

/// Splits a byte stream into lines (LF or CRLF), keeping empty lines — unlike `AsyncBytes.lines`,
/// which drops them and would hide SSE event boundaries.
struct LineSplitter {
    private var buffer: [UInt8] = []

    mutating func append(_ byte: UInt8) -> String? {
        guard byte == UInt8(ascii: "\n") else {
            buffer.append(byte)
            return nil
        }
        if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
        defer { buffer.removeAll(keepingCapacity: true) }
        return String(decoding: buffer, as: UTF8.self)
    }

    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
        defer { buffer.removeAll() }
        return String(decoding: buffer, as: UTF8.self)
    }
}

/// Accumulates a streamed Messages response: text, stop reason, usage.
struct StreamAccumulator {
    private(set) var stopReason: String?
    private(set) var stopDetails: StopDetails?
    private(set) var usage = APIUsage()
    private(set) var sawMessageStart = false
    private(set) var finished = false

    /// Returns the text delta to surface, if any. Throws on an `error` event.
    mutating func handle(_ message: SSEMessage) throws -> String? {
        guard let data = message.data.data(using: .utf8),
              let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
        else { return nil } // unknown or malformed event: ignore, per API versioning policy
        switch event.type {
        case "message_start":
            sawMessageStart = true
            if let u = event.message?.usage { merge(u) }
        case "content_block_delta":
            if event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty { return text }
        case "message_delta":
            if let reason = event.delta?.stop_reason { stopReason = reason }
            if let details = event.delta?.stop_details { stopDetails = details }
            if let u = event.usage { merge(u) }
        case "message_stop":
            finished = true
        case "error":
            throw ClaudeError.fromStreamError(type: event.error?.type, message: event.error?.message)
        default:
            break // ping, content_block_start/stop, thinking deltas
        }
        return nil
    }

    /// message_delta usage is cumulative, so later values replace earlier ones.
    private mutating func merge(_ u: APIUsage) {
        if let v = u.input_tokens { usage.input_tokens = v }
        if let v = u.output_tokens { usage.output_tokens = v }
        if let v = u.cache_creation_input_tokens { usage.cache_creation_input_tokens = v }
        if let v = u.cache_read_input_tokens { usage.cache_read_input_tokens = v }
    }
}

extension ClaudeError {
    static func fromStreamError(type: String?, message: String?) -> ClaudeError {
        switch type {
        case "overloaded_error": .overloaded
        case "rate_limit_error": .rateLimited(retryAfter: nil)
        case "authentication_error": .invalidAPIKey
        default: .badResponse(message ?? type ?? "stream error")
        }
    }
}
