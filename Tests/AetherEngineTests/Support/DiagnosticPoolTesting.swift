@testable import AetherEngine

extension ItemDiagnosticReadPool {
    /// A pool whose lanes do not give up on a read.
    ///
    /// The AE#597 read timeout is a deadline on a step these tests hold on purpose: a probe that
    /// blocks until the test releases it. On an oversubscribed runner the release can come later
    /// than 15 s, the lane then abandons the read, and the test reports the timeout instead of the
    /// behaviour it is about (a retirement finishing incomplete, a delivery that never comes, a
    /// third lane opening). Tests of the timeout itself pass their own small value.
    static func withoutReadTimeout() -> ItemDiagnosticReadPool {
        ItemDiagnosticReadPool(readTimeout: 86_400)
    }
}
