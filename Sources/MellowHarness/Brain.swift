import Foundation

/// The brain: answers multiple-choice questions about a plain-text state.
/// `JevBrain`, `ScriptedBrain` in tests, or your own: a local model,
/// another provider.
///
/// `state` is the whole prompt: your sections, then HISTORY and NOW.
/// Answer each question by its `key`, with the `name` of one of its
/// options, and probabilities if you have them. Each output reads only
/// its own keys and decides what a missing answer or a name it didn't
/// offer means: `Choice` changes nothing. Throwing drops the call, with
/// the error as the reason.
///
/// `deadline` is how long the call has. The loop drops an answer that
/// comes later and may start the next call while this one is still
/// running, so it can be called again before it returns. An eval's call
/// cancels the task at the deadline and waits for it, so check for
/// cancellation instead of blocking.
public protocol Brain: Sendable {
    /// For logs: `jev:jev-latest`, `scripted`.
    var id: String { get }
    func answer(state: String, questions: [Question], deadline: Duration) async throws -> Answers
}

public struct BrainError: Error, Equatable, CustomStringConvertible {
    public var description: String
    /// What came back, when it couldn't be used, for your own debugging.
    public var raw: String?
    /// The HTTP status, when the brain's server answered with an error.
    public var status: Int?

    public init(_ description: String, raw: String? = nil, status: Int? = nil) {
        self.description = description
        self.raw = raw
        self.status = status
    }
}

/// Answers from a script: for tests and replays. The script sees the state
/// and the questions and returns the answers, or throws.
public struct ScriptedBrain: Brain {
    public let id: String
    public let script: @Sendable (String, [Question]) throws -> Answers

    public init(id: String = "scripted", _ script: @escaping @Sendable (String, [Question]) throws -> Answers) {
        self.id = id
        self.script = script
    }

    /// The same answers every time, by question key; a question it has no
    /// answer for gets its first option. An answer given with no
    /// probabilities reports its pick at 1, as a brain with none does.
    public init(id: String = "scripted", always answers: Answers) {
        self.init(id: id) { _, questions in
            var out: Answers = [:]
            for q in questions {
                let pick = answers[q.key] ?? q.options.first.map { Answer(choice: $0.name) }
                out[q.key] = pick.map { $0.probabilities.isEmpty ? Answer(choice: $0.choice, probabilities: [$0.choice: 1]) : $0 }
            }
            return out
        }
    }

    public func answer(state: String, questions: [Question], deadline: Duration) async throws -> Answers {
        try script(state, questions)
    }
}
