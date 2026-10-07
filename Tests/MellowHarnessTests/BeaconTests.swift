import Beacon
import Foundation
import MellowHarness
import Testing

/// Beacon, MellowHarness's worked example: the worked example's
/// run, pinned, so the docs quote what it does. A port of the harness
/// runs the same timeline and must write the same log and prompts.
/// Serialized: one of its waits blocks.
@Suite(.serialized) struct BeaconTests {
    static let steering = Beacon.steering

    /// The prompt from HISTORY on.
    func tail(_ prompt: String) -> String {
        String(prompt[prompt.range(of: "HISTORY (")!.lowerBound...])
    }

    @Test func testTheWorkedExample() async throws {
        let run = try await Beacon.demo(steering: Self.steering)
        #expect(run.prompts.count == 6, "two failures, a press, the third, a press, the pass")
        #expect(run.log[8...12].joined(separator: "\n") == #"""
            {"seq":9,"at":1791986940000,"source":"ci","kind":"build_failed","data":{"branch":"main","run":814}}
            {"seq":10,"at":1791986940000,"source":"self","kind":"did","data":{"action":"flash","by":"rule","for":9,"message":"Beacon flashed red on its own.","ok":true}}
            {"seq":11,"at":1791986940000,"source":"self","kind":"pass","data":{"answers":{"play":{"choice":"wobble","p":{"wobble":1}},"tone":{"choice":"worried","p":{"worried":1}}},"brain":"scripted","dropped":null,"for":9,"ms":0}}
            {"seq":12,"at":1791986940000,"source":"self","kind":"did","data":{"action":"tone","by":"brain","for":9,"from":"calm","latency_ms":0,"message":"Beacon went from calm to worried.","ok":true,"to":"worried"}}
            {"seq":13,"at":1791986940000,"source":"self","kind":"did","data":{"action":"play","by":"brain","for":9,"latency_ms":0,"message":"Beacon wobbled.","ok":true,"open":true}}
            """#)
        #expect(run.log[15] == #"{"seq":16,"at":1791986948000,"source":"self","kind":"ended","data":{"action":"play","by":"brain","for":13,"outcome":"done"}}"#)

        #expect(tail(run.prompts[3].prompt) == """
            HISTORY (oldest first; indented lines add to the line above)
            8 min ago: The build on main failed.
              Beacon flashed red on its own.
            4 min ago: The build on main failed again, 2 in a row.
              Beacon flashed red on its own.
            3 min ago: You pressed the button.

            NOW (14:09, Wednesday)
            The build on main failed again, 3 in a row.
            Beacon flashed red on its own.
            """)
        #expect(run.prompts[3].prompt.contains("TONE\nCalm."))
        #expect(tail(run.prompts[4].prompt) == """
            HISTORY (oldest first; indented lines add to the line above)
            8 min ago: The build on main failed.
              Beacon flashed red on its own.
            4 min ago: The build on main failed again, 2 in a row.
              Beacon flashed red on its own.
            3 min ago: You pressed the button.
            just now: The build on main failed again, 3 in a row.
              Beacon flashed red on its own.
              Beacon went from calm to worried.
              Beacon wobbled. (in progress)
            Beacon has been worried for under a minute.

            NOW (14:09, Wednesday)
            You pressed the button.
            Beacon did nothing on its own.
            """, "the wobble in progress, so the brain plays nothing")
        #expect(run.prompts[4].prompt.contains("TONE\nWorried."), "the tone's section follows its value")
        #expect(tail(run.prompts[5].prompt) == """
            HISTORY (oldest first; indented lines add to the line above)
            19 min ago: The build on main failed.
              Beacon flashed red on its own.
            15 min ago: The build on main failed again, 2 in a row.
              Beacon flashed red on its own.
            14 min ago: You pressed the button.
            11 min ago: The build on main failed again, 3 in a row.
              Beacon flashed red on its own.
              Beacon went from calm to worried.
              Beacon wobbled.
            10 min ago: You pressed the button.
            Beacon has been worried for 11 min.

            NOW (14:20, Wednesday)
            The build on main passed after 3 failures.
            Beacon flashed green on its own.
            """, "reaching back to the red streak's start")
        #expect(run.log.last!.contains(#""kind":"ended""#) && run.log[20].contains(#""message":"Beacon cheered.""#))
        #expect(run.log[19].contains(#""to":"calm""#), "back to calm")
    }

    /// HISTORY reaches back to the red streak's first failure while
    /// the build is red and when the pass that ends it is NOW; a press a
    /// minute after the pass sees the last 10 minutes again.
    @Test func testReachingBackEndsOnceTheBuildIsGreen() async throws {
        final class Clock: @unchecked Sendable { var now = Beacon.start }
        let clock = Clock()
        let queue = DispatchQueue(label: "beacon.test")
        let beacon = try Beacon(brain: ScriptedBrain { _, _ in [:] }, log: Log(), steering: Self.steering,
                                clock: .init(now: { clock.now }), queue: queue, timeZone: TimeZone(identifier: "UTC")!,
                                loop: false)
        let h = beacon.harness
        func prompt(_ kind: String, atMinute minute: Int64) async -> String {
            clock.now = Beacon.start + minute * 60_000
            let e = queue.sync { h.emit(source: kind == "press" ? "device" : "ci", kind: kind, data: ["branch": "main"]) }
            return await h.respond(to: e)?.prompt ?? ""
        }
        _ = await prompt("build_failed", atMinute: 1)
        #expect(await prompt("build_failed", atMinute: 15).contains("14 min ago: The build on main failed."), "red")
        let passed = await prompt("build_passed", atMinute: 20)
        #expect(passed.contains("19 min ago: The build on main failed."), "its pass is NOW")
        let press = await prompt("press", atMinute: 21)
        #expect(!press.contains("20 min ago: The build on main failed."), "green since")
        #expect(press.contains("6 min ago: The build on main failed again, 2 in a row."))
        #expect(press.contains("1 min ago: The build on main passed after 2 failures."))
    }

    /// Reaching back goes by NOW, not by the log's newest
    /// event. The pass's call, made after a deploy and a press came, still
    /// reaches back to the streak; the press's, after the pass, doesn't.
    @Test func testReachingBackGoesByNow() async throws {
        final class Clock: @unchecked Sendable { var now = Beacon.start }
        let clock = Clock()
        let queue = DispatchQueue(label: "beacon.test")
        let beacon = try Beacon(brain: ScriptedBrain { _, _ in [:] }, log: Log(), steering: Self.steering,
                                clock: .init(now: { clock.now }), queue: queue, timeZone: TimeZone(identifier: "UTC")!,
                                loop: false)
        let h = beacon.harness
        func emit(_ kind: String, atMinute minute: Int64, _ data: [String: JSONValue] = ["branch": "main"]) -> Event {
            clock.now = Beacon.start + minute * 60_000
            return queue.sync { h.emit(source: kind == "press" ? "device" : "ci", kind: kind, data: data) }
        }
        _ = await h.respond(to: emit("build_failed", atMinute: 1))
        _ = await h.respond(to: emit("build_failed", atMinute: 15))
        let passed = emit("build_passed", atMinute: 20)
        _ = emit("deploy", atMinute: 20, ["who": "Ana", "service": "api"])
        let press = emit("press", atMinute: 20)
        let pass = await h.respond(to: passed)?.prompt ?? ""
        #expect(pass.contains("19 min ago: The build on main failed."), "its pass is NOW, though newer events came")
        #expect(!pass.contains("Ana deployed api."), "HISTORY stops before NOW")
        let after = await h.respond(to: press)?.prompt ?? ""
        #expect(after.contains("just now: Ana deployed api."))
        #expect(!after.contains("19 min ago: The build on main failed."), "green before NOW")
        #expect(after.contains("5 min ago: The build on main failed again, 2 in a row."))
    }

    /// In the loop, a pass that comes while another call runs is
    /// answered once that call ends, after a newer deploy, and its prompt
    /// still reaches back to the red streak's first failure.
    @Test func testReachingBackInTheLoop() throws {
        final class Clock: @unchecked Sendable { var now = Beacon.start }
        let clock = Clock()
        let queue = DispatchQueue(label: "beacon.test")
        let beacon = try Beacon(brain: SlowBrain(ms: 200), log: Log(), steering: Self.steering, clock: .init(now: { clock.now }),
                                queue: queue, timeZone: TimeZone(identifier: "UTC")!)
        let h = beacon.harness
        let prompts = Lines()
        queue.sync { h.onPass = { pass in if let line = pass.line, let prompt = pass.prompt { prompts.add(line + "\n" + prompt) } } }
        func emit(_ kind: String, atMinute minute: Int64, _ data: [String: JSONValue] = ["branch": "main"]) {
            clock.now = Beacon.start + minute * 60_000
            queue.sync { _ = h.emit(source: kind == "press" ? "device" : "ci", kind: kind, data: data) }
        }
        emit("build_failed", atMinute: 1)
        eventually("the first failure answered") { queue.sync { h.idle } }
        emit("build_failed", atMinute: 15)
        eventually("the second failure answered") { queue.sync { h.idle } }
        emit("press", atMinute: 20)
        #expect(queue.sync { !h.idle }, "the press's call is running")
        emit("build_passed", atMinute: 20)
        emit("deploy", atMinute: 20, ["who": "Ana", "service": "api"])
        eventually("all answered") { queue.sync { h.idle } && prompts.all.count == 5 }
        let all = prompts.all
        #expect(all.map { $0.prefix { $0 != "\n" } } == [
            "The build on main failed.", "The build on main failed again, 2 in a row.", "You pressed the button.",
            "The build on main passed after 2 failures.", "Ana deployed api.",
        ], "the pass before the newer deploy: its wake is higher")
        #expect(all.count == 5 && all[3].contains("19 min ago: The build on main failed."), "the pass reaches back")
    }

    /// Beacon's file registers a template, and an hour of red
    /// is news of its own, once.
    @Test func testDeploysAndAnHourOfRed() throws {
        final class Clock: @unchecked Sendable { var now = Beacon.start }
        let clock = Clock()
        let queue = DispatchQueue(label: "beacon.test")
        let beacon = try Beacon(brain: nil, log: Log(), steering: Self.steering, clock: .init(now: { clock.now }), queue: queue,
                                timeZone: TimeZone(identifier: "UTC")!)
        let h = beacon.harness
        let deploy = queue.sync { h.emit(source: "ci", kind: "deploy", data: ["who": "Ana", "service": "api"]) }
        #expect(queue.sync { h.line(deploy.seq)?.text } == "Ana deployed api.")
        queue.sync { _ = h.emit(source: "ci", kind: "build_failed", data: ["branch": "main"]) }
        #expect(beacon.light.played.map(\.name) == ["flash"], "the rule flashed, at once")
        clock.now += 3_600_000
        queue.sync { h.tick(); h.tick() }
        let red = queue.sync { h.log.events.filter { $0.kind == "still_red" } }
        #expect(red.count == 1)
        #expect(queue.sync { h.line(red[0].seq)?.text } == "The build has been red for an hour.")
    }
}
