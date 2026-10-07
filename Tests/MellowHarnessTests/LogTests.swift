import Foundation
import Testing
@testable import MellowHarness

/// The log's memory against the plainest reading of
/// it: every event appended, less the ones older than `keepMs` as of the
/// last trim, filtered. The log lets go of aged-out events in batches and
/// finds times by bisection; nothing it answers may differ.
@Suite struct LogTests {
    static let t0: Int64 = 1_790_690_400_000

    /// What the log should answer, worked out the slow way.
    struct Reference {
        var all: [Event] = []
        var gone = 0

        mutating func trim(now: Int64, keepMs: Int64) {
            while gone < all.count, now - all[gone].at > keepMs { gone += 1 }
        }

        var live: ArraySlice<Event> { all[gone...] }
        /// The harness's events of `kind` for the event `seq`; none for an
        /// event that has aged out, even while they haven't.
        func harness(_ kind: String, for seq: Int) -> [Event] {
            guard gone == 0 || seq > all[gone - 1].seq else { return [] }
            return live.filter { $0.source == Event.harness && $0.kind == kind && $0.about == seq }
        }
        var open: Set<Int> {
            Set(live.filter { e in
                e.source == Event.harness && e.kind == Event.did && e["open"]?.bool == true && e["ok"]?.bool != false
                    && harness(Event.ended, for: e.seq).isEmpty
            }.map(\.seq))
        }
    }

    /// A small, fixed stream of numbers, so a failure repeats.
    struct Numbers {
        var state: UInt64
        mutating func next(_ n: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(n))
        }
    }

    /// Events aging out on every append and every tick, thousands of
    /// times over, with `did`s, ends and passes for events that go before
    /// or after them: the events in memory, each kind's, each action's
    /// `did`s, what's open, answered and ended, and a stretch of time, as
    /// filtering everything would give, at every step.
    @Test func testLettingGoInBatchesAnswersAsFilteringEverything() {
        var options = Log.Options()
        options.keepMs = 60_000
        let log = Log(options: options)
        var ref = Reference()
        var numbers = Numbers(state: 7)
        var now = Self.t0
        for i in 0..<6000 {
            now += Int64(numbers.next(1500))
            let recent = ref.live.suffix(20).filter { !$0.fromHarness }.map(\.seq)
            let target = recent.isEmpty ? nil : recent[numbers.next(recent.count)]
            let e: Event
            switch numbers.next(10) {
            case 0...3:
                e = Event(source: "ci", kind: ["build", "press", "deploy"][numbers.next(3)], data: ["n": .int(Int64(i))])
            case 4, 5:
                e = Event.did("did \(i)", for: target, action: ["flash", "tone"][numbers.next(2)], by: "brain",
                              ok: numbers.next(5) > 0, open: numbers.next(2) == 0)
            case 6:
                let dids = ref.live.suffix(30).filter { $0.kind == Event.did && $0["open"]?.bool == true }.map(\.seq)
                e = dids.isEmpty ? Event(source: "ci", kind: "build") : Event.ended(dids[numbers.next(dids.count)], action: "flash", by: "brain")
            case 7:
                e = target.map { Event(source: Event.harness, kind: Event.pass, data: ["for": .int(Int64($0))]) }
                    ?? Event(source: "ci", kind: "press")
            default:
                e = Event(source: "device", kind: "did", data: ["action": "flash", "n": .int(Int64(i))])
            }
            let logged = log.append(e, now: now)
            ref.all.append(logged)
            ref.trim(now: logged.at, keepMs: options.keepMs)
            if i % 7 == 0 {
                now += Int64(numbers.next(3000))
                log.trim(now: now)
                ref.trim(now: now, keepMs: options.keepMs)
            }
            guard i % 13 == 0 || i > 5900 else { continue }
            let view = log.view(now: now)
            #expect(log.events.map(\.seq) == ref.live.map(\.seq))
            #expect(view.events.map(\.seq) == ref.live.map(\.seq))
            #expect(log.openDids == ref.open)
            for kind in ["build", "press", "deploy", Event.did, Event.ended, Event.pass] {
                #expect(view.last(kind)?.seq == ref.live.last { $0.kind == kind }?.seq)
                #expect(view.count(kind) == ref.live.filter { $0.kind == kind }.count)
                let since = ref.live.dropLast(40).last
                #expect(view.all(kind, since: since).map(\.seq) == ref.live.filter { $0.kind == kind && $0.seq > (since?.seq ?? 0) }.map(\.seq))
            }
            for action in ["flash", "tone"] {
                #expect(view.lastDid(action) { $0["ok"]?.bool == true }?.seq
                        == view.last(Event.did) { $0.action == action && $0["ok"]?.bool == true }?.seq)
            }
            // Events that aged out ask as ones that never were.
            let first = ref.all[max(0, ref.gone - 30)].seq
            for seq in first..<(first + 60) {
                #expect(log.dids(for: seq).map(\.seq) == ref.harness(Event.did, for: seq).map(\.seq))
                #expect(log.ended(seq)?.seq == ref.harness(Event.ended, for: seq).first?.seq)
                #expect(log.answered(seq) == !ref.harness(Event.pass, for: seq).isEmpty)
                #expect(view.answered(seq) == log.answered(seq))
            }
            #expect(view.events(after: first + 20).map(\.seq) == ref.live.filter { $0.seq > first + 20 }.map(\.seq))
            let from = now - Int64(numbers.next(70_000))
            let before = ref.all.last!.seq - numbers.next(10)
            #expect(log.events(before: before, from: from).map(\.seq)
                    == ref.live.filter { $0.seq < before && $0.at >= from }.map(\.seq))
            #expect(view.recent(within: now - from).map(\.seq) == ref.live.filter { $0.at >= from }.map(\.seq))
            for kind in ["build", "press", Event.did, "missing"] {
                #expect(view.count(kind, within: now - from) == ref.live.filter { $0.kind == kind && $0.at >= from }.count)
            }
        }
        #expect(log.kept.count < ref.all.count / 4, "the aged-out events were let go")
        #expect(log.kept.count - log.start == ref.live.count)
    }

    /// An older app's lines can go back in time; the log reads them
    /// as written, and a stretch of time holds what filtering finds, the
    /// out-of-order ones included, while the order lasts and after it.
    @Test func testTimesReadBackOutOfOrderAreFoundAsFilteringFinds() throws {
        let dir = tempDir("mellowharness-order")
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = Log.Options()
        options.day = { _ in "2026-09-30" }
        let ats: [Int64] = [100, 200, 150, 300, 250, 400, 500, 600]
        let lines = ats.enumerated().map { i, at in
            Event(seq: i + 1, at: Self.t0 + at, source: "old", kind: "x").jsonLine
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("2026-09-30.jsonl"), atomically: true, encoding: .utf8)
        let log = Log(folder: dir, options: options)
        log.load(now: Self.t0 + 1000)
        #expect(log.events.map(\.at) == ats.map { Self.t0 + $0 }, "as written")
        #expect(log.unsortedFrom == 5)
        for later in [700, 800] { log.append(Event(source: "ci", kind: "y"), now: Self.t0 + Int64(later)) }
        for from in stride(from: Int64(0), through: 900, by: 25) {
            for before in 1...11 {
                #expect(log.events(before: before, from: Self.t0 + from).map(\.seq)
                        == log.events.filter { $0.seq < before && $0.at >= Self.t0 + from }.map(\.seq))
                // Public time-window queries include all matching
                // timestamps, even before a later line's clock steps back.
                let view = LogView(log: log, upTo: before, now: Self.t0 + 1000)
                let expected = log.events.filter { $0.seq < before && $0.at >= Self.t0 + from }
                #expect(view.recent(within: 1000 - from).map(\.seq) == expected.map(\.seq))
                for kind in ["x", "y", "missing"] {
                    #expect(view.count(kind, within: 1000 - from) == expected.filter { $0.kind == kind }.count)
                }
            }
        }
    }

    /// An hour of an older app's lines, stepping back a few
    /// milliseconds now and then up to its newest, as main's did (a hook
    /// timed as it came, a tick as it ran), then a live hour that lets them
    /// go in batches. Every stretch of time holds what filtering finds, and
    /// only the lines out of order inside it are filtered one by one, not
    /// everything before the newest step back.
    @Test func testStepsBackUpToTheNewestLineOnlyCostTheirOwnStretch() throws {
        let dir = tempDir("mellowharness-steps")
        defer { try? FileManager.default.removeItem(at: dir) }
        var options = Log.Options()
        options.day = { _ in "2026-09-30" }
        options.keepMs = 3_600_000
        var numbers = Numbers(state: 11)
        var at = Self.t0, last = Self.t0
        var lines: [String] = []
        for seq in 1...4000 {
            at += Int64(numbers.next(1800))
            last = seq % 97 == 0 || seq == 3999 ? last - Int64(1 + numbers.next(20)) : max(at, last)
            lines.append(Event(seq: seq, at: last, source: "old", kind: "x").jsonLine)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("2026-09-30.jsonl"), atomically: true, encoding: .utf8)
        let log = Log(folder: dir, options: options)
        var now = at + 1000
        log.load(now: now)
        #expect(log.unsortedFrom == 3999)
        for i in 0..<4000 {
            if i % 250 == 0 {
                for back in [Int64(0), 700, 60_000, 600_000, 3_000_000] {
                    let from = now - back
                    for before in [log.lastSeq + 1, log.lastSeq - 3] {
                        #expect(log.events(before: before, from: from).map(\.seq)
                                == log.events.filter { $0.seq < before && $0.at >= from }.map(\.seq))
                    }
                    let (scan, _) = log.window(from: from, end: log.kept.count)
                    #expect(log.kept[scan].filter { $0.at < from }.count <= 1, "filtered one by one: only lines out of order")
                }
                #expect(log.maxAt.count == log.kept.count)
            }
            now += Int64(numbers.next(2000))
            log.append(Event(source: "ci", kind: "y"), now: now)
        }
        #expect(log.events.allSatisfy { $0.source == "ci" }, "the older app's lines aged out")
        #expect(log.kept.count < 6000, "and were let go in batches")
    }
}
