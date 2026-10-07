import Foundation

/// A JSON value: an event's `data`.
public enum JSONValue: Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }

    /// An optional string, as a value or `null`.
    public static func of(_ s: String?) -> JSONValue { s.map(JSONValue.string) ?? .null }

    /// Plain Foundation objects, for `JSONSerialization`.
    public var foundation: Any {
        switch self {
        case .string(let s): s
        case .int(let n): NSNumber(value: n)
        case .double(let d): d.isFinite ? JSONValue.shortest(d) : NSNull()
        case .bool(let b): b
        case .array(let a): a.map(\.foundation)
        case .object(let o): o.mapValues(\.foundation)
        case .null: NSNull()
        }
    }

    /// `d` as a decimal of Swift's shortest form: `JSONSerialization` writes
    /// a double to 17 places, 0.97 as 0.96999999999999997. A decimal can't
    /// hold much past 1e±127, so a double it can't give back exactly goes
    /// as itself.
    static func shortest(_ d: Double) -> NSNumber {
        let n = NSDecimalNumber(string: String(d))
        return n != NSDecimalNumber.notANumber && n.doubleValue == d ? n : NSNumber(value: d)
    }

    /// A value from what `JSONSerialization` read: a whole number is an
    /// `int`, a fraction a `double`.
    public init(foundation value: Any?) {
        switch value {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            switch String(cString: n.objCType) {
            case "c", "B": self = .bool(n.boolValue)
            case "d", "f": self = n.doubleValue.rounded() == n.doubleValue && abs(n.doubleValue) < 9e15
                ? .int(n.int64Value) : .double(n.doubleValue)
            default: self = .int(n.int64Value)
            }
        case let a as [Any]: self = .array(a.map { JSONValue(foundation: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSONValue(foundation: $0) })
        default: self = .null
        }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var int: Int64? { if case .int(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    /// A number, whole or not.
    public var double: Double? {
        switch self {
        case .double(let d): d
        case .int(let n): Double(n)
        default: nil
        }
    }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}

extension JSONValue: CustomStringConvertible {
    /// The value as a line reads it, for `"\(e["branch"]!)"`: a string as
    /// itself, a number or yes and no as written, `null`, and an array or
    /// an object as JSON.
    public var description: String {
        switch self {
        case .string(let s): s
        case .int(let n): String(n)
        case .double(let d): String(d)
        case .bool(let b): String(b)
        case .null: "null"
        case .array, .object: JSONLine.encode(foundation)
        }
    }
}

// MARK: - Outputs: the output contract

/// One option of a question, with its meaning: what the brain judges it by.
public struct Option: Equatable, Sendable {
    public let name: String
    public let what: String
    /// What it isn't, when two options are easily confused.
    public let notFor: String?

    public init(_ name: String, _ what: String, notFor: String? = nil) {
        self.name = name
        self.what = what
        self.notFor = notFor
    }
}

/// A multiple-choice question an output asks the brain.
public struct Question: Equatable, Sendable {
    /// Unique across all outputs: `tone`, `say.feeling`.
    public let key: String
    public let text: String
    /// The part of the prompt it's about: `the NOW section`.
    public let about: String
    /// What to judge it by: `the TONE section, its reason to leave`.
    public let judgeBy: String
    public let options: [Option]

    public init(key: String, text: String, about: String, judgeBy: String, options: [Option]) {
        self.key = key
        self.text = text
        self.about = about
        self.judgeBy = judgeBy
        self.options = options
    }
}

/// The brain's answer to one question: its pick, and every option's
/// probability. A brain with none gives its pick 1.
public struct Answer: Equatable, Sendable {
    public let choice: String
    public let probabilities: [String: Double]

    public init(choice: String, probabilities: [String: Double] = [:]) {
        self.choice = choice
        self.probabilities = probabilities
    }

    /// The pick's probability.
    public var p: Double { probabilities[choice] ?? 0 }
}

/// Answers by question key.
public typealias Answers = [String: Answer]

/// What an output did: its `message` is the whole line HISTORY shows when
/// `ok`, the reason when not. A started one finishes later: HISTORY shows
/// it in progress until its `pending` ends.
public struct ActionResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String
    /// How a started output tells the harness it ended; nil for one that
    /// finished when `run` returned.
    public let pending: Pending?
    /// What the output says of its effect beyond its line, for your tools:
    /// the harness puts them in its `did`'s data as they are and never reads
    /// them.
    public let facts: [String: JSONValue]

    public init(ok: Bool, message: String, pending: Pending? = nil, facts: [String: JSONValue] = [:]) {
        self.ok = ok
        self.message = message
        self.pending = pending
        self.facts = facts
    }

    public static func done(_ message: String, facts: [String: JSONValue] = [:]) -> ActionResult {
        ActionResult(ok: true, message: message, facts: facts)
    }
    public static func failed(_ why: String) -> ActionResult { ActionResult(ok: false, message: why) }
    /// Started, and ends when `pending` is finished.
    public static func started(_ message: String, _ pending: Pending, facts: [String: JSONValue] = [:]) -> ActionResult {
        ActionResult(ok: true, message: message, pending: pending, facts: facts)
    }

    /// The same handle, not just an equal one.
    public static func == (a: ActionResult, b: ActionResult) -> Bool {
        a.ok == b.ok && a.message == b.message && a.pending === b.pending && a.facts == b.facts
    }
}

/// A started output's end, still to come: the output, or
/// whatever it hands this to, finishes it once it knows how things went.
/// Only the first `finish` counts, and one that comes before the harness
/// has logged the result is kept until it has. Touched only on the
/// harness's queue.
public final class Pending: @unchecked Sendable {
    public enum End: Equatable, Sendable {
        case done
        /// It never happened, and why.
        case failed(String)
    }

    /// How it ended, once it has; nil until then.
    private var end: End?
    /// Where the end goes, once it comes.
    private var delivers: [(End) -> Void] = []

    public init() {}

    public func finish(_ end: End) {
        guard self.end == nil else { return }
        self.end = end
        let now = delivers
        delivers = []
        now.forEach { $0(end) }
    }

    /// Hands `deliver` the end once it comes, or at once if it came first.
    /// The harness binds each started result's handle, to end its `did`;
    /// your own code may bind one too, to hear of it as well.
    public func bind(_ deliver: @escaping (End) -> Void) {
        if let end { deliver(end) } else { delivers.append(deliver) }
    }
}

/// An output: something your app can do when the
/// brain wakes. It builds its questions for every call, reads the brain's
/// answers to them, and reports what it did, or what it started. Its body
/// can call anything; the harness asks, logs and places the result.
public protocol Action: AnyObject {
    var name: String { get }
    /// Built for every call, all asked in one request, from the event the
    /// brain is answering (nil for a forced pass) and the log, so options
    /// can follow anything. Keys never change; options may.
    func questions(now: Event?, log: LogView) -> [Question]
    /// The brain's answers to this output's own questions, for `now` (nil
    /// for a forced pass). Nil means "did nothing". Called on the harness's
    /// queue; slow work is handed off.
    func run(_ answers: Answers, now: Event?, log: LogView) -> ActionResult?
}
