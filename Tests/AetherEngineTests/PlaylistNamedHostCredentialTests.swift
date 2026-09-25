import Foundation
import Testing
@testable import AetherEngine

/// A playlist can name any host and any scheme for a variant, a rendition, a segment or a key. The
/// host's credential headers were set on every one of those fetches, including an http:// URI inside
/// an https:// playlist. They now follow the redirect rule (audit NET-7): the token only to the origin
/// the host gave it for, with no downgrade, and every other header wherever the playlist points.
@Suite("Credential headers stay with the host's origin", .serialized)
struct PlaylistNamedHostCredentialTests {

    private let headers = [
        "Authorization": "MediaBrowser Token=\"t0k3n\"",
        "X-Emby-Token": "t0k3n",
        "Cookie": "connect.sid=s1",
        "Referer": "https://portal.example/",
        "User-Agent": "UA/1",
    ]
    private let credentialNames = ["Authorization", "X-Emby-Token", "Cookie"]
    private let origin = URL(string: "https://media.example/live/master.m3u8")!

    @Test("The live ingest keeps the token on its own origin and drops it elsewhere", arguments: [
        ("https://media.example/live/seg1.ts", true),
        ("https://media.example:443/keys/k1", true),
        ("https://cdn.other/seg1.ts", false),
        ("http://media.example/live/seg1.ts", false),
        ("https://media.example:8443/seg1.ts", false),
    ])
    func liveIngest(target: String, keepsCredentials: Bool) throws {
        let reader = HLSLiveIngestReader(playlistURL: origin, httpHeaders: headers)
        let request = reader.makeRequest(try #require(URL(string: target)))
        expect(request, keepsCredentials: keepsCredentials)
    }

    @Test("A companion reader judges by its parent's origin, not by the rendition URL it was handed")
    func companionInheritsTheHostOrigin() throws {
        let rendition = try #require(URL(string: "https://cdn.other/audio/index.m3u8"))
        let companion = HLSLiveIngestReader(
            playlistURL: rendition, httpHeaders: headers, role: .companionAudio, credentialOrigin: origin)
        expect(companion.makeRequest(try #require(URL(string: "https://cdn.other/audio/a1.aac"))),
               keepsCredentials: false)
        expect(companion.makeRequest(try #require(URL(string: "https://media.example/audio/a1.aac"))),
               keepsCredentials: true)
    }

    @Test("The VOD ingest applies the same rule")
    func vodIngest() throws {
        let reader = HLSVODIngestReader(playlistURL: origin, httpHeaders: headers)
        defer { reader.close() }
        expect(reader.makeRequest(try #require(URL(string: "https://media.example/v/seg0.ts"))),
               keepsCredentials: true)
        expect(reader.makeRequest(try #require(URL(string: "http://media.example/v/seg0.ts"))),
               keepsCredentials: false)
    }

    @Test("The relay sends credentials to the host's origins only, not to one a playlist revealed")
    func relayHeaders() throws {
        let anchors = [origin]
        let own = HLSOriginRelay.headers(
            headers, for: try #require(URL(string: "https://media.example/hls/seg.ts")), grantedFor: anchors)
        #expect(own == headers)
        let discovered = HLSOriginRelay.headers(
            headers, for: try #require(URL(string: "http://cdn.other/seg.ts")), grantedFor: anchors)
        for name in credentialNames { #expect(discovered[name] == nil, "\(name) reached a discovered origin") }
        #expect(discovered["Referer"] == "https://portal.example/")
        #expect(discovered["User-Agent"] == "UA/1")
    }

    @Test("The carriage probe does not carry the token to a variant on another host")
    func carriageProbeVariant() async throws {
        CredentialCaptureProtocol.reset()
        let variant = "http://cdn.other/v/index.m3u8"
        CredentialCaptureProtocol.bodies[origin.absoluteString] = Data("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=1000000
            \(variant)
            """.utf8)
        CredentialCaptureProtocol.bodies[variant] = Data("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:6.0,
            seg0.m4s
            """.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialCaptureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let evidence = await HLSCarriageProbe.classifyFromPlaylists(
            playlistURL: origin, httpHeaders: headers, advertisesFragmentedMP4OnlyVideo: false,
            session: session)
        #expect(evidence == .settled(.otherCarriage))

        let master = try #require(CredentialCaptureProtocol.seen[origin.absoluteString])
        let onVariant = try #require(CredentialCaptureProtocol.seen[variant])
        #expect(master["X-Emby-Token"] == "t0k3n")
        for name in credentialNames { #expect(onVariant[name] == nil, "\(name) reached \(variant)") }
        #expect(onVariant["Referer"] == "https://portal.example/")
    }

    private func expect(_ request: URLRequest, keepsCredentials: Bool,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        for name in credentialNames {
            let value = request.value(forHTTPHeaderField: name)
            #expect((value != nil) == keepsCredentials, "\(name) on \(request.url!)",
                    sourceLocation: sourceLocation)
        }
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://portal.example/",
                sourceLocation: sourceLocation)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "UA/1", sourceLocation: sourceLocation)
    }
}

/// Answers from canned bodies and records the headers each URL was asked with. Its own class rather
/// than the #119 suite's, whose statics a parallel suite would reset under this one.
private final class CredentialCaptureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _bodies: [String: Data] = [:]
    nonisolated(unsafe) private static var _seen: [String: [String: String]] = [:]

    static var bodies: [String: Data] {
        get { lock.withLock { _bodies } }
        set { lock.withLock { _bodies = newValue } }
    }

    static var seen: [String: [String: String]] { lock.withLock { _seen } }

    static func reset() {
        lock.withLock { _bodies = [:]; _seen = [:] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let fields = request.allHTTPHeaderFields ?? [:]
        Self.lock.withLock { Self._seen[url.absoluteString] = fields }
        guard let data = Self.bodies[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
