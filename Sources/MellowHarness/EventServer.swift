#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// A way in for other processes: a Unix socket that
/// takes one JSON event per line, `{"source":…,"kind":…,"data":{…}}`
/// (`line` and `at` optional), and hands each on as its line ends. It never
/// writes back. Each connection is read on its own thread, and closed once
/// it's quiet for half a second. `mellowharness-emit` sends to it from a shell.
public final class EventServer: @unchecked Sendable {
    public let path: String
    private let state: State

    /// What the listening thread needs, apart from the server, so letting
    /// go of the server stops it.
    private final class State: @unchecked Sendable {
        let onEvent: @Sendable (Event) -> Void
        let lock = NSLock()
        var listener: Int32 = -1

        init(onEvent: @escaping @Sendable (Event) -> Void) { self.onEvent = onEvent }
    }

    /// `onEvent` gets each event on one of the server's threads; hop to the
    /// harness's queue to emit it.
    public init(path: String, onEvent: @escaping @Sendable (Event) -> Void) {
        self.path = path
        state = State(onEvent: onEvent)
    }

    public enum Failure: Error { case pathTooLong, socket(Int32), bind(Int32), listen(Int32), send }

    public func start() throws {
        guard var address = EventServer.address(path) else { throw Failure.pathTooLong }
        unlink(path)
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw Failure.socket(errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let error = errno
            close(fd)
            throw Failure.bind(error)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
            let error = errno
            close(fd)
            throw Failure.listen(error)
        }
        let state = state
        state.lock.withLock { state.listener = fd }
        let thread = Thread { EventServer.acceptLoop(fd, state) }
        thread.name = "mellowharness.event-server"
        thread.start()
    }

    public func stop() {
        let state = state
        let fd = state.lock.withLock { () -> Int32 in
            defer { state.listener = -1 }
            return state.listener
        }
        guard fd >= 0 else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        close(fd)
        unlink(path)
    }

    deinit { stop() }

    private static func acceptLoop(_ fd: Int32, _ state: State) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if state.lock.withLock({ state.listener }) != fd { return }  // stopped
                usleep(10_000)
                continue
            }
            let reader = Thread { autoreleasepool { handle(client, state.onEvent) } }
            reader.name = "mellowharness.event-server.client"
            reader.start()
        }
    }

    /// Reads a connection's lines, handing on each as it ends, until the
    /// client closes it, it's quiet for half a second, or it has sent 1 MB.
    private static func handle(_ client: Int32, _ onEvent: @Sendable (Event) -> Void) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var pending = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 4096)
        while total < 1 << 20 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            total += n
            pending.append(contentsOf: buffer[0..<n])
            while let end = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<end]
                if !line.isEmpty, let e = decode(Data(line)) { onEvent(e) }
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        if !pending.isEmpty, let e = decode(pending) { onEvent(e) }
    }

    /// An event from a line: `source` and `kind` needed, `data`, `line` and
    /// `at` optional. Its `seq` is the log's to give.
    public static func decode(_ line: Data) -> Event? {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let source = o["source"] as? String, let kind = o["kind"] as? String, !source.isEmpty, !kind.isEmpty
        else { return nil }
        let data = (o["data"] as? [String: Any] ?? [:]).mapValues { JSONValue(foundation: $0) }
        return Event(at: (o["at"] as? NSNumber)?.int64Value ?? 0, source: source, kind: kind, line: o["line"] as? String,
                     data: data)
    }

    /// An event from a command line's words, `SOURCE KIND [key=value ...]`
    /// (`mellowharness-emit`): a value that's a whole number written plainly (`812`,
    /// `-3`, not `007` or `+4`) is one, `true` and `false` are yes and no,
    /// the rest strings. Nil without a source and a kind, or a word that
    /// isn't `key=value`.
    public static func event(from arguments: [String]) -> Event? {
        guard arguments.count >= 2 else { return nil }
        var data: [String: JSONValue] = [:]
        for word in arguments.dropFirst(2) {
            guard let eq = word.firstIndex(of: "="), eq != word.startIndex else { return nil }
            let key = String(word[..<eq]), value = String(word[word.index(after: eq)...])
            let number = Int64(value).flatMap { String($0) == value ? JSONValue.int($0) : nil }
            data[key] = number ?? (value == "true" ? .bool(true) : value == "false" ? .bool(false) : .string(value))
        }
        return Event(source: arguments[0], kind: arguments[1], data: data)
    }

    /// The line for `e`, as `send` writes it.
    public static func encode(_ e: Event) -> String {
        var o: [String: Any] = ["source": e.source, "kind": e.kind, "data": e.data.mapValues(\.foundation)]
        if let line = e.line { o["line"] = line }
        if e.at != 0 { o["at"] = NSNumber(value: e.at) }
        return JSONLine.encode(o)
    }

    /// Sends one event to the socket at `path`.
    public static func send(_ e: Event, to path: String) throws {
        guard var address = address(path) else { throw Failure.pathTooLong }
        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw Failure.socket(errno) }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw Failure.send }
        let bytes = Array((encode(e) + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw Failure.send }
            offset += n
        }
    }

    /// A `sockaddr_un` for `path`, or nil if it doesn't fit.
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in bytes.enumerated() { buffer[i] = byte }
            buffer[bytes.count] = 0
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return address
    }
}
