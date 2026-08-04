import Testing
import Foundation
@testable import AetherEngine

/// Proactive replacement of a persistent connection that dies while the reader is still buffered.
///
/// MEASURED DEFECT (Apple TV, 2026-08-03, live Metro trace):
///   17:34:12.156Z  reader parks the transfer for backpressure (`pumpSusp=1`, ~10 MB ahead)
///   17:34:22.458Z  CFNetwork reports that parked generation dead ("network connection was lost")
///   ...            the reader keeps serving the resident window and opens nothing
///   17:34:46.874Z  only after `pumpAheadMB=0` does it open gen 6 — 24.416 s later
///                  that replacement's first byte arrived in 28 ms
/// Generation 6 repeated it (parked 17:36:42.857Z, lost 17:36:44.476Z, replacement 22 ms).
///
/// Root cause: `readPersistent` only consults `connEnded` on the branch where `available <= 0`,
/// i.e. after the window has drained at the read cursor. A connection that dies while the reader
/// is comfortably buffered is therefore KNOWN dead and deliberately ignored until starvation. The
/// origin was instant every time it was finally asked, so the entire freeze was manufactured
/// client-side — which is exactly what Patrick reported and what the telemetry confirms.
@Suite("AVIOReader proactive connection replacement")
struct ProactiveConnectionReplacementTests {

    // MARK: - Pure decision rules

    /// These guards are the whole safety story: every `skip` hands recovery back to the drain
    /// path, which owns backoff, Retry-After and the give-up budget. A regression that turns any
    /// of them into `.replace` is a reconnect storm against a source that is already unhappy.
    struct DecisionRules {

        private let policy = AetherSourceBufferPolicy.stock

        @Test("a healthy mid-file connection loss is replaced immediately")
        func healthyLossReplaces() {
            let inputs = AetherProactiveReplaceInputs(
                connStatus: 206, fileSize: 1_000_000_000, frontier: 500_000_000)
            #expect(policy.decideProactiveReplace(inputs) == .replace)
        }

        @Test("the kill switch defers to the drain path")
        func killSwitch() {
            var off = AetherSourceBufferPolicy.stock
            off.replaceOnConnectionLoss = false
            #expect(off.decideProactiveReplace(AetherProactiveReplaceInputs()) == .skip("disabled"))
            // The pre-change policy must behave exactly like the old binary here.
            #expect(AetherSourceBufferPolicy.preChange
                .decideProactiveReplace(AetherProactiveReplaceInputs()) == .skip("disabled"))
        }

        @Test("our own #220 hard-cap end is never re-requested immediately")
        func backpressureCapDefers() {
            // Re-requesting here would refill straight back over the cap. That path is correct
            // only once the consumer has drained, which is what the drain path already does.
            let inputs = AetherProactiveReplaceInputs(endedByBackpressure: true)
            #expect(policy.decideProactiveReplace(inputs) == .skip("backpressure-cap"))
        }

        @Test("a rate-limited origin is backed off, not hammered")
        func rateLimitedDefers() {
            #expect(policy.decideProactiveReplace(AetherProactiveReplaceInputs(connStatus: 429))
                    == .skip("rate-limited-429"))
            #expect(policy.decideProactiveReplace(AetherProactiveReplaceInputs(connStatus: 503))
                    == .skip("rate-limited-503"))
        }

        @Test("a completed file is not re-requested")
        func eofDefers() {
            let atEnd = AetherProactiveReplaceInputs(fileSize: 1_000, frontier: 1_000)
            #expect(policy.decideProactiveReplace(atEnd) == .skip("eof"))
            let past = AetherProactiveReplaceInputs(fileSize: 1_000, frontier: 4_000)
            #expect(policy.decideProactiveReplace(past) == .skip("eof"))
            // A live source has no meaningful EOF; frontier past a stale size must still replace.
            let live = AetherProactiveReplaceInputs(isLive: true, fileSize: 1_000, frontier: 4_000)
            #expect(live.isLive)
            #expect(policy.decideProactiveReplace(live) == .replace)
        }

        @Test("an unknown file size cannot be mistaken for EOF")
        func unknownSizeReplaces() {
            let inputs = AetherProactiveReplaceInputs(fileSize: 0, frontier: 9_000_000)
            #expect(policy.decideProactiveReplace(inputs) == .replace)
        }

        @Test("a failing source stops being retried and returns to the drain path")
        func deadStreakSuppresses() {
            // Limit is 2: streaks 0 and 1 still retry, 2 hands over.
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(deadStreak: 0)) == .replace)
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(deadStreak: 1)) == .replace)
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(deadStreak: 2)) == .skip("dead-streak-2"))
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(deadStreak: 9)) == .skip("dead-streak-9"))
        }

        @Test("a flapping source cannot become a reconnect storm")
        func minIntervalBounds() {
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(msSinceLastReplace: 10)) == .skip("min-interval-10ms"))
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(msSinceLastReplace: 249)) == .skip("min-interval-249ms"))
            #expect(policy.decideProactiveReplace(
                AetherProactiveReplaceInputs(msSinceLastReplace: 250)) == .replace)
        }

        @Test("two deaths cannot start two replacements for the same connection")
        func inFlightGuard() {
            let inputs = AetherProactiveReplaceInputs(alreadyInFlight: true)
            #expect(policy.decideProactiveReplace(inputs) == .skip("already-in-flight"))
        }

        @Test("a closing reader never opens a new connection")
        func closingDefers() {
            #expect(policy.decideProactiveReplace(AetherProactiveReplaceInputs(isClosed: true))
                    == .skip("closing"))
        }
    }

    // MARK: - Loopback origin that drops the connection

    /// Serves `Range: bytes=X-` with a 206 and a deterministic body (`byte at offset N == N & 0xFF`,
    /// so the client can prove continuity across a replacement), then hangs up after
    /// `dropAfterBytes` on the FIRST connection only. Records every request's Range start, which
    /// is how "the replacement resumed at the frontier" becomes a server-side observable rather
    /// than an assertion about the client's private state.
    private final class DroppingOriginServer: @unchecked Sendable {
        let port: UInt16
        private let listenFD: Int32
        private let totalSize: Int64
        private let dropAfterBytes: Int64
        private let lock = NSLock()
        private var _rangeStarts: [Int64] = []
        private var _bytesOnFirstConn: Int64 = 0
        private var _connCount = 0
        private var _stopped = false

        /// Range start of every request served, in order.
        var rangeStarts: [Int64] { lock.lock(); defer { lock.unlock() }; return _rangeStarts }
        var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return _connCount }
        var bytesOnFirstConnection: Int64 {
            lock.lock(); defer { lock.unlock() }; return _bytesOnFirstConn
        }
        private var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

        init?(totalSize: Int64, dropAfterBytes: Int64) {
            self.totalSize = totalSize
            self.dropAfterBytes = dropAfterBytes

            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(fd, 8) == 0 else { close(fd); return nil }
            var bound = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameResult = withUnsafeMutablePointer(to: &bound) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
            }
            guard nameResult == 0 else { close(fd); return nil }
            self.listenFD = fd
            self.port = UInt16(bigEndian: bound.sin_port)
            Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        }

        func stop() {
            lock.lock()
            guard !_stopped else { lock.unlock(); return }
            _stopped = true
            lock.unlock()
            close(listenFD)
        }

        private func acceptLoop() {
            while !stopped {
                let clientFD = accept(listenFD, nil, nil)
                guard clientFD >= 0 else { if stopped { return }; continue }
                Thread.detachNewThread { [weak self] in self?.serve(clientFD) }
            }
        }

        private func serve(_ fd: Int32) {
            defer { close(fd) }
            // Never let a parked client block this thread forever.
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            guard let header = readRequestHeader(fd) else { return }
            let start = Self.rangeStart(from: header)

            lock.lock()
            _connCount += 1
            let myIndex = _connCount
            _rangeStarts.append(start)
            lock.unlock()

            let end = totalSize - 1
            let head = "HTTP/1.1 206 Partial Content\r\n"
                + "Content-Range: bytes \(start)-\(end)/\(totalSize)\r\n"
                + "Content-Length: \(end - start + 1)\r\n"
                + "Accept-Ranges: bytes\r\n"
                + "Connection: close\r\n\r\n"
            guard writeAll(fd, Array(head.utf8)) else { return }

            let chunk = 64 * 1024
            var offset = start
            var writtenHere: Int64 = 0
            while !stopped, offset <= end {
                let n = Int(min(Int64(chunk), end - offset + 1))
                // Deterministic pattern so the client can prove the stream stayed contiguous.
                var body = [UInt8](repeating: 0, count: n)
                for i in 0..<n { body[i] = UInt8(truncatingIfNeeded: offset &+ Int64(i)) }
                let sent = writeCounting(fd, body)
                guard sent > 0 else { return }
                offset += Int64(sent)
                writtenHere += Int64(sent)
                if myIndex == 1 {
                    lock.lock(); _bytesOnFirstConn = writtenHere; lock.unlock()
                    // THE DROP. This models the field event: the connection dies mid-stream while
                    // the client still holds a healthy buffer.
                    if writtenHere >= dropAfterBytes { return }
                }
            }
        }

        private static func rangeStart(from header: String) -> Int64 {
            guard let r = header.range(of: "Range: bytes=", options: .caseInsensitive) else { return 0 }
            let tail = header[r.upperBound...]
            let digits = tail.prefix { $0.isNumber }
            return Int64(digits) ?? 0
        }

        private func readRequestHeader(_ fd: Int32) -> String? {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            var collected = Data()
            let terminator = Data("\r\n\r\n".utf8)
            while collected.range(of: terminator) == nil {
                let n = recv(fd, &buf, buf.count, 0)
                guard n > 0 else { return nil }
                collected.append(contentsOf: buf[0..<n])
                if collected.count > 64 * 1024 { return nil }
            }
            return String(data: collected, encoding: .utf8)
        }

        private func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
            var sent = 0
            while sent < bytes.count {
                let n = bytes[sent...].withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
                guard n > 0 else { return false }
                sent += n
            }
            return true
        }

        /// Returns bytes accepted; 0 on error/timeout so a parked client ends the connection
        /// rather than wedging the test.
        private func writeCounting(_ fd: Int32, _ bytes: [UInt8]) -> Int {
            bytes.withUnsafeBytes { raw in max(0, write(fd, raw.baseAddress, raw.count)) }
        }
    }

    // MARK: - Integration

    /// THE REGRESSION TEST. Nothing is consumed after the drop, so the read loop never runs — which
    /// is precisely why the old code could not recover: its only reconnect trigger is a read that
    /// finds the window empty. If a replacement connection arrives here at all, it came from the
    /// delegate-driven path.
    @Test("a connection lost while buffered is replaced without waiting for the buffer to drain")
    func replacesWithoutDraining() async throws {
        let server = try #require(DroppingOriginServer(totalSize: 512 * 1024 * 1024,
                                                       dropAfterBytes: 2 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        // Pinned per reader, not globally: parallel tests must not observe each other's policy.
        // `.stock` keeps the OLD byte watermarks, which is the point — the fix must work in the
        // shipped default configuration, not only when the new sizing is switched on.
        reader.policyOverrideForTesting = .stock
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // The drop happens ~2 MB in, below the 8 MB low water, so the reader is not suspended and
        // holds a healthy buffer. Give the replacement a generous window; the field measurement
        // was 28 ms, and the old behaviour would never reconnect at all without a read.
        let deadline = Date().addingTimeInterval(10)
        while server.connectionCount < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(server.connectionCount >= 2,
                "no replacement connection: the reader sat on a dead source (connCount=\(server.connectionCount))")
    }

    /// The replacement must CONTINUE, not restart: same file position, nothing refetched, nothing
    /// discarded. A replacement that re-requested from 0 would rewind playback; one that requested
    /// past the frontier would punch a hole in the stream.
    @Test("the replacement resumes exactly at the window frontier")
    func replacementResumesAtFrontier() async throws {
        let server = try #require(DroppingOriginServer(totalSize: 512 * 1024 * 1024,
                                                       dropAfterBytes: 3 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        reader.policyOverrideForTesting = .stock
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let deadline = Date().addingTimeInterval(10)
        while server.connectionCount < 2 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let starts = server.rangeStarts
        try #require(starts.count >= 2, "no replacement connection was made")

        #expect(starts[0] == 0, "the first request must open the file at 0, got \(starts[0])")
        // The frontier is what the CLIENT received on connection 1. That is at most what the
        // server wrote into the socket, and normally all of it (a graceful close flushes), but a
        // final chunk can still be in flight when the FIN lands — hence the one-chunk tolerance
        // rather than strict equality, which would be a flaky assertion about kernel timing.
        //
        // What this proves is the shape: the replacement continues near the end of what was
        // already received, so nothing was discarded (it did not restart at 0) and nothing was
        // skipped (it did not jump past what connection 1 delivered). Byte-exact continuity is
        // asserted separately by `streamStaysContiguousAcrossReplacement`.
        let written = server.bytesOnFirstConnection
        #expect(starts[1] > 0, "the replacement restarted the file instead of continuing")
        #expect(starts[1] <= written,
                "replacement asked for \(starts[1]), past the \(written) bytes ever sent")
        #expect(starts[1] >= written - 256 * 1024,
                // One interpolated literal, NOT a `+` concatenation: swift-testing takes a
                // `Comment?`, which is ExpressibleByStringInterpolation but not constructible from
                // a runtime String, so concatenating here fails to compile and takes the whole
                // test target down with it.
                """
                replacement asked for \(starts[1]) but \(written) bytes had been sent — \
                more than one chunk of the window was discarded
                """)
    }

    /// End-to-end continuity: read straight through the drop and verify every byte, so a
    /// replacement that silently duplicated or skipped a region cannot pass.
    @Test("bytes stay contiguous and correct across the replacement")
    func streamStaysContiguousAcrossReplacement() async throws {
        let total: Int64 = 64 * 1024 * 1024
        let server = try #require(DroppingOriginServer(totalSize: total,
                                                       dropAfterBytes: 2 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        reader.policyOverrideForTesting = .stock
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 256 * 1024
        let target = 12 * 1024 * 1024      // well past the 2 MB drop point
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }

        var consumed: Int64 = 0
        var mismatches = 0
        let deadline = Date().addingTimeInterval(60)
        while consumed < Int64(target), Date() < deadline {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            for i in 0..<Int(n) where buf[i] != UInt8(truncatingIfNeeded: consumed &+ Int64(i)) {
                mismatches += 1
            }
            consumed += Int64(n)
        }

        #expect(consumed >= Int64(target),
                "only \(consumed / (1024 * 1024)) MB read across the drop")
        #expect(mismatches == 0, "\(mismatches) byte(s) were wrong across the replacement")
        #expect(server.connectionCount >= 2, "the drop was never replaced")
    }

    /// The kill switch must restore the old behaviour exactly, so a device that somehow regresses
    /// on the new path can be returned to the known binary without a rebuild.
    @Test("with replacement disabled no connection is opened while buffered")
    func killSwitchRestoresOldBehaviour() async throws {
        let server = try #require(DroppingOriginServer(totalSize: 512 * 1024 * 1024,
                                                       dropAfterBytes: 2 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        reader.policyOverrideForTesting = .preChange
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Nothing consumes, so the drain path cannot fire either. The old binary opens nothing.
        try await Task.sleep(for: .seconds(3))
        #expect(server.connectionCount == 1,
                "the disabled path still opened \(server.connectionCount) connections")
    }
}
