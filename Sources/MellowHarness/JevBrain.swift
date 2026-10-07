import Foundation

/// TypeSafe's Jev (https://docs.typesafe.ai/api), a brain:
/// the state as one string and every output's questions as choice
/// questions, in one request of about 0.2–0.3 s. Needs the person's API
/// key. Only a failed request's HTTP status is logged, since an error body
/// may repeat the request.
public struct JevBrain: Brain {
    public let id = "jev:\(JevBrain.model)"
    static let model = "jev-latest"
    let key: String
    /// Sends a request and returns the body and HTTP status. Tests pass their own.
    let send: @Sendable (URLRequest) async throws -> (Data, Int)

    public static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!

    /// A busy or failing server, or a dropped connection, is tried once more
    /// after this, as TypeSafe advises for 429 and 529, unless the pass's
    /// deadline would pass first: a request that goes on past the deadline
    /// (to time it) mustn't send another nobody waits for.
    static let retryAfterMs = 300

    public init(key: String, send: (@Sendable (URLRequest) async throws -> (Data, Int))? = nil) {
        self.key = key
        self.send = send ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    public func answer(state: String, questions: [Question], deadline: Duration) async throws -> Answers {
        var request = URLRequest(url: JevBrain.endpoint, timeoutInterval: Double(deadline.components.seconds) + 1)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = JevBrain.body(model: JevBrain.model, state: state, questions: questions)
        let started = ContinuousClock.now
        var (data, status) = try await sendOnce(request)
        if JevBrain.retryable(status), ContinuousClock.now - started + .milliseconds(JevBrain.retryAfterMs) < deadline {
            try await Task.sleep(for: .milliseconds(JevBrain.retryAfterMs))
            (data, status) = try await sendOnce(request)
        }
        // No server answered (offline, say), so there's no status to name.
        guard let status else { throw BrainError("jev: can't reach the server") }
        guard status == 200 else { throw BrainError("jev: HTTP \(status)", status: status) }
        return try JevBrain.answers(data, questions)
    }

    /// A 429, a 5xx, or a connection that failed (nil).
    static func retryable(_ status: Int?) -> Bool { status.map { $0 == 429 || $0 >= 500 } ?? true }

    /// The body and the HTTP status, or no status for a connection that
    /// failed (not one that timed out), which is tried again.
    func sendOnce(_ request: URLRequest) async throws -> (Data, Int?) {
        do {
            let (data, status) = try await send(request)
            return (data, status)
        } catch let error as URLError where error.code != .timedOut && error.code != .cancelled {
            return (Data(), nil)
        }
    }

    /// The request: each `Question` becomes a choice question.
    static func body(model: String, state: String, questions: [Question]) -> Data {
        var qs: [String: Any] = [:]
        for q in questions {
            var criteria: [String: Any] = [:]
            for o in q.options {
                criteria[o.name] = o.notFor.map { ["what": o.what, "not_for": $0] as [String: Any] } ?? o.what
            }
            qs[q.key] = ["type": "choice", "criteria": criteria,
                         "instructions": ["question": q.text, "about": q.about, "judge_by": q.judgeBy]] as [String: Any]
        }
        let object: [String: Any] = ["model": model, "state": state, "questions": qs]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    /// Every question's choice and probabilities. A question left out, or
    /// answered with an option it doesn't have, fails the whole answer.
    static func answers(_ data: Data, _ questions: [Question]) throws -> Answers {
        let raw = String(decoding: data, as: UTF8.self)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any]
        else { throw BrainError("jev: no answers", raw: raw) }
        var out: Answers = [:]
        for q in questions {
            guard let a = answers[q.key] as? [String: Any], let choice = a["choice"] as? String,
                  q.options.contains(where: { $0.name == choice })
            else { throw BrainError("jev: no usable answer for \(q.key)", raw: raw) }
            var probabilities: [String: Double] = [:]
            for (name, p) in (a["probabilities"] as? [String: Any]) ?? [:] {
                if let p = (p as? NSNumber)?.doubleValue { probabilities[name] = p }
            }
            // With no probabilities, the pick is reported at 1.
            out[q.key] = Answer(choice: choice, probabilities: probabilities.isEmpty ? [choice: 1] : probabilities)
        }
        return out
    }
}
