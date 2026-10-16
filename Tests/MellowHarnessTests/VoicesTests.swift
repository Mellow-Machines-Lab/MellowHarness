import Foundation
import Testing
@testable import MellowHarness

/// Voices: several characters from one log. Each answers an event in a
/// pass of its own, in turn, asked only its own outputs' questions and
/// those of no voice, and sees what the ones before it did. Serialized:
/// its waits block.
@Suite(.serialized) final class VoicesTests {
    static let light = Harness.Voice(id: "light", name: "Light")
    static let fan = Harness.Voice(id: "fan", name: "Fan")

    /// A rig with Light and Fan, each with its own `mood` (the same name
    /// and key), a `blink` of no voice, and a section that says whose
    /// prompt it is. Its brain notes each prompt's first line and the keys
    /// it was asked, and makes Light glad and Fan grumpy.
    final class Two {
        let rig: Rig
        let asked: Lines
        let prompts: Lines
        var light: Choice!, fan: Choice!
        let blink = ToyOutput("blink", keys: ["blink"], result: .done("The lamp blinked."))

        init(options: Harness.Options = Harness.Options(), log: Log = Log(), brain: Bool = true) {
            let asked = Lines(), prompts = Lines()
            self.asked = asked
            self.prompts = prompts
            rig = Rig(brain: brain ? ScriptedBrain { state, questions in
                prompts.add(state)
                asked.add(String(state.prefix { $0 != "\n" }) + ": " + questions.map(\.key).joined(separator: " "))
                let pick = state.hasPrefix("YOU ARE LIGHT") ? "glad" : "grumpy"
                return Dictionary(uniqueKeysWithValues: questions.map { ($0.key, Answer(choice: $0.key == "mood" ? pick : "x")) })
            } : nil, options: options, log: log)
            rig.h.voice(VoicesTests.light)
            rig.h.voice(VoicesTests.fan)
            rig.h.section { _, voice in "YOU ARE \(voice?.name.uppercased() ?? "NOBODY")" }
            rig.h.input("press", wake: 0) { _, _ in "You pressed the button." }
            light = mood(VoicesTests.light)
            fan = mood(VoicesTests.fan)
            rig.h.output(light)
            rig.h.output(fan)
            rig.h.output(blink)
        }

        func mood(_ voice: Harness.Voice) -> Choice {
            Choice(name: "mood", start: "calm", voice: voice.id, question: "How does \(voice.name) feel?", judgeBy: "x",
                   said: { _, to in "\(voice.name) felt \(to)." },
                   options: { _, _, _ in [Option("calm", "Calm."), Option("glad", "Glad."), Option("grumpy", "Grumpy.")] })
        }

        func passes() -> [Event] { rig.sync { rig.h.log.events.filter { $0.kind == Event.pass } } }
        func value(_ choice: Choice) -> String { rig.sync { choice.value(rig.h.log.view(now: rig.clock.now)) } }
    }

    /// Two voices answer one event in the order registered, one pass
    /// each, each asked its own `mood` and the `blink` of no voice. The
    /// second sees under NOW what the first did; the harness's own words
    /// use its name. The pass carries the voice, and a `did` its output's
    /// voice, none for an output of none. Each `mood` keeps its own value.
    @Test func testTwoVoicesAnswerOneEventInTurn() {
        let two = Two()
        var passes: [Harness.Pass] = []
        two.rig.h.onPass = { passes.append($0) }
        let press = two.rig.emit("press")
        eventually("both passes") { two.rig.sync { two.rig.h.idle } && two.passes().count == 2 }
        #expect(two.passes().map { $0["voice"]?.string } == ["light", "fan"])
        #expect(passes.map(\.voice) == ["light", "fan"])
        #expect(two.asked.all == ["YOU ARE LIGHT: mood blink", "YOU ARE FAN: mood blink"])
        #expect(two.prompts.all.first?.hasSuffix("You pressed the button.\nLight did nothing on its own.") == true)
        #expect(two.prompts.all.last == """
            YOU ARE FAN

            How to read HISTORY and NOW:
            - HISTORY is oldest first. Each line says how long ago it happened.
              Lines indented under it add to it: its notes, then what Fan and
              the others did. A line of what was done ending in (in progress)
              hasn't finished yet.
            - NOW is what to react to. Lines indented under it are its notes,
              then what the others already did about it. Its last line is what
              Fan already did on its own, by reflex.

            HISTORY (oldest first; indented lines add to the line above)

            NOW (14:09, Wednesday)
            You pressed the button.
              Light felt glad.
              The lamp blinked.
            Fan did nothing on its own.
            """)
        let dids = two.rig.sync { two.rig.h.log.dids(for: press.seq) }
        #expect(dids.map { "\($0.action!) \($0["voice"]?.string ?? "-")" } == ["mood light", "blink -", "mood fan", "blink -"])
        #expect(two.value(two.light) == "glad")
        #expect(two.value(two.fan) == "grumpy")
        #expect(two.rig.sync { two.rig.h.outputs(for: "fan").map(\.name) } == ["mood", "blink"])
        #expect(two.rig.sync { two.rig.h.outputs(for: nil).map(\.name) } == ["blink"])
    }

    /// A voice's NOW lists as its reflexes only the rules' `did`s with no
    /// voice or with its own: Light's reflex isn't Fan's.
    @Test func testEachVoiceHasItsOwnReflexes() {
        let two = Two()
        two.rig.h.on("press") { e in
            two.rig.h.did("The lamp flickered on its own.", for: e, action: "flicker", facts: ["voice": "light"])
        }
        two.rig.emit("press")
        eventually("both passes") { two.rig.sync { two.rig.h.idle } && two.passes().count == 2 }
        #expect(two.prompts.all.first?.hasSuffix("You pressed the button.\nThe lamp flickered on its own.") == true)
        #expect(two.prompts.all.last?.hasSuffix("Fan did nothing on its own.") == true)
    }

    /// With no voices, nothing changes: the pass and the `did` carry no
    /// voice, and the event is answered for none.
    @Test func testNoVoicesCarryNoVoice() {
        let rig = Rig(brain: ScriptedBrain(always: [:]))
        rig.h.output(ToyOutput("a", keys: ["a"], result: .done("Beacon did a.")))
        rig.h.input("go", wake: 0) { _, _ in "Go." }
        let go = rig.emit("go")
        eventually("the pass") { rig.sync { rig.h.log.answered(go.seq) } }
        let pass = rig.sync { rig.h.log.events.last { $0.kind == Event.pass } }
        #expect(pass.map { Set($0.data.keys) } == ["for", "brain", "answers", "dropped", "ms"])
        #expect(rig.sync { rig.h.log.dids(for: go.seq).first?["voice"] } == nil)
    }

    /// `speakers` says who answers and in what order; an id that isn't a
    /// voice is left out, and an empty list leaves the event unanswered.
    @Test func testSpeakersPickWhoAnswersAndInWhatOrder() {
        let two = Two()
        two.rig.h.input("quiet", wake: 1) { _, _ in "Something quiet happened." }
        two.rig.h.speakers { e, _ in e.kind == "quiet" ? [] : ["fan", "nobody", "light"] }
        let press = two.rig.emit("press")
        eventually("both passes") { two.rig.sync { two.rig.h.idle } && two.passes().count == 2 }
        #expect(two.passes().map { $0["voice"]?.string } == ["fan", "light"])
        #expect(two.asked.all.map { $0.prefix { $0 != ":" } } == ["YOU ARE FAN", "YOU ARE LIGHT"])
        #expect(two.rig.sync { two.rig.h.log.answered(press.seq, voice: "fan") && two.rig.h.log.answered(press.seq, voice: "light") })
        #expect(!two.rig.sync { two.rig.h.log.answered(press.seq) }, "for no voice, it never is")
        let quiet = two.rig.emit("quiet")
        #expect(two.rig.sync { two.rig.h.idle })
        #expect(two.passes().count == 2)
        #expect(!two.rig.sync { two.rig.h.log.answered(quiet.seq, voice: "light") })
    }

    /// A hold that knows the voice holds one back and not the other.
    @Test func testAVoiceCanBeHeld() {
        let two = Two()
        two.rig.h.hold("press") { _, _, voice in voice?.id == "light" ? "Light is asleep" : nil }
        two.rig.emit("press")
        eventually("both passes") { two.rig.sync { two.rig.h.idle } && two.passes().count == 2 }
        #expect(two.passes().map { $0["held"]?.string } == ["Light is asleep", nil])
        #expect(two.asked.all == ["YOU ARE FAN: mood blink"])
    }

    /// One call at a time, and an event's voices answer it in turn; what
    /// goes next is still the highest wake, and a wake-0 event with a
    /// newer one behind it is passed over for its remaining voices too.
    @Test func testVoicesTakeTurnsInTheLoop() {
        let gate = DispatchSemaphore(value: 0)
        let asked = Lines()
        let rig = Rig(brain: ScriptedBrain { state, _ in
            let lines = state.split(separator: "\n")
            let now = lines.firstIndex { $0.hasPrefix("NOW (") }!
            asked.add("\(lines[0]): \(lines[now + 1])")
            gate.wait()
            return [:]
        })
        rig.h.voice(Self.light)
        rig.h.voice(Self.fan)
        rig.h.section { _, voice in voice!.name }
        for (kind, wake) in [("routine", 0), ("finish", 1)] {
            rig.h.input(kind, wake: wake) { e, _ in "\(kind) \(e["n"]!.int!)" }
        }
        rig.emit("routine", ["n": 1])
        eventually("the first call") { asked.all == ["Light: routine 1"] }
        rig.emit("finish", ["n": 2])
        for _ in 0..<3 { gate.signal() }
        eventually("the rest") { rig.sync { rig.h.idle } }
        #expect(asked.all == ["Light: routine 1", "Light: finish 2", "Fan: finish 2"], "\(asked.all)")
    }

    /// A forced pass with a voice runs that voice's outputs and those of
    /// no voice, and carries the voice; with none, only those of no voice
    /// run. One output forced alone, and a restore, carry its voice.
    @Test func testForcedPassesAndChoicesByVoice() {
        let two = Two(brain: false)
        let ran = two.rig.sync { two.rig.h.force(["mood": "glad", "blink": "x"], by: "dashboard", voice: "fan") }
        #expect(ran.map(\.name) == ["mood", "blink"])
        #expect(two.passes().last?["voice"] == "fan")
        #expect(two.value(two.fan) == "glad")
        #expect(two.value(two.light) == "calm")
        #expect(two.rig.sync { two.rig.h.force(["mood": "grumpy", "blink": "x"], by: "dashboard") }.map(\.name) == ["blink"])
        #expect(two.passes().last?["voice"] == nil)
        let set = two.rig.sync {
            two.rig.h.force(two.light, by: "dashboard") { two.light.set("grumpy", log: two.rig.h.log.view(now: two.rig.clock.now)) }
        }
        #expect(set?.ok == true)
        #expect(two.rig.sync { two.rig.h.log.events.last?["voice"] } == "light")
        #expect(two.value(two.light) == "grumpy")
        #expect(two.value(two.fan) == "glad", "the same name, its own value")
        let restored = two.rig.sync { two.fan.restore("calm", by: "upgrade", in: two.rig.h) }
        #expect(restored?["voice"] == "fan")
        #expect(two.value(two.fan) == "calm")
        let none = Choice(name: "mood", start: "calm", question: "?", judgeBy: "?", options: { _, _, _ in [] })
        #expect(two.rig.sync { none.value(two.rig.h.log.view(now: two.rig.clock.now)) } == "calm", "one of no voice reads none of theirs")
    }

    /// The one-event call takes a voice: its pass is that voice's.
    @Test func testOneEventStraightThroughForAVoice() async {
        var options = Harness.Options()
        options.loop = false
        let two = Two(options: options)
        let press = two.rig.emit("press")
        let pass = await two.rig.h.respond(to: press, voice: "fan")
        #expect(pass?.voice == "fan")
        #expect(pass?.questions.map(\.key) == ["mood", "blink"])
        #expect(pass?.prompt?.hasPrefix("YOU ARE FAN") == true)
        #expect(two.rig.sync { two.rig.h.log.answered(press.seq, voice: "fan") && !two.rig.h.log.answered(press.seq, voice: "light") })
        #expect(two.rig.sync { two.rig.h.prompt(for: press, voice: "light") }.hasPrefix("YOU ARE LIGHT"))
    }

    /// A relaunch reads back which voices answered each event, and each
    /// voice's value.
    @Test func testARelaunchReadsBackEachVoice() {
        let dir = tempDir("mellowharness-voices")
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = Two(log: Log(folder: dir))
        let press = first.rig.emit("press")
        eventually("both passes") { first.rig.sync { first.rig.h.idle } && first.passes().count == 2 }
        let again = Two(log: Log(folder: dir), brain: false)
        again.rig.clock.now = first.rig.clock.now
        again.rig.sync { _ = again.rig.h.resume() }
        #expect(again.rig.sync { again.rig.h.log.answered(press.seq, voice: "light") && again.rig.h.log.answered(press.seq, voice: "fan") })
        #expect(!again.rig.sync { again.rig.h.log.answered(press.seq) })
        #expect(again.value(again.light) == "glad")
        #expect(again.value(again.fan) == "grumpy")
    }
}
