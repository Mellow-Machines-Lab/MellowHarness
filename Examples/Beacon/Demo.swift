import MellowHarness
import Foundation

extension Beacon {
    /// A brain for the demo and its test, answering from NOW alone as the
    /// worked example says Jev might: worried and a wobble at the
    /// third failure in a row, calm and a cheer when the build passes after
    /// failing, and otherwise stay as it is and play nothing.
    public static let demoBrain = ScriptedBrain(id: "scripted") { state, questions in
        let now = state.components(separatedBy: "\nNOW (").last ?? ""
        let third = now.contains("failed again, 3 in a row")
        let passed = now.contains("passed after")
        var out: Answers = [:]
        for q in questions {
            let pick = switch q.key {
            case "tone": third ? "worried" : passed ? "calm" : q.options[0].name
            case "play": third ? "wobble" : passed ? "cheer" : "none"
            default: q.options[0].name
            }
            let choice = q.options.contains { $0.name == pick } ? pick : q.options[0].name
            out[q.key] = Answer(choice: choice, probabilities: [choice: 1])
        }
        return out
    }

    /// What the worked example's run came to: every event as the log
    /// wrote it, and every prompt the brain was sent, with NOW's line.
    public struct Run: Sendable {
        public var log: [String] = []
        public var prompts: [(now: String, prompt: String)] = []
    }

    /// 2026-10-14 14:00 UTC, a Wednesday.
    public static let start: Int64 = 1_791_986_400_000

    /// The worked example's timeline on a virtual clock from 14:00
    /// UTC: two failures, a press, a third failure and a press while the
    /// wobble plays, then the build passing. Each event that wakes the
    /// brain is answered straight through (`respond`), with `demoBrain`.
    public static func demo(steering: URL) async throws -> Run {
        final class Box: @unchecked Sendable {
            var now = Beacon.start
            var prompts: [(String, String)] = []
        }
        let box = Box()
        let brain = ScriptedBrain(id: "scripted") { state, questions in
            box.prompts.append((state.components(separatedBy: "\nNOW (").last.map { "NOW (" + $0 } ?? "", state))
            return try Beacon.demoBrain.script(state, questions)
        }
        let queue = DispatchQueue(label: "beacon.demo")
        let beacon = try Beacon(brain: brain, log: Log(), steering: steering, clock: .init(now: { box.now }), queue: queue,
                                timeZone: TimeZone(identifier: "UTC")!, loop: false)
        let h = beacon.harness
        func at(_ clock: String) {
            let parts = clock.split(separator: ":").compactMap { Int64($0) }
            box.now = Beacon.start + ((parts[0] - 14) * 3600 + parts[1] * 60 + (parts.count > 2 ? parts[2] : 0)) * 1000
        }
        func emit(_ kind: String, _ data: [String: JSONValue] = [:]) async {
            let e = queue.sync { h.emit(source: kind == "press" ? "device" : "ci", kind: kind, data: data) }
            _ = await h.respond(to: e)
        }
        at("14:01"); await emit("build_failed", ["branch": "main", "run": 812])
        at("14:05"); await emit("build_failed", ["branch": "main", "run": 813])
        at("14:06"); await emit("press")
        at("14:09"); await emit("build_failed", ["branch": "main", "run": 814])
        at("14:09:03"); await emit("press")
        at("14:09:08"); queue.sync { beacon.light.finish() }
        at("14:20"); await emit("build_passed", ["branch": "main", "run": 815])
        at("14:20:04"); queue.sync { beacon.light.finish() }
        var run = Run()
        run.log = queue.sync { h.log.events.map(\.jsonLine) }
        run.prompts = box.prompts.map { (now: $0.0, prompt: $0.1) }
        return run
    }
}

extension Beacon {
    /// Beacon live on the socket at `path`, which `mellowharness-emit` sends
    /// events to, with `demoBrain` and the system clock: `say` hears each
    /// line and pass as it happens. The light plays for two seconds, then
    /// says it's done. Keep what it returns while it runs.
    public static func listen(socket path: String, steering: URL, say: @escaping @Sendable (String) -> Void) throws
        -> (Beacon, EventServer) {
        let queue = DispatchQueue(label: "beacon")
        let beacon = try Beacon(brain: Beacon.demoBrain, log: Log(), steering: steering, clock: .system, queue: queue)
        let h = beacon.harness, light = beacon.light
        h.onLine = { e, line, wakes in say("▸ \(e.seq) \(e.kind)\(wakes ? "" : " (no pass)"): \(line.text)") }
        h.on(Event.did) { e in say("  \(e["open"]?.bool == true ? "…" : "✓") \(e.action ?? "?"): \(e["message"]?.string ?? "")") }
        h.onPass = { pass in
            let answers = pass.answers.keys.sorted().map { "\($0) \(pass.answers[$0]!.choice)" }.joined(separator: " · ")
            say("  pass \(pass.brain ?? pass.by ?? "?"): "
                + (pass.held.map { "held: \($0)" } ?? pass.dropped.map { "dropped: \($0)" } ?? answers))
            queue.asyncAfter(deadline: .now() + 2) { light.finish() }
        }
        let server = EventServer(path: path) { e in queue.async { h.emit(e) } }
        try server.start()
        queue.sync { h.start() }
        return (beacon, server)
    }
}
