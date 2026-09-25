import Foundation

/// A bounded, non-blocking handoff from the demux thread to the recording writer.
///
/// The ceiling is a BYTE budget rather than a packet count on purpose: live packet sizes span two
/// orders of magnitude (a 20 byte audio frame against a 400 KB keyframe), so a count either admits
/// far too much video or refuses ordinary audio.
///
/// `offer` never waits. When the ceiling is reached it refuses, accounts the bytes it dropped, and
/// returns false. A recording that cannot keep up is a reported failure; a parked demux thread is a
/// stalled picture, which is the outcome this type exists to make impossible.
final class LiveRecordingQueue: @unchecked Sendable {

    struct QueuedPacket {
        var bytes: Data
        var sourceStreamIndex: Int32
        var pts: Int64
        var dts: Int64
        var duration: Int64
        var isKeyframe: Bool
    }

    private let lock = NSLock()
    private var pending: [QueuedPacket] = []
    private var pendingBytes: Int = 0
    private var _droppedBytes: Int64 = 0
    private var draining = false
    private var finished = false

    private let ceilingBytes: Int
    private let drain: (QueuedPacket) -> Void
    private let queue = DispatchQueue(label: "de.superuser404.aether.recording.write", qos: .utility)

    var droppedBytes: Int64 { lock.lock(); defer { lock.unlock() }; return _droppedBytes }

    init(ceilingBytes: Int, drain: @escaping (QueuedPacket) -> Void) {
        self.ceilingBytes = ceilingBytes
        self.drain = drain
    }

    /// Returns false when the packet was refused because the queue is full or finished.
    @discardableResult
    func offer(_ item: QueuedPacket) -> Bool {
        lock.lock()
        if finished {
            lock.unlock()
            return false
        }
        if pendingBytes + item.bytes.count > ceilingBytes {
            _droppedBytes += Int64(item.bytes.count)
            lock.unlock()
            return false
        }
        pending.append(item)
        pendingBytes += item.bytes.count
        let needsPump = !draining
        if needsPump { draining = true }
        lock.unlock()

        if needsPump { queue.async { [weak self] in self?.pump() } }
        return true
    }

    /// Drains what is queued and stops accepting. Blocks the CALLER, never the demux thread: only
    /// the writer's teardown calls it, and never from the main actor.
    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
        // The queue is serial, so an in-flight pump finishes first and this one drains what it left.
        queue.sync { pump() }
    }

    /// Audit REC-1: takes the backlog a batch at a time. `removeFirst()` per item shifted the whole
    /// array each time, quadratic on the tens of thousands of small packets the ceiling admits. The
    /// bytes still leave `pendingBytes` one write at a time, so the ceiling keeps counting a batch
    /// that is taken but not yet on disk.
    private func pump() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                draining = false
                lock.unlock()
                return
            }
            var batch: [QueuedPacket] = []
            swap(&batch, &pending)
            lock.unlock()
            for item in batch {
                drain(item)
                lock.lock()
                pendingBytes -= item.bytes.count
                lock.unlock()
            }
        }
    }
}
