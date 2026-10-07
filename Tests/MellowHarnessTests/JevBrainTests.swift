import Foundation
import Testing
@testable import MellowHarness

/// `JevBrain`: the request, the answer and its one retry,
/// with a `send` of the test's own instead of the network.
@Suite struct JevBrainTests {
    /// Each `Question` becomes a choice question: its options' meanings are
    /// the criteria, with `not_for` when there is one.
    @Test func testJevsRequest() throws {
        let q = Question(key: "word.feeling", text: "Which exclamation fits NOW?", about: "the NOW section",
                         judgeBy: "the PERSONALITY section", options: [Option("none", "No exclamation fits NOW."),
                                                                       Option("finally", "Something worked after failing.", notFor: "A first try.")])
        let body = JevBrain.body(model: "jev-latest", state: "STATE", questions: [q])
        let o = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(o["model"] as? String == "jev-latest")
        #expect(o["state"] as? String == "STATE")
        let question = try #require((o["questions"] as? [String: Any])?["word.feeling"] as? [String: Any])
        #expect(question["type"] as? String == "choice")
        let criteria = try #require(question["criteria"] as? [String: Any])
        #expect(criteria["none"] as? String == "No exclamation fits NOW.")
        #expect(criteria["finally"] as? [String: String] == ["what": "Something worked after failing.", "not_for": "A first try."])
        #expect(question["instructions"] as? [String: String]
                == ["question": "Which exclamation fits NOW?", "about": "the NOW section", "judge_by": "the PERSONALITY section"])
    }

    /// The answer's choices and probabilities; one missing, or off its
    /// options, fails it. A 429 is tried once more; only the status is kept.
    @Test func testJevsAnswerAndRetry() async throws {
        let q = [Question(key: "react", text: "?", about: "a", judgeBy: "b", options: [Option("none", "n"), Option("proud", "p")])]
        let good = Data(#"{"answers":{"react":{"choice":"proud","probabilities":{"proud":0.7,"none":0.3}}}}"#.utf8)
        #expect(try JevBrain.answers(good, q) == ["react": Answer(choice: "proud", probabilities: ["proud": 0.7, "none": 0.3])])
        #expect(throws: (any Error).self) { try JevBrain.answers(Data(#"{"answers":{"react":{"choice":"sad"}}}"#.utf8), q) }
        #expect(throws: (any Error).self) { try JevBrain.answers(Data(#"{"answers":{}}"#.utf8), q) }
        let calls = Lines()
        let jev = JevBrain(key: "k") { request in
            calls.add(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return calls.all.count == 1 ? (Data("PRIVATE".utf8), 429) : (good, 200)
        }
        let answers = try await jev.answer(state: "s", questions: q, deadline: .milliseconds(Harness.Options().deadlineMs))
        #expect(answers["react"]?.choice == "proud")
        #expect(calls.all == ["Bearer k", "Bearer k"])
        // No retry the deadline would cut off: it would only cost a request.
        let slow = Lines()
        let late = JevBrain(key: "k") { _ in
            slow.add("sent")
            try await Task.sleep(for: .milliseconds(150))
            return (Data(), 503)
        }
        do {
            _ = try await late.answer(state: "s", questions: q, deadline: .milliseconds(400))
            Issue.record("no answer")
        } catch let error as BrainError {
            #expect(error.description == "jev: HTTP 503")
        }
        #expect(slow.all == ["sent"], "150 ms, and 300 more, is past the 400")
        let down = JevBrain(key: "k") { _ in (Data("PRIVATE".utf8), 500) }
        do {
            _ = try await down.answer(state: "s", questions: q, deadline: .milliseconds(Harness.Options().deadlineMs))
            Issue.record("no answer")
        } catch let error as BrainError {
            #expect(error.description == "jev: HTTP 500", "only the status")
            #expect(error.status == 500)
        }
    }

    /// A connection that fails is tried once more, as a
    /// busy server is, but reads as the server out of reach, with no
    /// status, since no server answered; one that times out isn't retried.
    @Test func testJevOutOfReachIsNotAnHTTPStatus() async throws {
        let q = [Question(key: "react", text: "?", about: "a", judgeBy: "b", options: [Option("none", "n")])]
        let calls = Lines()
        let offline = JevBrain(key: "k") { _ in
            calls.add("sent")
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await offline.answer(state: "s", questions: q, deadline: .milliseconds(Harness.Options().deadlineMs))
            Issue.record("no answer")
        } catch let error as BrainError {
            #expect(error.description == "jev: can't reach the server")
            #expect(error.status == nil)
        }
        #expect(calls.all == ["sent", "sent"], "tried once more")
    }
}
