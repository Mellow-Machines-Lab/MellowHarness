import Foundation
import Testing

/// A new, empty folder under the system's temporary one, named
/// `<prefix>-<UUID>`. The test removes it.
func tempDir(_ prefix: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(prefix)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Lines gathered from any thread.
final class Lines: @unchecked Sendable {
    let lock = NSLock()
    var all: [String] { lock.withLock { stored } }
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
}

/// Waits up to `timeout` for `condition`, checking every 20 ms, then
/// expects it: how every test waits on another thread. It blocks, so the
/// suites that use it are serialized.
func eventually(_ what: String, timeout: TimeInterval = 3, sourceLocation: SourceLocation = #_sourceLocation,
                _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    #expect(condition(), Comment(rawValue: what), sourceLocation: sourceLocation)
}
