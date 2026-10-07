import Foundation

/// What a transform makes of an event: its line in
/// HISTORY and NOW, notes to go indented under it, and facts for your own
/// logs and tools, which the harness hands to `onLine` and never shows or
/// stores.
public struct Line: Equatable, Sendable, ExpressibleByStringInterpolation {
    public var text: String
    public var notes: [String]
    public var facts: [String: JSONValue]

    public init(_ text: String, notes: [String] = [], facts: [String: JSONValue] = [:]) {
        self.text = text
        self.notes = notes
        self.facts = facts
    }

    public init(stringLiteral value: String) { self.init(value) }

    /// The line a registered kind with no transform shows when its event
    /// has no `line`: `hold: secs 2`, its data's plain values, keys sorted.
    public static func fallback(_ e: Event) -> Line {
        let facts = e.data.keys.sorted().compactMap { key -> String? in
            switch e.data[key] {
            case .string(let s)?: "\(key) \(s)"
            case .int(let n)?: "\(key) \(n)"
            case .double(let d)?: "\(key) \(d)"
            case .bool(let b)?: "\(key) \(b)"
            default: nil
            }
        }
        return Line(facts.isEmpty ? e.kind : "\(e.kind): " + facts.joined(separator: ", "))
    }
}
