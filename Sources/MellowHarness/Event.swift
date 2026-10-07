import Foundation

/// One thing that happened: the same five fields for
/// every event, and `data` for everything else. `source` and `kind` are
/// free strings; the harness's own events are `self`'s (`did`, `ended`,
/// `pass`).
public struct Event: Equatable, Sendable {
    /// Its place in the log, counting on across days and launches; 0
    /// until it's logged.
    public var seq: Int
    /// When it happened, in unix milliseconds; 0 until it's logged, unless
    /// the emitter set it.
    public var at: Int64
    /// Who it's from: `ci`, `device`, `editor`, `self`.
    public var source: String
    /// What it is: `build_failed`, `press`, `turn_end`.
    public var kind: String
    /// A line of its own, for a kind registered with no transform.
    public var line: String?
    public var data: [String: JSONValue]

    public init(seq: Int = 0, at: Int64 = 0, source: String, kind: String, line: String? = nil,
                data: [String: JSONValue] = [:]) {
        self.seq = seq
        self.at = at
        self.source = source
        self.kind = kind
        self.line = line
        self.data = data
    }

    public subscript(_ key: String) -> JSONValue? { data[key] }

    /// The harness's own events' source.
    public static let harness = "self"

    // MARK: The harness's own events

    public static let did = "did", ended = "ended", pass = "pass"

    /// Whether it's one of the harness's own events: those never get a
    /// line of their own, nor wake the brain.
    public var fromHarness: Bool { source == Event.harness && (kind == Event.did || kind == Event.ended || kind == Event.pass) }

    /// What a rule or an output did: its `message` is the whole
    /// line HISTORY shows. `open` while it plays on. `facts` join
    /// the data as they are; the harness's own keys win a clash.
    public static func did(_ message: String, for about: Int?, action: String, by: String, ok: Bool = true,
                           open: Bool = false, facts: [String: JSONValue] = [:], at: Int64 = 0) -> Event {
        var data: [String: JSONValue] = ["for": about.map { .int(Int64($0)) } ?? .null, "by": .string(by),
                                         "action": .string(action), "ok": .bool(ok), "message": .string(message)]
        if open { data["open"] = true }
        return Event(at: at, source: harness, kind: did, data: data.merging(facts) { mine, _ in mine })
    }

    /// How something that took a while ended: `why` when it failed.
    public static func ended(_ did: Int, action: String, by: String, failed why: String? = nil, at: Int64 = 0) -> Event {
        var data: [String: JSONValue] = ["for": .int(Int64(did)), "action": .string(action), "by": .string(by),
                                         "outcome": why == nil ? "done" : "failed"]
        if let why { data["why"] = .string(why) }
        return Event(at: at, source: harness, kind: ended, data: data)
    }

    /// The `seq` a harness event is `for`, or nil.
    public var about: Int? { data["for"]?.int.map(Int.init) }

    /// The output's or rule's name, on a `did` or an `ended`.
    public var action: String? { data["action"]?.string }

    // MARK: The line

    /// The event as one JSON line: `seq`, `at`, `source`, `kind`, `line`
    /// when there is one, then `data` with its keys sorted.
    public var jsonLine: String {
        var parts = ["\"seq\":\(seq)", "\"at\":\(at)", "\"source\":\(JSONLine.encode(source))",
                     "\"kind\":\(JSONLine.encode(kind))"]
        if let line { parts.append("\"line\":\(JSONLine.encode(line))") }
        parts.append("\"data\":" + JSONLine.encode(data.mapValues(\.foundation)))
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// The event a line holds, or nil for a line that isn't one.
    public init?(jsonLine line: some StringProtocol) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        self.init(json: o)
    }

    public init?(json o: [String: Any]) {
        guard let seq = (o["seq"] as? NSNumber)?.intValue, let at = (o["at"] as? NSNumber)?.int64Value,
              let source = o["source"] as? String, let kind = o["kind"] as? String else { return nil }
        let data = (o["data"] as? [String: Any] ?? [:]).mapValues { JSONValue(foundation: $0) }
        self.init(seq: seq, at: at, source: source, kind: kind, line: o["line"] as? String, data: data)
    }
}

/// JSON the way the log writes it: keys sorted, slashes left alone.
public enum JSONLine {
    /// `value` as JSON: a string comes back quoted.
    public static func encode(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value,
                                                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
