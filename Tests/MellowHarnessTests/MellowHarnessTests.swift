import Foundation
import Testing
@testable import MellowHarness

/// MellowHarness on its own, with toy outputs: events and the log,
/// lines, rules, the prompt, the loop, outputs and what takes a while,
/// `Choice`, the tick and the socket in. Serialized: its waits block.
@Suite(.serialized) final class MellowHarnessTests {
    nonisolated static let t0: Int64 = 1_790_690_400_000

    // MARK: Events and the log

    /// One JSON line, `seq`, `at`, `source`, `kind`, `line` when
    /// there is one, then `data` with its keys sorted; the harness's own events
    /// are `self`'s, `for` what they answer.
    @Test func testAnEventIsOneLine() throws {
        var e = Event(source: "ci", kind: "build_failed", data: ["run": 812, "branch": "main"])
        e.seq = 408
        e.at = 1_790_690_940_000
        #expect(e.jsonLine == #"{"seq":408,"at":1790690940000,"source":"ci","kind":"build_failed","data":{"branch":"main","run":812}}"#)
        #expect(Event(jsonLine: e.jsonLine) == e, "it reads back")
        var lined = Event(source: "ci", kind: "deploy", line: "Deployed.")
        lined.seq = 1
        #expect(lined.jsonLine == #"{"seq":1,"at":0,"source":"ci","kind":"deploy","line":"Deployed.","data":{}}"#)
        let did = Event.did("Beacon flashed red on its own.", for: 408, action: "flash", by: "rule", facts: ["for": 1, "color": "red"])
        #expect(did.source == "self")
        #expect(did.kind == "did")
        #expect(did.about == 408, "the harness's own keys win a clash")
        #expect(did["color"] == "red")
        #expect(did.fromHarness)
        #expect(Event.ended(412, action: "play", by: "brain", failed: "no device").data
                == ["for": 412, "action": "play", "by": "brain", "outcome": "failed", "why": "no device"])
        #expect(JSONLine.encode(JSONValue.object(["p": 0.97, "q": 0.812]).foundation) == #"{"p":0.97,"q":0.812}"#,
                "a fraction is written as short as it reads")
        #expect(JSONValue(foundation: try JSONSerialization.jsonObject(with: Data("[0.81, 2, true]".utf8))) as JSONValue
                == .array([.double(0.81), .int(2), .bool(true)]), "a fraction stays one")
    }

    /// A file a day, the last day in memory, `seq` on across a
    /// relaunch, a torn line skipped and ended, another shape read by
    /// `decode`, and files past `keptDays` deleted.
    @Test func testTheLogKeepsADayAndReadsItBack() throws {
        let dir = tempDir("mellowharness-log")
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = Log.Options()
        options.day = { ms in ms < Self.t0 ? "2026-09-29" : "2026-09-30" }
        options.decode = { line in line.hasPrefix("old ") ? Event(seq: 90, at: Self.t0 + 5, source: "old", kind: "x") : nil }
        let log = Log(folder: dir, options: options)
        let day = 24 * 3_600_000 as Int64
        log.append(Event(at: Self.t0 - day - 1, source: "ci", kind: "old_news"), now: Self.t0)
        log.append(Event(source: "ci", kind: "a"), now: Self.t0)
        log.append(Event(source: "ci", kind: "b"), now: Self.t0 + 1)
        let today = dir.appendingPathComponent("2026-09-30.jsonl")
        try (String(contentsOf: today, encoding: .utf8) + "old line\n" + #"{"seq":99,"at":"#).write(to: today, atomically: true, encoding: .utf8)
        try "{}\n".write(to: dir.appendingPathComponent("2026-09-01.jsonl"), atomically: true, encoding: .utf8)

        let again = Log(folder: dir, options: options)
        let read = again.load(now: Self.t0 + 10)
        #expect(read.map(\.kind) == ["a", "b", "x"], "the last day, the older shape too, the torn line skipped")
        #expect(again.lastSeq == 90, "seq goes on from the files' last")
        #expect(again.append(Event(source: "ci", kind: "c"), now: Self.t0 + 11).seq == 91)
        #expect(!(FileManager.default.fileExists(atPath: dir.appendingPathComponent("2026-09-01.jsonl").path)), "past 14 days")
        #expect(try String(contentsOf: today, encoding: .utf8).hasSuffix("\n"), "the torn line was ended")
    }

    /// A transform's view stops just before its event; the rest see
    /// everything so far.
    @Test func testLookingBack() {
        let log = Log()
        for (i, kind) in ["failed", "press", "failed", "passed", "failed"].enumerated() {
            log.append(Event(source: "ci", kind: kind, data: ["n": .int(Int64(i))]), now: Self.t0 + Int64(i) * 1000)
        }
        let last = log.events.last!
        let before = log.view(before: last)
        #expect(before.now == last.at)
        #expect(before.last("failed")?["n"] == 2, "not the event itself")
        #expect(before.count("failed") == 2)
        #expect(before.count("failed", since: before.last("passed")) == 0)
        #expect(before.all("failed", where: { $0["n"]?.int == 2 }).map(\.seq) == [3])
        #expect(before.count("failed", within: 2000) == 1, "at or after now - 2 s")
        #expect(before.events(after: 3).map(\.kind) == ["passed"])
        #expect(before.event(last.seq) == nil)
        #expect(log.view(now: Self.t0 + 4000).count("failed") == 3)
    }

    /// The defaults, 14 days of files (`keptDays`) and 24 hours in
    /// memory (`keepMs`): a file 13 days old is kept and one 14 days old
    /// deleted; an event 24 h old stays in memory and one a millisecond
    /// older is let go.
    @Test func testTheLogKeepsFourteenDaysOfFilesAndADayInMemory() {
        let options = Log.Options()
        #expect(options.keptDays == 14)
        #expect(options.keepMs == 24 * 60 * 60 * 1000)
        let dir = tempDir("mellowharness-days")
        defer { try? FileManager.default.removeItem(at: dir) }
        let day = 24 * 3_600_000 as Int64
        func file(_ daysBack: Int64) -> URL { dir.appendingPathComponent(Log.localDay(Self.t0 - daysBack * day) + ".jsonl") }
        for back: Int64 in [13, 14] { try! "{}\n".write(to: file(back), atomically: true, encoding: .utf8) }
        Log(folder: dir).prune(now: Self.t0)
        #expect(FileManager.default.fileExists(atPath: file(13).path))
        #expect(!FileManager.default.fileExists(atPath: file(14).path))
        let log = Log()
        log.append(Event(source: "ci", kind: "older"), now: Self.t0 - day - 1)
        log.append(Event(source: "ci", kind: "a day"), now: Self.t0 - day)
        log.trim(now: Self.t0)
        #expect(log.events.map(\.kind) == ["a day"])
    }

    /// A value reads as itself in a line, `"\(e["branch"]!)"` as
    /// `main`, not `string("main")`; an array or an object as JSON.
    @Test func testAValueReadsAsItself() {
        let e = Event(source: "ci", kind: "x", data: ["branch": "main", "run": 812, "p": 0.5, "ok": true, "none": .null])
        #expect("\(e["branch"]!) \(e["run"]!) \(e["p"]!) \(e["ok"]!) \(e["none"]!)" == "main 812 0.5 true null")
        #expect("\(JSONValue.object(["a": .array([1, "b"])]))" == #"{"a":[1,"b"]}"#)
    }

    // MARK: Lines and rules

    /// A transform's line (nil hides the event), a registered
    /// kind with none shows the event's own line or its data, a kind never
    /// registered has no line, and a JSON file registers templates.
    @Test func testLines() throws {
        let rig = Rig()
        rig.h.input("build_failed", wake: 1) { e, log in
            let streak = log.count("build_failed", since: log.last("build_passed"))
            return streak == 0 ? "The build on \(e["branch"]!.string!) failed."
                : "The build on \(e["branch"]!.string!) failed again, \(streak + 1) in a row."
        }
        rig.h.input("quiet") { _, _ in nil }
        rig.h.input("hold")
        let file = tempDir("mellowharness-events").appendingPathComponent("events.json")
        try Data(#"{"build_passed":{"line":"The build on {branch} passed for {who}.","wake":1}}"#.utf8).write(to: file)
        try rig.sync { try rig.h.load(file) }
        func line(_ e: Event) -> String? { rig.sync { rig.h.line(e.seq)?.text } }
        #expect(line(rig.emit("build_failed", ["branch": "main"])) == "The build on main failed.")
        #expect(line(rig.emit("build_failed", ["branch": "main"])) == "The build on main failed again, 2 in a row.")
        #expect(line(rig.emit("build_passed", ["branch": "main"])) == "The build on main passed for {who}.",
                "a field the event hasn't is left as written")
        #expect(line(rig.emit("build_failed", ["branch": "main"])) == "The build on main failed.")
        #expect(line(rig.emit("quiet")) == nil, "hidden")
        #expect(line(rig.emit("hold", ["secs": 2])) == "hold: secs 2")
        #expect(line(rig.sync { rig.h.emit(Event(source: "ci", kind: "hold", line: "Held for 2 s.")) }) == "Held for 2 s.")
        #expect(line(rig.emit("unregistered", ["x": 1])) == nil, "logged, with no line")
    }

    /// A rule runs at once, before the brain hears of the event, and
    /// what it did goes under it: NOW shows it, or that nothing was done.
    @Test func testRulesRunAtOnceAndNowShowsWhatTheyDid() {
        let rig = Rig()
        rig.h.input("build_failed", wake: 1) { e, _ in "The build on \(e["branch"]!.string!) failed." }
        rig.h.input("press", wake: 0) { _, _ in "You pressed the button." }
        var seen: [String] = []
        rig.h.on("*") { e in seen.append(e.kind) }
        rig.h.on("build_failed") { e in rig.h.did("Beacon flashed red on its own.", for: e, action: "flash") }
        let failed = rig.emit("build_failed", ["branch": "main"])
        #expect(seen == ["build_failed", "did"], "in the order they were registered, for every event, the harness's own too")
        #expect(rig.sync { rig.h.prompt(for: failed) }.components(separatedBy: "\n\n").last
                == "NOW (14:09, Wednesday)\nThe build on main failed.\nBeacon flashed red on its own.")
        let press = rig.emit("press")
        #expect(rig.sync { rig.h.prompt(for: press) }.hasSuffix("You pressed the button.\nBeacon did nothing on its own."))
    }

    // MARK: The prompt

    /// Your sections (an empty one left out), how to read the rest,
    /// HISTORY with relative times, notes and what was done in order, a
    /// failed or failed-ended one left out and an open one in progress,
    /// the closing line, then NOW. The same log gives the same text.
    @Test func testThePromptsLayout() {
        let rig = Rig()
        rig.h.input("build_failed", wake: 1) { e, _ in Line("The build on \(e["branch"]!.string!) failed.", notes: ["Run \(e["run"]!.int!)."]) }
        rig.h.input("press", wake: 0) { _, _ in "You pressed the button." }
        rig.h.section { _ in "GUIDE\nBe a light." }
        rig.h.section { _ in "" }
        rig.h.section { _ in nil }
        rig.h.section { log in "TONE\n\(log.count("press"))" }
        rig.h.closing { _, _, _ in "Beacon has been worried for 8 min." }
        let first = rig.emit("build_failed", ["branch": "main", "run": 812])
        rig.sync {
            rig.h.did("Beacon flashed red on its own.", for: first, action: "flash")
            rig.h.emit(Event.did("Beacon felt worried.", for: first.seq, action: "tone", by: "brain"))
            rig.h.emit(Event.did("no device", for: first.seq, action: "play", by: "brain", ok: false))
            let open = rig.h.emit(Event.did("Beacon wobbled.", for: first.seq, action: "play", by: "brain", open: true))
            let gone = rig.h.emit(Event.did("Beacon cheered.", for: first.seq, action: "play", by: "brain", open: true))
            rig.h.emit(Event.ended(gone.seq, action: "play", by: "brain", failed: "skipped"))
            _ = open
        }
        rig.clock.now += 4 * 60_000
        let press = rig.emit("press")
        let prompt = rig.sync { rig.h.prompt(for: press) }
        #expect(prompt == """
            GUIDE
            Be a light.

            TONE
            1

            How to read HISTORY and NOW:
            - HISTORY is oldest first. Each line says how long ago it happened.
              Lines indented under it add to it: its notes, then what Beacon did.
              A line of what Beacon did ending in (in progress) hasn't finished yet.
            - NOW is what to react to. Its last line is what Beacon already did on
              its own, by reflex.

            HISTORY (oldest first; indented lines add to the line above)
            4 min ago: The build on main failed.
              Run 812.
              Beacon flashed red on its own.
              Beacon felt worried.
              Beacon wobbled. (in progress)
            Beacon has been worried for 8 min.

            NOW (14:09, Wednesday)
            You pressed the button.
            Beacon did nothing on its own.
            """)
        #expect(rig.sync { rig.h.prompt(for: press) } == prompt, "a pure function of the log and the time")
        #expect(Harness.ago(59_999) == "just now")
        #expect(Harness.ago(60_000) == "1 min ago")
        #expect(Harness.ago(3_599_999) == "59 min ago")
        #expect(Harness.ago(7_200_000) == "2 h ago")
    }

    /// HISTORY holds the last 10 minutes, or back to `reachBack`
    /// when that's further; then at most the newest 40, and any older one
    /// in that time whose `did` is still in progress. How to read it can be
    /// yours, or none.
    @Test func testHistoryReachesBackAndHoldsForty() {
        var options = Harness.Options()
        options.reading = .none
        let rig = Rig(options: options)
        rig.h.input("tick", wake: 0) { e, _ in "Tick \(e["n"]!.int!)." }
        var back: Int64?
        rig.h.reachBack { _, _, _ in back }
        let old = rig.emit("tick", ["n": 0])
        rig.sync { _ = rig.h.emit(Event.did("Beacon hummed.", for: old.seq, action: "hum", by: "brain", open: true)) }
        rig.clock.now += 60_000
        for n in 1...41 { rig.emit("tick", ["n": .int(Int64(n))]) }
        var now = rig.emit("tick", ["n": 42])
        func history() -> [String] {
            let prompt = rig.sync { rig.h.prompt(for: now) }
            let lines = prompt.components(separatedBy: "\n\n")[0].split(separator: "\n").map(String.init)
            return lines.filter { $0.contains("Tick") }
        }
        #expect(history().count == 1 + 40, "the newest 40, and the one still in progress")
        #expect(history().first == "1 min ago: Tick 0.")
        #expect(history()[1] == "just now: Tick 2.")
        rig.clock.now += 11 * 60_000
        now = rig.emit("tick", ["n": 43])
        #expect(history() == [], "all past 10 minutes, in progress or not")
        back = MellowHarnessTests.t0
        #expect(history().first == "12 min ago: Tick 0.", "reaching back")
        #expect(history().count == 1 + 40)
        #expect(!(rig.sync { rig.h.prompt(for: now) }.contains("How to read")), "none of the harness's words")
    }

    // MARK: The loop

    /// One call at a time; what goes next is worked out from the log:
    /// the highest wake first, oldest first within it, one at 0 passed
    /// over for anything newer, none older than 10 s, and a held one
    /// logged as a pass with why, the brain not asked.
    @Test func testWhatTheBrainAnswersNext() {
        let gate = DispatchSemaphore(value: 0)
        let asked = Lines()
        let brain = ScriptedBrain { state, _ in
            asked.add(String(state.split(separator: "\n").reversed()[1]))
            gate.wait()
            return [:]
        }
        let rig = Rig(brain: brain)
        for (kind, wake) in [("routine", 0), ("finish", 1), ("talk", 2)] {
            rig.h.input(kind, wake: wake) { e, _ in "\(kind) \(e["n"]!.int!)" }
        }
        var holding = false
        rig.h.input("press", wake: 0) { _, _ in "press" }
        rig.h.hold("press") { _, _ in holding ? "Beacon is busy" : nil }
        rig.emit("routine", ["n": 1])
        eventually("the first call") { asked.all == ["routine 1"] }
        rig.emit("routine", ["n": 2])
        rig.emit("finish", ["n": 3])
        rig.emit("routine", ["n": 4])
        rig.emit("finish", ["n": 5])
        rig.emit("talk", ["n": 6])
        rig.emit("routine", ["n": 7])
        for _ in 0..<5 { gate.signal() }
        eventually("the rest") { rig.sync { rig.h.idle } }
        #expect(asked.all == ["routine 1", "talk 6", "finish 3", "finish 5", "routine 7"],
                "what you said first, finishes oldest first, and the newest routine one: \(asked.all)")

        holding = true
        rig.emit("press")
        let held = rig.sync { rig.h.log.events.last { $0.kind == Event.pass } }
        #expect(held?["held"] == "Beacon is busy")
        #expect(asked.all.count == 5, "the brain wasn't asked")
        holding = false
        rig.clock.now += 11_000
        #expect(rig.sync { rig.h.idle }, "nothing older than 10 s waits, the held press answered")
    }

    /// An event waits at most 10 s (`maxWaitMs`): one 10 s old when a
    /// brain comes is answered, one a millisecond older never is.
    @Test func testAnEventWaitsTenSecondsAtMost() {
        #expect(Harness.Options().maxWaitMs == 10_000)
        for (age, answered) in [(10_000 as Int64, true), (10_001, false)] {
            let rig = Rig()
            rig.h.input("go", wake: 1) { _, _ in "Go." }
            let go = rig.emit("go")
            rig.clock.now += age
            rig.sync { rig.h.use(ScriptedBrain(always: [:])) }
            eventually("the call") { rig.sync { rig.h.idle } }
            #expect(rig.sync { rig.h.log.answered(go.seq) } == answered, "\(age) ms old")
        }
    }

    /// A relaunch answers nothing from before it, however recent: an
    /// event logged a second before the launch never gets a pass, and the
    /// next one does.
    @Test func testARelaunchAnswersNothingFromBeforeIt() {
        let dir = tempDir("mellowharness-relaunch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Rig(log: Log(folder: dir))
        first.h.input("go", wake: 1) { _, _ in "Go." }
        let before = first.emit("go")
        let again = Rig(brain: ScriptedBrain(always: [:]), log: Log(folder: dir))
        again.clock.now = first.clock.now + 1000
        again.h.input("go", wake: 1) { _, _ in "Go." }
        again.sync { _ = again.h.resume() }
        #expect(again.sync { again.h.idle }, "nothing waits")
        let after = again.emit("go")
        eventually("the new one's call") { again.sync { again.h.log.answered(after.seq) } }
        #expect(!again.sync { again.h.log.answered(before.seq) }, "the one from before the launch")
    }

    /// Question keys asked twice, across two outputs or in one,
    /// drop the pass with why: the brain isn't asked and no output runs,
    /// and a forced pass is dropped the same way. Nothing crashes.
    @Test func testQuestionKeysAskedTwiceDropThePass() async {
        let asked = Lines()
        let rig = Rig(brain: ScriptedBrain { _, _ in
            asked.add("asked")
            return [:]
        })
        let a = ToyOutput("a", keys: ["k"], result: .done("Beacon did a."))
        let b = ToyOutput("b", keys: ["k"], result: .done("Beacon did b."))
        rig.h.output(a)
        rig.h.output(b)
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        let go = rig.emit("go")
        let why = "question keys must be unique across outputs: k asked twice"
        let pass = rig.sync { rig.h.log.events.last { $0.kind == Event.pass } }
        #expect(pass?.about == go.seq)
        #expect(pass?["dropped"] == .string(why))
        #expect(rig.sync { rig.h.idle })
        #expect(rig.sync { rig.h.force(["k": "x"], by: "dashboard") }.isEmpty)
        #expect(rig.sync { rig.h.log.events.last { $0.kind == Event.pass }?["dropped"] } == .string(why))
        #expect(asked.all.isEmpty && a.got.isEmpty && b.got.isEmpty)
        #expect(rig.sync { rig.h.log.events.filter { $0.kind == Event.did } }.isEmpty)

        var options = Harness.Options()
        options.loop = false
        let one = Rig(brain: ScriptedBrain(always: [:]), options: options)
        let twice = ToyOutput("twice", keys: ["k", "k"], result: .done("Beacon did it twice."))
        one.h.output(twice)
        one.h.input("go", wake: 0) { _, _ in "Go." }
        let dropped = await one.h.respond(to: one.emit("go"))
        #expect(dropped?.dropped == why)
        #expect(dropped?.prompt == nil, "nothing was asked")
        #expect(twice.got.isEmpty)
    }

    /// Each output gets only its own answers, in order; nil does
    /// nothing; each result is a `did` for the event, by the brain. A brain
    /// that fails, or answers late, drops the call and runs no output. The
    /// `pass` event keeps the answers.
    @Test func testOutputsAndDroppedCalls() throws {
        let rig = Rig(brain: ScriptedBrain { _, _ in
            ["a1": Answer(choice: "x", probabilities: ["x": 0.8123, "y": 0.1877]), "b1": Answer(choice: "y")]
        })
        let a = ToyOutput("a", keys: ["a1"], result: .done("Beacon did a."))
        let b = ToyOutput("b", keys: ["b1"], result: nil)
        rig.h.output(a)
        rig.h.output(b)
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        var passes: [Harness.Pass] = []
        rig.h.onPass = { passes.append($0) }
        let go = rig.emit("go")
        eventually("the pass") { rig.sync { !passes.isEmpty } }
        #expect(a.got.map { Array($0.keys) } == [["a1"]])
        #expect(b.got.map { Array($0.keys) } == [["b1"]])
        let dids = rig.sync { rig.h.log.dids(for: go.seq) }
        #expect(dids.map(\.action) == ["a"], "nil logs nothing")
        #expect(dids.first?["by"] == "brain")
        let pass = try #require(rig.sync { rig.h.log.events.last { $0.kind == Event.pass } })
        #expect(pass.about == go.seq)
        #expect(pass["answers"]?.object?["a1"]?.object?["p"]?.object?["x"] == .double(0.812), "three places")
        #expect(passes.first?.actions.map(\.name) == ["a"])
        #expect(passes.first?.prompt?.hasSuffix("NOW (14:09, Wednesday)\nGo.\nBeacon did nothing on its own.") == true)

        let failing = Rig(brain: ScriptedBrain { _, _ in throw BrainError("nope") })
        let c = ToyOutput("c", keys: ["c1"], result: .done("Beacon did c."))
        failing.h.output(c)
        failing.h.input("go", wake: 0) { _, _ in "Go." }
        failing.emit("go")
        eventually("dropped") { failing.sync { failing.h.log.events.contains { $0.kind == Event.pass } } }
        #expect(failing.sync { failing.h.log.events.last { $0.kind == Event.pass }?["dropped"] } == "nope")
        #expect(c.got.isEmpty)

        var late = Harness.Options()
        late.deadlineMs = 50
        let notes = Lines()
        let slow = Rig(brain: SlowBrain(ms: 200), options: late, note: { notes.add($0) })
        slow.h.input("go", wake: 0) { _, _ in "Go." }
        slow.emit("go")
        eventually("late") { slow.sync { slow.h.log.events.contains { $0.kind == Event.pass } } }
        #expect(slow.sync { slow.h.log.events.last { $0.kind == Event.pass }?["dropped"] } == "late: no answer within 50 ms")
        eventually("its answer, timed") { notes.all.contains { $0.hasPrefix("harness: slow answered after ") } }
    }

    /// An answer that comes after the deadline runs no output: the
    /// pass was dropped as late, and the answer is only noted.
    @Test func testALateAnswerRunsNoOutput() {
        var options = Harness.Options()
        options.deadlineMs = 50
        let notes = Lines()
        let rig = Rig(brain: SlowBrain(ms: 200, answers: ["a1": Answer(choice: "x")]), options: options,
                      note: { notes.add($0) })
        let a = ToyOutput("a", keys: ["a1"], result: .done("Beacon did a."))
        rig.h.output(a)
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        let go = rig.emit("go")
        eventually("its answer, timed") { notes.all.contains { $0.hasPrefix("harness: slow answered after ") } }
        #expect(rig.sync { rig.h.log.events.last { $0.kind == Event.pass }?["dropped"] } == "late: no answer within 50 ms")
        #expect(a.got.isEmpty)
        #expect(rig.sync { rig.h.log.dids(for: go.seq) }.isEmpty)
    }

    /// The deadline cuts a call off on time: its timer fires within
    /// 5 ms of it, where the system's default leeway let it fire up to 7%
    /// (105 ms) late, so an answer just past it was kept or dropped by
    /// chance. The leeway is pinned exactly. The wall clock is checked only
    /// off CI: a shared runner took 1635 ms, whatever the leeway.
    @Test func testTheDeadlineComesOnTime() async {
        #expect(Harness.Options().deadlineMs == 1500)
        #expect(Harness.Options().deadlineLeewayMs == 5)
        var options = Harness.Options()
        options.loop = false
        let runs = (0..<4).map { _ -> (Rig, Event) in
            let rig = Rig(brain: SlowBrain(ms: 3000), options: options)
            rig.h.input("go", wake: 0) { _, _ in "Go." }
            return (rig, rig.emit("go"))
        }
        let ms = await withTaskGroup(of: Int.self) { group in
            for (rig, e) in runs {
                group.addTask {
                    let started = ContinuousClock.now
                    _ = await rig.h.respond(to: e)
                    return (ContinuousClock.now - started).ms
                }
            }
            var all: [Int] = []
            for await one in group { all.append(one) }
            return all
        }
        if ProcessInfo.processInfo.environment["CI"] == nil {
            #expect(ms.max() ?? 0 < 1590, "\(ms)")
        }
    }

    // MARK: What takes a while

    /// A started result is an open `did`, in progress until its
    /// handle ends it; a handle ended before the harness had the result is
    /// kept; only the first end counts; one left open past `openFor` is
    /// ended on the tick; one open at a relaunch is ended as restarted.
    @Test func testSomethingThatTakesAWhile() throws {
        let dir = tempDir("mellowharness-open")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rig = Rig(brain: ScriptedBrain(always: [:]), log: Log(folder: dir))
        let play = ToyOutput("play", keys: ["play"], result: nil)
        rig.h.output(play, openFor: 20_000)
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        func open() -> [Int] { rig.sync { rig.h.log.openDids.sorted() } }
        func ended(_ seq: Int) -> String? { rig.sync { rig.h.log.ended(seq)?["outcome"]?.string } }

        var handle = Pending()
        play.result = .started("Beacon wobbled.", handle)
        let first = rig.emit("go")
        eventually("started") { !open().isEmpty }
        let wobble = open()[0]
        #expect(rig.sync { rig.h.prompt(for: first) }.contains("Beacon did nothing on its own."))
        let later = rig.emit("tick")
        #expect(rig.sync { rig.h.prompt(for: later) }.contains("  Beacon wobbled. (in progress)"))
        rig.sync { handle.finish(.done) }
        #expect(ended(wobble) == "done")
        rig.sync { handle.finish(.failed("too late")) }
        #expect(rig.sync { rig.h.log.events.filter { $0.kind == Event.ended }.count } == 1, "only the first end counts")

        handle = Pending()
        handle.finish(.failed("no device"))
        play.result = .started("Beacon cheered.", handle)
        rig.emit("go")
        eventually("its end, kept") { rig.sync { rig.h.log.events.filter { $0.kind == Event.ended }.count } == 2 }
        #expect(open().isEmpty)

        play.result = .started("Beacon wobbled.", Pending())
        rig.emit("go")
        eventually("started") { open().count == 1 }
        let stuck = open()[0]
        rig.clock.now += 19_999
        rig.sync { rig.h.tick() }
        #expect(ended(stuck) == nil)
        rig.clock.now += 1
        rig.sync { rig.h.tick() }
        #expect(rig.sync { rig.h.log.ended(stuck)?["why"] } == .string(Harness.noWord))

        play.result = .started("Beacon wobbled.", Pending())
        rig.emit("go")
        eventually("started") { open().count == 1 }
        let relaunched = Rig(log: Log(folder: dir))
        relaunched.clock.now = rig.clock.now
        let read = relaunched.sync { relaunched.h.resume() }
        #expect(read.count > 0)
        #expect(relaunched.sync { relaunched.h.log.events.last?["why"] } == .string(Harness.restarted))
        #expect(relaunched.sync { relaunched.h.log.openDids.isEmpty })
    }

    // MARK: Forced passes

    /// Forced answers at probability 1, for no event, by who forced
    /// them, a choice that isn't offered left out; the `did` shows under
    /// the latest line before it. An output that acted outside a call
    /// while one ran sits that call's answers out.
    @Test func testForcedPasses() {
        let gate = DispatchSemaphore(value: 0)
        let rig = Rig(brain: ScriptedBrain { _, _ in
            gate.wait()
            return ["a1": Answer(choice: "x")]
        })
        let a = ToyOutput("a", keys: ["a1"], result: .done("Beacon did a."))
        rig.h.output(a)
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        let go = rig.emit("go")
        let ran = rig.sync { rig.h.force(["a1": "y", "zz": "q"], by: "dashboard") }
        #expect(ran.map(\.name) == ["a"])
        #expect(a.got.last?["a1"] == Answer(choice: "y", probabilities: ["y": 1]))
        let forced = rig.sync { rig.h.log.events.last { $0.kind == Event.pass } }
        #expect(forced?["by"] == "dashboard")
        #expect(forced?["for"] == .null)
        gate.signal()
        eventually("the call") { rig.sync { rig.h.log.answered(go.seq) } }
        #expect(a.got.count == 1, "it acted while the call ran, so it sat that call's answers out")
        let next = rig.emit("tick")
        #expect(rig.sync { rig.h.prompt(for: next) }.contains("Go.\n  Beacon did a."), "under the latest line before it")
    }

    // MARK: Choice

    /// Its value is the latest change in the log, or its start;
    /// staying is nothing; a pick it didn't offer changes nothing; `set`
    /// changes it whatever the options; a relaunch reads it back.
    @Test func testChoice() {
        let log = Log()
        let tone = Choice(name: "tone", start: "calm", question: "After NOW, how does Beacon feel?",
                          judgeBy: "the TONE section, its reason to leave",
                          said: { from, to in "Beacon went from \(from) to \(to)." },
                          options: { current, _, _ in
                              current == "calm" ? [Option("calm", "Stay calm."), Option("worried", "Failures keep coming.")]
                                  : [Option("worried", "Stay worried."), Option("calm", "A build passed.")]
                          })
        func view() -> LogView { log.view(now: Self.t0) }
        func run(_ pick: String) -> ActionResult? {
            let result = tone.run(["tone": Answer(choice: pick)], now: nil, log: view())
            if let result { log.append(Event.did(result.message, for: nil, action: "tone", by: "brain", facts: result.facts), now: Self.t0) }
            return result
        }
        #expect(tone.value(view()) == "calm")
        #expect(tone.since(view()) == nil)
        #expect(tone.questions(now: nil, log: view())[0].options.map(\.name) == ["calm", "worried"])
        #expect(tone.questions(now: nil, log: view())[0].about == "the NOW and HISTORY sections")
        #expect(run("calm") == nil, "staying is nothing")
        #expect(run("grim") == nil, "not offered")
        #expect(run("worried") == .done("Beacon went from calm to worried.", facts: ["from": "calm", "to": "worried"]))
        #expect(tone.value(view()) == "worried")
        #expect(tone.since(view()) == Self.t0)
        #expect(tone.questions(now: nil, log: view())[0].options.map(\.name) == ["worried", "calm"])
        #expect(tone.set("grim", log: view())?.message == "Beacon went from worried to grim.", "whatever the options")
        let again = Choice(name: "tone", start: "calm", question: "?", judgeBy: "?", options: { _, _, _ in [] })
        #expect(again.value(view()) == "worried", "nothing to restore: it's the log's")
    }

    /// `restore` carries a value over without a line: it's the value
    /// from then on, by who restored it, HISTORY never shows it, and
    /// restoring the value it has logs nothing.
    @Test func testARestoredChoiceHasNoLine() {
        let rig = Rig()
        let tone = Choice(name: "tone", start: "calm", question: "?", judgeBy: "?", options: { _, _, _ in [] })
        rig.h.output(tone)
        rig.h.input("press", wake: 0) { _, _ in "You pressed the button." }
        rig.emit("press")
        let restored = rig.sync { tone.restore("worried", by: "upgrade", in: rig.h) }
        #expect(restored?["by"] == "upgrade")
        #expect(restored?["from"] == "calm")
        #expect(restored?["message"] == nil)
        #expect(rig.sync { tone.value(rig.h.log.view(now: rig.clock.now)) } == "worried")
        #expect(rig.sync { tone.since(rig.h.log.view(now: rig.clock.now)) } == restored?.at)
        #expect(rig.sync { tone.restore("worried", by: "upgrade", in: rig.h) } == nil, "already worried")
        let next = rig.emit("press")
        let prompt = rig.sync { rig.h.prompt(for: next) }
        #expect(!prompt.contains("worried") && !prompt.contains("tone"), "HISTORY shows no line for it: \(prompt)")
    }

    // MARK: The tick

    /// A timed check emits what it returns, and doesn't fire twice
    /// because the log says it already did.
    @Test func testTimedChecks() {
        let rig = Rig()
        rig.h.input("build_failed", wake: 1) { _, _ in "The build failed." }
        rig.h.input("still_red", wake: 1) { _, _ in "The build has been red for an hour." }
        rig.h.tick { now, log in
            guard let red = log.last("build_failed"), now - red.at >= 3_600_000, log.count("still_red", since: red) == 0 else { return nil }
            return Event(source: "beacon", kind: "still_red")
        }
        rig.emit("build_failed")
        rig.clock.now += 3_599_999
        rig.sync { rig.h.tick() }
        #expect(rig.sync { rig.h.log.view(now: rig.clock.now).count("still_red") } == 0)
        rig.clock.now += 1
        rig.sync { rig.h.tick() }
        rig.sync { rig.h.tick() }
        #expect(rig.sync { rig.h.log.view(now: rig.clock.now).count("still_red") } == 1, "once")
    }

    /// Another process sends events through the socket, which the
    /// harness emits like any other.
    @Test func testTheSocketIn() throws {
        let rig = Rig()
        rig.h.input("build_failed", wake: 1) { e, _ in "The build on \(e["branch"]!.string!) failed." }
        let path = NSTemporaryDirectory() + "jh-\(UUID().uuidString.prefix(6)).sock"
        let server = EventServer(path: path) { e in rig.home.async { rig.h.emit(e) } }
        try server.start()
        defer { server.stop() }
        try EventServer.send(Event(source: "ci", kind: "build_failed", data: ["branch": "main", "run": 812]), to: path)
        eventually("emitted") { rig.sync { rig.h.log.view(now: rig.clock.now).count("build_failed") } == 1 }
        let e = try #require(rig.sync { rig.h.log.events.last })
        #expect(e.source == "ci")
        #expect(e["run"] == 812)
        #expect(rig.sync { rig.h.line(e.seq)?.text } == "The build on main failed.")
        #expect(EventServer.decode(Data(#"{"kind":"x"}"#.utf8)) == nil, "a source is needed")
        let words = try #require(EventServer.event(from: ["ci", "build_failed", "branch=main", "run=812", "green=false"]))
        #expect(words.data == ["branch": "main", "run": 812, "green": false], "mellowharness-emit's words")
        #expect(EventServer.event(from: ["ci"]) == nil)
        #expect(EventServer.event(from: ["ci", "x", "=1"]) == nil)
    }

    /// For evals: one event straight through, without the loop: nil
    /// when it doesn't wake the brain or is held.
    @Test func testOneEventStraightThrough() async {
        var options = Harness.Options()
        options.loop = false
        let rig = Rig(brain: ScriptedBrain(always: [:]), options: options)
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        rig.h.input("held", wake: 0) { _, _ in "Held." }
        rig.h.hold("held") { _, _ in "no" }
        rig.h.input("quiet") { _, _ in "Quiet." }
        let go = rig.emit("go")
        #expect(!(rig.sync { rig.h.log.answered(go.seq) }), "no loop")
        let pass = await rig.h.respond(to: go)
        #expect(pass?.line == "Go.")
        let held = await rig.h.respond(to: rig.emit("held"))
        #expect(held == nil)
        let quiet = await rig.h.respond(to: rig.emit("quiet"))
        #expect(quiet == nil)
    }

    // MARK: The brain

    /// `ScriptedBrain(always:)` reports a pick given with no
    /// probabilities at 1, as a brain with none does; probabilities given
    /// are kept, and a question it has no answer for gets its first option
    /// at 1.
    @Test func testAScriptedBrainsPicksAreAtOne() async throws {
        let q = { (key: String) in
            Question(key: key, text: "?", about: "the NOW section", judgeBy: "x", options: [Option("x", "X"), Option("y", "Y")])
        }
        let brain = ScriptedBrain(always: ["a": Answer(choice: "y"), "b": Answer(choice: "y", probabilities: ["x": 0.3, "y": 0.7])])
        let got = try await brain.answer(state: "", questions: [q("a"), q("b"), q("c")], deadline: .seconds(1))
        #expect(got["a"] == Answer(choice: "y", probabilities: ["y": 1]))
        #expect(got["a"]?.p == 1)
        #expect(got["b"] == Answer(choice: "y", probabilities: ["x": 0.3, "y": 0.7]), "given ones kept")
        #expect(got["c"] == Answer(choice: "x", probabilities: ["x": 1]))
    }
}

/// A clock the tests move by hand.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var ms: Int64
    init(_ ms: Int64) { self.ms = ms }
    var now: Int64 {
        get { lock.withLock { ms } }
        set { lock.withLock { ms = newValue } }
    }
}

/// A harness named Beacon on its own queue and a hand-moved clock, its
/// heading fixed.
final class Rig: @unchecked Sendable {
    let home = DispatchQueue(label: "mellowharness.test")
    let clock = TestClock(MellowHarnessTests.t0)
    let h: Harness

    init(brain: (any Brain)? = nil, options: Harness.Options = Harness.Options(), log: Log = Log(),
         note: @escaping (String) -> Void = { _ in }) {
        var o = options
        o.heading = { _ in "14:09, Wednesday" }
        let clock = self.clock
        h = Harness(name: "Beacon", brain: brain, log: log, clock: .init(now: { clock.now }), queue: home, options: o, note: note)
    }

    func sync<T>(_ body: () throws -> T) rethrows -> T { try home.sync(execute: body) }

    @discardableResult
    func emit(_ kind: String, _ data: [String: JSONValue] = [:]) -> Event {
        sync { h.emit(source: "ci", kind: kind, data: data) }
    }
}

/// An output with fixed keys that records the answers it gets and returns
/// `result`.
final class ToyOutput: Action, @unchecked Sendable {
    let name: String
    let keys: [String]
    var got: [Answers] = []
    var result: ActionResult?
    init(_ name: String, keys: [String], result: ActionResult?) {
        self.name = name
        self.keys = keys
        self.result = result
    }
    func questions(now: Event?, log: LogView) -> [Question] {
        keys.map { Question(key: $0, text: "?", about: "the NOW section", judgeBy: "x", options: [Option("x", "X"), Option("y", "Y")]) }
    }
    func run(_ answers: Answers, now: Event?, log: LogView) -> ActionResult? {
        got.append(answers)
        return result
    }
}

/// A brain that answers `answers` after `ms`.
struct SlowBrain: Brain {
    let id = "slow"
    let ms: Int
    var answers: Answers = [:]
    func answer(state: String, questions: [Question], deadline: Duration) async throws -> Answers {
        try await Task.sleep(for: .milliseconds(ms))
        return answers
    }
}
