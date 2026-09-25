import Foundation
import Testing
@testable import AetherEngine

/// The playlist caps in the ingest readers and the carriage probe used to be tested after
/// `session.data(for:)` had buffered the whole body, so they bounded nothing (audit NET-10). These
/// pin that the cap now holds while the body arrives, with and without a declared length.
@Suite("Playlist bodies are capped while they arrive", .serialized)
struct BoundedPlaylistFetchTests {

    private static let limit = 4096

    @Test("A body within the cap arrives whole")
    func withinCap() async throws {
        let (data, response) = try await fetch(.init(chunks: 3, chunkBytes: 1000, declaresLength: false))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(data.count == 3000)
    }

    @Test("A declared length over the cap is refused before the body is read")
    func declaredOverCap() async {
        await #expect(throws: HLSIngestError.playlistInvalid(reason: "playlist exceeds \(Self.limit) bytes")) {
            _ = try await fetch(.init(chunks: 8, chunkBytes: 1000, declaresLength: true))
        }
    }

    @Test("A body with no stated length is cut off at the cap")
    func undeclaredOverCap() async {
        await #expect(throws: HLSIngestError.playlistInvalid(reason: "playlist exceeds \(Self.limit) bytes")) {
            _ = try await fetch(.init(chunks: 64, chunkBytes: 1000, declaresLength: false))
        }
    }

    @Test("A refusal comes back with its status and no body")
    func refusalKeepsItsStatus() async throws {
        let (data, response) = try await fetch(.init(chunks: 64, chunkBytes: 1000, declaresLength: false, status: 404))
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(data.isEmpty)
    }

    private func fetch(_ shape: StreamingPlaylistProtocol.Shape) async throws -> (Data, URLResponse) {
        StreamingPlaylistProtocol.shape = shape
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingPlaylistProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await BoundedPlaylistFetch.data(
            for: URLRequest(url: URL(string: "https://origin.test/live.m3u8")!), session: session,
            limit: Self.limit)
    }
}

/// Answers every request with `shape`: a body delivered in chunks, with or without a length.
private final class StreamingPlaylistProtocol: URLProtocol, @unchecked Sendable {
    struct Shape {
        var chunks: Int
        var chunkBytes: Int
        var declaresLength: Bool
        var status = 200
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _shape = Shape(chunks: 0, chunkBytes: 0, declaresLength: false)
    static var shape: Shape {
        get { lock.withLock { _shape } }
        set { lock.withLock { _shape = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let shape = Self.shape
        var fields = ["Content-Type": "application/vnd.apple.mpegurl"]
        if shape.declaresLength { fields["Content-Length"] = String(shape.chunks * shape.chunkBytes) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: shape.status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for _ in 0 ..< shape.chunks {
            client?.urlProtocol(self, didLoad: Data(repeating: 0x23, count: shape.chunkBytes))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}
