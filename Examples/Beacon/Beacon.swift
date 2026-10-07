import MellowHarness
import Foundation

/// Beacon: a CI light with one button and three one-shots
/// it plays, `flash`, `wobble` and `cheer`. MellowHarness's worked example, as
/// small as it gets: builds failing and passing and the button, each a
/// line; a rule that flashes; a tone the brain can change, whose Markdown
/// file is a section; and one-shots the brain can play, in progress until
/// the light says they're done.
public final class Beacon {
    public let harness: Harness
    public let light: Light
    public let tone: Choice

    /// Beacon's steering folder, next to this file in the source tree.
    public static let steering = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("steering")

    /// `steering` is Beacon's folder (`Beacon.steering`); NOW's heading is
    /// in `timeZone`.
    public init(brain: (any Brain)?, log: Log, steering: URL, clock: Harness.Clock, queue: DispatchQueue,
                timeZone: TimeZone = .current, loop: Bool = true) throws {
        var options = Harness.Options()
        options.loop = loop
        options.heading = { ms in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "HH:mm, EEEE"
            return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        let h = Harness(name: "Beacon", brain: brain, log: log, clock: clock, queue: queue, options: options)
        let light = Light()
        let tone = Beacon.tone()
        let words = try Steering(folder: steering)
        harness = h
        self.light = light
        self.tone = tone

        // Inputs: each a line that looks back at the log.
        h.input("build_failed", wake: 1) { e, log in
            let branch = e["branch"]?.string ?? "main"
            let streak = log.count("build_failed", since: log.last("build_passed"))
            return streak == 0 ? "The build on \(branch) failed."
                : "The build on \(branch) failed again, \(streak + 1) in a row."
        }
        h.input("build_passed", wake: 1) { e, log in
            let branch = e["branch"]?.string ?? "main"
            let streak = log.count("build_failed", since: log.last("build_passed"))
            return streak == 0 ? "The build on \(branch) passed."
                : "The build on \(branch) passed after \(streak == 1 ? "failing" : "\(streak) failures")."
        }
        h.input("press", wake: 0) { _, log in
            let n = log.count("press", within: 3000)
            return n == 0 ? "You pressed the button." : "You pressed the button \(n + 1) times in a row."
        }
        h.hold("press") { _, log in log.count("press", within: 3000) >= 4 ? "the button is being mashed" : nil }
        h.input("still_red", wake: 1) { _, _ in "The build has been red for an hour." }
        try h.load(steering.appendingPathComponent("events.json"))

        // Rules: the light flashes at once, before the brain hears of it.
        h.on("build_failed") { [unowned h] e in
            light.do("flash", ["color": "red"])
            h.did("Beacon flashed red on its own.", for: e, action: "flash")
        }
        h.on("build_passed") { [unowned h] e in
            light.do("flash", ["color": "green"])
            h.did("Beacon flashed green on its own.", for: e, action: "flash")
        }

        // Outputs.
        h.output(tone)
        h.output(Play(light), openFor: 20_000)

        // The prompt.
        h.section { _ in words["guide"] }
        h.section { _ in words["personality"] }
        h.section { log in words["tone/\(tone.value(log))"] }
        // HISTORY reaches back to the red streak's first failure, however
        // long ago, while the build is red as of NOW, and when NOW is the
        // pass that ended it; once the build passed before NOW, it's back
        // to 10 min. It goes by NOW, not by the log's newest event: a
        // call can start after newer events came.
        h.reachBack { e, _, log in
            guard let failed = log.last("build_failed", where: { $0.seq < e.seq }) else { return nil }
            if log.last("build_passed", where: { $0.seq > failed.seq && $0.seq < e.seq }) != nil { return nil }
            return log.all("build_failed", since: log.last("build_passed") { $0.seq < failed.seq }).first?.at
        }
        h.closing { _, now, log in
            guard tone.value(log) != "calm", let since = tone.since(log) else { return nil }
            return "Beacon has been \(tone.value(log)) for \(Beacon.span(now - since))."
        }

        // A timed check: an hour of red is news of its own.
        h.tick { now, log in
            guard let red = log.last("build_failed"), log.last("build_passed").map({ $0.seq < red.seq }) ?? true,
                  now - red.at >= 3_600_000, log.count("still_red", since: red) == 0 else { return nil }
            return Event(source: "beacon", kind: "still_red")
        }
    }

    /// Beacon's tone, MellowHarness's `Choice`: calm, worried or grim.
    static func tone() -> Choice {
        Choice(name: "tone", start: "calm", question: "After NOW, how does Beacon feel?",
               judgeBy: "the TONE section, its reason to leave",
               said: { from, to in "Beacon went from \(from) to \(to)." },
               options: { current, _, _ in
                   let meaning = [
                       "calm": Option("calm", "At ease: a build passed, or a failure is a one-off."),
                       "worried": Option("worried", "Failures keep coming.", notFor: "A single failure."),
                       "grim": Option("grim", "The build has been red for an hour or more."),
                   ]
                   let moves = ["calm": ["worried"], "worried": ["calm", "grim"], "grim": ["worried", "calm"]][current] ?? []
                   return [Option(current, "Stay \(current): NOW is no reason to change it.")] + moves.compactMap { meaning[$0] }
               })
    }

    /// `under a minute`, `8 min`, `2 h`.
    static func span(_ ms: Int64) -> String {
        ms < 60_000 ? "under a minute" : ms < 3_600_000 ? "\(ms / 60_000) min" : "\(ms / 3_600_000) h"
    }
}

/// The light, as far as Beacon's brain needs it: what it was asked to play,
/// each with the handle to end once it has. A real one would send `do`
/// to the device over its link; this one keeps them until `finish`.
public final class Light: @unchecked Sendable {
    public private(set) var played: [(name: String, args: [String: String])] = []
    var ends: [Pending] = []

    public init() {}

    public func `do`(_ name: String, _ args: [String: String] = [:], ended: Pending? = nil) {
        played.append((name, args))
        if let ended { ends.append(ended) }
    }

    /// Whether something the brain asked for is still playing.
    public var playing: Bool { !ends.isEmpty }

    /// Everything playing ends, as the light would say. On the harness's queue.
    public func finish(_ end: Pending.End = .done) {
        let now = ends
        ends = []
        now.forEach { $0.finish(end) }
    }
}

/// What Beacon can play when the brain wakes: nothing, a wobble or a
/// cheer, in progress until the light says it's done.
final class Play: Action {
    let name = "play"
    let light: Light

    init(_ light: Light) { self.light = light }

    func questions(now: Event?, log: LogView) -> [Question] {
        [Question(key: "play", text: "Does Beacon play something now?", about: "the NOW section",
                  judgeBy: "the PERSONALITY and TONE sections",
                  options: [Option("none", "Nothing: NOW is no reason to, or HISTORY shows it still playing (in progress)."),
                            Option("wobble", "A worried wobble: the build looks shaky.", notFor: "A single failure."),
                            Option("cheer", "A cheer: the build came good again.", notFor: "Anything but a build passing.")])]
    }

    func run(_ answers: Answers, now: Event?, log: LogView) -> ActionResult? {
        guard let pick = answers["play"]?.choice, pick != "none" else { return nil }
        let p = Pending()
        light.do(pick, ended: p)
        return .started(pick == "wobble" ? "Beacon wobbled." : "Beacon cheered.", p)
    }
}
