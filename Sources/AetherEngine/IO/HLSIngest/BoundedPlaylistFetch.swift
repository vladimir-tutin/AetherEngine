import Foundation

/// Reads a playlist body with its size cap enforced while it arrives (audit NET-10).
///
/// `session.data(for:)` buffers the whole body before a caller can look at its size, so a cap tested
/// afterwards bounded nothing: an origin answering with an endless body kept the fetch growing until
/// the resource timeout, or until jetsam. Here a declared length over the cap is refused before a
/// byte is read, and an undeclared one is cut off at the cap.
enum BoundedPlaylistFetch {

    /// The body and response of `request`. A non-2xx answer comes back with an empty body: every
    /// caller throws on the status alone, so its body is not worth reading.
    static func data(for request: URLRequest, session: URLSession, limit: Int) async throws
        -> (Data, URLResponse)
    {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else { return (Data(), response) }
        let declared = response.expectedContentLength
        guard declared <= Int64(limit) else { throw exceeded(limit) }
        var data = Data()
        if declared > 0 { data.reserveCapacity(Int(declared)) }
        for try await byte in bytes {
            guard data.count < limit else { throw exceeded(limit) }
            data.append(byte)
        }
        return (data, response)
    }

    private static func exceeded(_ limit: Int) -> HLSIngestError {
        .playlistInvalid(reason: "playlist exceeds \(limit) bytes")
    }
}
