import Foundation

/// The one ready-made output: a named value the brain
/// can change, such as a tone or a mood. It stores nothing: its value is
/// the `to` of its latest `did` in the log, or `start`. Its options come
/// from your function, for every call; staying put is the brain picking
/// the value it has, which changes nothing and logs nothing.
public final class Choice: Action {
    public let name: String
    public let start: String
    let question: String
    let about: String
    let judgeBy: String
    let said: (String, String) -> String
    let options: (String, Event?, LogView) -> [Option]

    /// `said` is the whole line a change shows in HISTORY, from the value
    /// it had and the new one; `options` what the brain is offered, from
    /// the value it has, the event it's answering (nil for a forced pass)
    /// and the log.
    public init(name: String, start: String, question: String, about: String = "the NOW and HISTORY sections",
                judgeBy: String, said: ((String, String) -> String)? = nil,
                options: @escaping (String, Event?, LogView) -> [Option]) {
        self.name = name
        self.start = start
        self.question = question
        self.about = about
        self.judgeBy = judgeBy
        self.said = said ?? { from, to in "\(name) changed: \(from) → \(to)." }
        self.options = options
    }

    /// Its latest change in the log, if any.
    public func latest(_ log: LogView) -> Event? {
        log.lastDid(name) { $0["ok"]?.bool == true && $0["to"]?.string != nil }
    }

    /// The value it has.
    public func value(_ log: LogView) -> String { latest(log)?["to"]?.string ?? start }

    /// When it last changed, or nil for never, in the log's time.
    public func since(_ log: LogView) -> Int64? { latest(log)?.at }

    public func questions(now: Event?, log: LogView) -> [Question] {
        [Question(key: name, text: question, about: about, judgeBy: judgeBy, options: options(value(log), now, log))]
    }

    /// A pick that isn't one of the options it was offered changes nothing.
    public func run(_ answers: Answers, now: Event?, log: LogView) -> ActionResult? {
        guard let pick = answers[name]?.choice, options(value(log), now, log).contains(where: { $0.name == pick }) else {
            return nil
        }
        return set(pick, log: log)
    }

    /// Changes it to `to`, whatever the options: nil when it already is.
    public func set(_ to: String, log: LogView) -> ActionResult? {
        let from = value(log)
        guard to != from else { return nil }
        return .done(said(from, to), facts: ["from": .string(from), "to": .string(to)])
    }

    /// Sets it to `to` without a line: a value carried over from before
    /// the log kept it, such as your app's own file. The change is
    /// logged for no event, by `by`, with no message, so HISTORY never
    /// shows it; `since` is when it was logged. Returns the change, or nil
    /// when it already is `to`. On the harness's queue.
    @discardableResult
    public func restore(_ to: String, by: String, in harness: Harness) -> Event? {
        let from = value(harness.log.view(now: harness.clock.now()))
        guard to != from else { return nil }
        return harness.emit(Event(source: Event.harness, kind: Event.did,
                                  data: ["for": .null, "by": .string(by), "action": .string(name), "ok": true,
                                         "from": .string(from), "to": .string(to)]))
    }
}
