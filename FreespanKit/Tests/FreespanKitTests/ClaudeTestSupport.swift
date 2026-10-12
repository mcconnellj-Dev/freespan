import Foundation
import Synchronization
@testable import FreespanKit

/// URLProtocol mock. Every test that uses it lives in the `.serialized` "Claude network" suite, because
/// the handler is process-global. Nothing here ever reaches the network.
final class ClaudeMockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case http(status: Int, headers: [String: String], chunks: [Data])
        case failure(URLError)
    }

    struct Captured: Sendable {
        let request: URLRequest
        let body: Data
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:] }
        var bodyString: String { String(decoding: body, as: UTF8.self) }
    }

    private struct State {
        var handler: (@Sendable (Captured, Int) -> Reply)?
        var captured: [Captured] = []
    }
    private static let state = Mutex(State())

    static func install(_ handler: @escaping @Sendable (Captured, Int) -> Reply) {
        state.withLock { $0 = State(handler: handler) }
    }

    static var requests: [Captured] { state.withLock { $0.captured } }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ClaudeMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        let captured = Captured(request: request, body: body)
        let (handler, index) = Self.state.withLock { s -> ((@Sendable (Captured, Int) -> Reply)?, Int) in
            s.captured.append(captured)
            return (s.handler, s.captured.count - 1)
        }
        let reply = handler?(captured, index) ?? .failure(URLError(.notConnectedToInternet))
        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .http(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

enum ClaudeFixtures {
    static let home = "/Users/tester"

    static func client(key: String? = "sk-ant-test", usage: UsageMeter = UsageMeter(suiteName: "claude-tests-\(UUID())")) -> AnthropicClient {
        AnthropicClient(apiKeyProvider: { key }, session: ClaudeMockURLProtocol.session(), usage: usage,
                        home: home, retryBaseDelay: .milliseconds(1))
    }

    static func item(_ path: String, size: Int64 = 2_000_000_000, children: [String] = ["Cache_Data", "GPUCache"]) -> ItemMetadata {
        ItemMetadata(path: path, sizeBytes: size, isDirectory: true, itemCount: 1200,
                     modified: Date(timeIntervalSince1970: 1_700_000_000), accessed: Date(timeIntervalSince1970: 1_710_000_000),
                     topChildren: children)
    }

    static func summary() -> DiskSummary {
        DiskSummary(
            volume: VolumeInfo(name: "Macintosh HD", totalBytes: 460_000_000_000, availableBytes: 12_000_000_000),
            scannedAt: Date(timeIntervalSince1970: 1_760_000_000),
            categories: [.init(category: .developer, bytes: 30_000_000_000, safeBytes: 18_000_000_000)],
            topFindings: [
                .init(path: "~/Library/Developer/Xcode/iOS DeviceSupport", title: "iOS device symbols", bytes: 17_200_000_000,
                      label: .safe, category: .developer, lastModified: nil),
                .init(path: "~/Library/Developer/CoreSimulator/Devices", title: "Simulators", bytes: 11_000_000_000,
                      label: .review, category: .developer, lastModified: nil),
                .init(path: "~/Pictures/Photos Library.photoslibrary", title: "Photos library", bytes: 13_000_000_000,
                      label: .keep, category: .media, lastModified: nil),
            ],
            unknownLarge: [item("~/Library/Application Support/Mystery", size: 3_000_000_000)])
    }

    // MARK: Response bodies

    static func message(text: String, stopReason: String = "end_turn", stopDetails: String? = nil,
                        input: Int = 100, output: Int = 50, cacheRead: Int = 0, cacheWrite: Int = 0) -> Data {
        var json: [String: Any] = [
            "id": "msg_test", "type": "message", "role": "assistant", "model": "x",
            "content": [["type": "thinking", "thinking": "", "signature": "sig"], ["type": "text", "text": text]],
            "stop_reason": stopReason,
            "usage": ["input_tokens": input, "output_tokens": output,
                      "cache_read_input_tokens": cacheRead, "cache_creation_input_tokens": cacheWrite],
        ]
        if let stopDetails { json["stop_details"] = ["type": "refusal", "category": stopDetails, "explanation": NSNull()] }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    static func ok(_ body: Data) -> ClaudeMockURLProtocol.Reply {
        .http(status: 200, headers: ["content-type": "application/json"], chunks: [body])
    }

    static func error(_ status: Int, type: String, headers: [String: String] = [:]) -> ClaudeMockURLProtocol.Reply {
        let body = #"{"type":"error","error":{"type":"\#(type)","message":"test \#(type)"},"request_id":"req_1"}"#
        return .http(status: status, headers: headers.merging(["content-type": "application/json"]) { a, _ in a }, chunks: [Data(body.utf8)])
    }

    static func json(_ object: Any) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    /// An SSE stream for the given text deltas.
    static func sse(_ deltas: [String], stopReason: String = "end_turn", extraEvents: [String] = []) -> String {
        var s = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-sonnet-5","stop_reason":null,"usage":{"input_tokens":1200,"output_tokens":1,"cache_read_input_tokens":4000,"cache_creation_input_tokens":300}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: ping
        data: {"type": "ping"}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}


        """
        for d in deltas {
            let payload = json(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": d]])
            s += "event: content_block_delta\ndata: \(payload)\n\n"
        }
        for e in extraEvents { s += e + "\n\n" }
        s += """
        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"\(stopReason)","stop_sequence":null},"usage":{"output_tokens":321}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        return s
    }

    /// Splits a string into chunks of `size` bytes so SSE lines straddle chunk boundaries.
    static func chunked(_ s: String, size: Int) -> [Data] {
        let bytes = Array(s.utf8)
        return stride(from: 0, to: bytes.count, by: size).map { Data(bytes[$0 ..< min($0 + size, bytes.count)]) }
    }

    static func sseReply(_ s: String, chunkSize: Int = 37) -> ClaudeMockURLProtocol.Reply {
        .http(status: 200, headers: ["content-type": "text/event-stream"], chunks: chunked(s, size: chunkSize))
    }
}
