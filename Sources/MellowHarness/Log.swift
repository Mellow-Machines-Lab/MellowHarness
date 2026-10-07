import Foundation

/// The log: every event, in order, append-only, the only
/// state the harness keeps. With a folder, each event is written as it's
/// appended to `<folder>/<day>.jsonl`, one file a day, and a launch reads
/// the files back; the last `keepMs` of events are kept in memory,
/// indexed for looking back. Without one (tests) it's in memory only.
/// Touched only on the harness's queue.
public final class Log: @unchecked Sendable {
    public struct Options: Sendable {
        /// Days of files kept, today included; older ones are deleted at
        /// launch and on the first event of each new day.
        public var keptDays = 14
        /// How far back events are kept in memory.
        public var keepMs: Int64 = 24 * 60 * 60 * 1000
        /// The day an event's file is named for: `yyyy-MM-dd`, in the
        /// local time zone by default.
        public var day: @Sendable (Int64) -> String = Log.localDay
        /// Reads a line that isn't the log's own shape, such as an older
        /// app's; nil skips it.
        public var decode: (@Sendable (Substring) -> Event?)?

        public init() {}
    }

    public let folder: URL?
    public let options: Options
    let note: (String) -> Void

    /// The events in memory, oldest first: the last `keepMs` of them.
    public var events: ArraySlice<Event> { kept[start...] }
    /// The events kept, oldest first: those before `start` have aged out,
    /// and are let go in batches (`trim`), so an event aging out costs
    /// nothing in the common case.
    var kept: [Event] = []
    var start = 0
    /// The newest aged-out event's `seq`, or 0: the indexes below may still
    /// name it or older ones, which they leave out.
    var goneTo = 0
    /// The newest event whose `at` is before that of the one kept just
    /// before it, or 0 for none: only a line read back from an older app's
    /// file can be. From it on, `at` never goes down, so a time is found
    /// by bisection.
    var unsortedFrom = 0
    /// The latest `at` so far at each place in `kept`. It never goes down,
    /// so before `unsortedFrom` too, where it reaches a time is found by
    /// bisection: no event before that place is as late.
    var maxAt: [Int64] = []
    /// The newest event's `seq`, or 0 before the first.
    public private(set) var lastSeq = 0
    /// The newest event's `at`, and its day, which the next can't go before.
    var lastAt: Int64 = 0
    var lastDay: String?
    /// Each kind's events, by `seq`, oldest first.
    var byKind: [String: [Int]] = [:]
    /// The harness's own events by what they're `for`: `did`s by their
    /// event, `ended` by its `did`, and which events have a `pass`.
    var didsFor: [Int: [Int]] = [:]
    var endedFor: [Int: Int] = [:]
    var passFor: [Int: Int] = [:]
    /// The `did`s by their output or rule (`action`), by `seq`, oldest first.
    var didsBy: [String: [Int]] = [:]
    /// The `did`s still open: `open`, with no `ended` yet.
    public private(set) var openDids: Set<Int> = []

    public init(folder: URL? = nil, options: Options = Options(), note: @escaping (String) -> Void = { _ in }) {
        self.folder = folder
        self.options = options
        self.note = note
    }

    /// `yyyy-MM-dd` in the local time zone.
    public static let localDay: @Sendable (Int64) -> String = { ms in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    /// The file for the day of `at`.
    public func file(for at: Int64) -> URL? {
        folder?.appendingPathComponent(options.day(at) + ".jsonl")
    }

    /// Logs an event: the next `seq`, and `now` as its `at` if it has none.
    /// An `at` never goes back past the last event's, so `seq` and `at`
    /// keep the same order in the files and in memory, nor on past `now`,
    /// so one emitter's clock can't carry the rest into the future.
    @discardableResult
    public func append(_ event: Event, now: Int64) -> Event {
        var e = event
        lastSeq += 1
        e.seq = lastSeq
        e.at = max(lastAt, min(e.at == 0 ? now : e.at, max(now, lastAt)))
        lastAt = e.at
        if folder != nil {
            let day = options.day(e.at)
            if let last = lastDay, day != last { prune(now: e.at) }
            lastDay = day
            if let url = file(for: e.at) { LineFile.append(e.jsonLine, to: url) }
        }
        keep(e)
        trim(now: e.at)
        return e
    }

    /// Keeps `e` in memory, indexed.
    func keep(_ e: Event) {
        if let before = kept.last, e.at < before.at { unsortedFrom = e.seq }
        kept.append(e)
        maxAt.append(max(maxAt.last ?? e.at, e.at))
        byKind[e.kind, default: []].append(e.seq)
        if e.kind == Event.did, let action = e.action { didsBy[action, default: []].append(e.seq) }
        if e.kind == Event.did, e.source == Event.harness, e["open"]?.bool == true, e["ok"]?.bool != false { openDids.insert(e.seq) }
        guard e.source == Event.harness, let about = e.about else { return }
        switch e.kind {
        case Event.did:
            didsFor[about, default: []].append(e.seq)
        case Event.ended:
            if endedFor[about] == nil { endedFor[about] = e.seq }
            openDids.remove(about)
        case Event.pass:
            if passFor[about] == nil { passFor[about] = e.seq }
        default:
            break
        }
    }

    /// Lets go of the events older than `keepMs` as of `now`, so what's in
    /// view is what a launch at `now` would read back: on each append, and
    /// on the harness's tick. They're out of view at once; their memory
    /// and their entries in the indexes go once they're an eighth of what's
    /// kept, so each event's share of the work stays small however long
    /// the app runs.
    public func trim(now: Int64) {
        var cut = start
        while cut < kept.count, now - kept[cut].at > options.keepMs { cut += 1 }
        guard cut > start else { return }
        start = cut
        goneTo = kept[cut - 1].seq
        openDids = openDids.filter { $0 > goneTo }
        if start >= Log.batch, start * 8 >= kept.count { compact() }
    }

    /// Fewer aged-out events than this aren't worth letting go of yet.
    static let batch = 1024

    /// Lets go of the aged-out events and their entries in the indexes.
    func compact() {
        kept.removeFirst(start)
        maxAt.removeFirst(start)
        start = 0
        let gone = goneTo
        for (kind, seqs) in byKind {
            let left = seqs.drop { $0 <= gone }
            byKind[kind] = left.isEmpty ? nil : Array(left)
        }
        for (action, seqs) in didsBy {
            let left = seqs.drop { $0 <= gone }
            didsBy[action] = left.isEmpty ? nil : Array(left)
        }
        didsFor = didsFor.filter { $0.key > gone }
        endedFor = endedFor.filter { $0.key > gone }
        passFor = passFor.filter { $0.key > gone }
    }

    /// The days that have a file, oldest first.
    func days() -> [String] {
        guard let folder else { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(".jsonl".count)) }.sorted()
    }

    /// Deletes the files older than `keptDays` as of `now`: at launch, and
    /// on the first event of each new day.
    public func prune(now: Int64) {
        guard let folder else { return }
        let oldest = options.day(now - Int64(options.keptDays - 1) * 24 * 3_600_000)
        for day in days() where day < oldest {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(day + ".jsonl"))
            note("log: deleted \(day).jsonl, older than \(options.keptDays) days")
        }
    }

    /// Reads the files back as of `now`, then prunes: the events of the
    /// last `keepMs` into memory, in order, and `seq` on from the newest
    /// file's last event, even when that file is about to go. Returns the
    /// events read into memory. A line that doesn't parse, such as one a
    /// crash cut short, is skipped, even when the cut is inside a character.
    @discardableResult
    public func load(now: Int64) -> ArraySlice<Event> {
        guard let folder else { return events }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            prune(now: now)
            lastDay = options.day(max(lastAt, now))
        }
        let days = days()
        let from = now - options.keepMs
        let oldestRead = options.day(from)
        let first = kept.count
        for day in days {
            let name = day + ".jsonl"
            // An older file is read only if it's the newest, for `seq`.
            let url = folder.appendingPathComponent(name)
            guard day >= oldestRead || day == days.last, let data = try? Data(contentsOf: url) else { continue }
            // Decoded leniently: a torn character spoils only its own line.
            let text = String(decoding: data, as: UTF8.self)
            // A line a crash cut short is ended, so the next one written
            // isn't glued to it and lost with it.
            if !text.isEmpty, !text.hasSuffix("\n") { LineFile.append("", to: url) }
            var skipped = 0
            for line in text.split(separator: "\n") {
                // What each line's parse leaves is let go at once: a launch
                // reads thousands, before any run loop drains a pool.
                autoreleasepool {
                    guard let e = Event(jsonLine: line) ?? options.decode?(line) else { skipped += 1; return }
                    lastSeq = max(lastSeq, e.seq)
                    lastAt = max(lastAt, e.at)
                    guard e.at >= from, e.seq > (kept.last?.seq ?? 0) else { return }
                    keep(e)
                }
            }
            if skipped > 0 { note("log: skipped \(skipped) unreadable line(s) in \(name)") }
        }
        return kept[first...]
    }

    // MARK: Looking back

    /// Everything so far, at `now`.
    public func view(now: Int64) -> LogView { LogView(log: self, upTo: Int.max, now: now) }

    /// Everything before `e`, at its time: a transform's view.
    public func view(before e: Event) -> LogView { LogView(log: self, upTo: e.seq, now: e.at) }

    /// Where the event with `seq` is in `kept`, if it's in memory.
    func index(of seq: Int) -> Int? {
        var lo = start, hi = kept.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = kept[mid].seq
            if s == seq { return mid }
            if s < seq { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// The first index in `kept`, from `start`, whose event's `seq` is over
    /// `seq`.
    func index(after seq: Int) -> Int {
        var lo = start, hi = kept.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if kept[mid].seq <= seq { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// The events before `seq` at or after `from`, oldest first: as
    /// filtering every event in memory, but found by bisection (`window`).
    func events(before seq: Int, from: Int64) -> [Event] {
        let (scan, sorted) = window(from: from, end: index(after: seq - 1))
        return kept[scan].filter { $0.at >= from } + kept[sorted]
    }

    /// Where in `kept`, before `end`, the events at or after `from` are:
    /// every one in `sorted`, from `unsortedFrom` on, where `at` is in
    /// order; and, before it, some in `scan`, which starts where `maxAt`
    /// reaches `from`, so only the lines out of order inside the window
    /// are filtered out one by one.
    func window(from: Int64, end: Int) -> (scan: Range<Int>, sorted: Range<Int>) {
        let unsorted = min(max(start, index(after: unsortedFrom - 1)), end)
        let scan = Log.bisect(start..<unsorted) { maxAt[$0] >= from }
        return (scan..<unsorted, Log.bisect(unsorted..<end) { kept[$0].at >= from }..<end)
    }

    /// The first index in `range` where `over`, which stays true once it
    /// is, is true; the range's end if none.
    static func bisect(_ range: Range<Int>, _ over: (Int) -> Bool) -> Int {
        var lo = range.lowerBound, hi = range.upperBound
        while lo < hi {
            let mid = (lo + hi) / 2
            if over(mid) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    public func event(_ seq: Int) -> Event? { index(of: seq).map { kept[$0] } }

    /// The `did`s for the event `seq`, in order.
    public func dids(for seq: Int) -> [Event] { seq > goneTo ? (didsFor[seq] ?? []).compactMap(event) : [] }

    /// How the `did` `seq` ended, or nil while it hasn't.
    public func ended(_ did: Int) -> Event? { did > goneTo ? endedFor[did].flatMap(event) : nil }

    /// Whether the event `seq` has a `pass`.
    public func answered(_ seq: Int) -> Bool { seq > goneTo && passFor[seq] != nil }

    /// Where `seqs`, in order, start being in memory and stop being before
    /// `upTo`.
    func inView(_ seqs: [Int], upTo: Int) -> Range<Int> {
        func first(_ over: (Int) -> Bool) -> Int {
            var lo = 0, hi = seqs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if over(seqs[mid]) { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let gone = goneTo
        let from = first { $0 > gone }
        return from..<max(from, first { $0 >= upTo })
    }
}

/// A read-only view of the log: everything so far,
/// or, for a transform, everything before its event.
public struct LogView {
    let log: Log
    /// Events at or after this `seq` aren't in view.
    public let upTo: Int
    /// The event's `at`, or the clock.
    public let now: Int64

    /// The events in view, oldest first.
    public var events: ArraySlice<Event> { log.kept[log.start..<log.index(after: upTo - 1)] }

    public func event(_ seq: Int) -> Event? { seq < upTo ? log.event(seq) : nil }

    /// Every event after `seq`, of any kind, oldest first.
    public func events(after seq: Int) -> ArraySlice<Event> {
        let end = log.index(after: upTo - 1)
        return log.kept[min(log.index(after: seq), end)..<end]
    }

    /// Every event at or after `now - ms`, oldest first.
    public func recent(within ms: Int64) -> ArraySlice<Event> {
        let from = now - ms
        let (scan, sorted) = log.window(from: from, end: log.index(after: upTo - 1))
        guard !scan.isEmpty else { return log.kept[sorted] }
        return ArraySlice(log.kept[scan].filter { $0.at >= from } + log.kept[sorted])
    }

    /// The `seq`s of `kind`'s events in view, oldest first.
    func seqs(_ kind: String) -> ArraySlice<Int> {
        let all = log.byKind[kind] ?? []
        return all[log.inView(all, upTo: upTo)]
    }

    /// The newest event of `kind` in view that matches.
    public func last(_ kind: String, where match: ((Event) -> Bool)? = nil) -> Event? {
        for seq in seqs(kind).reversed() {
            guard let e = log.event(seq) else { continue }
            if match?(e) ?? true { return e }
        }
        return nil
    }

    /// The newest `did` of the output or rule `action` in view that
    /// matches: `last(Event.did)` for one action, without looking through
    /// the others'.
    public func lastDid(_ action: String, where match: ((Event) -> Bool)? = nil) -> Event? {
        let all = log.didsBy[action] ?? []
        for seq in all[log.inView(all, upTo: upTo)].reversed() {
            guard let e = log.event(seq) else { continue }
            if match?(e) ?? true { return e }
        }
        return nil
    }

    /// Every event of `kind` in view after `since` (everything, for nil)
    /// that matches, oldest first.
    public func all(_ kind: String, since: Event? = nil, where match: ((Event) -> Bool)? = nil) -> [Event] {
        let seqs = seqs(kind)
        let after = since?.seq ?? 0
        var lo = seqs.startIndex, hi = seqs.endIndex
        while lo < hi {
            let mid = (lo + hi) / 2
            if seqs[mid] <= after { lo = mid + 1 } else { hi = mid }
        }
        return seqs[lo...].compactMap(log.event).filter { match?($0) ?? true }
    }

    public func count(_ kind: String, since: Event? = nil, where match: ((Event) -> Bool)? = nil) -> Int {
        guard since != nil || match != nil else { return seqs(kind).count }
        return all(kind, since: since, where: match).count
    }

    /// How many of `kind` in view came at or after `now - ms`.
    public func count(_ kind: String, within ms: Int64) -> Int {
        let from = now - ms
        let (scan, sorted) = log.window(from: from, end: log.index(after: upTo - 1))
        let all = seqs(kind)
        // Locate each stretch in the kind's index too: a long, ordered
        // window costs bisection, not a lookup for every recent event.
        func position(_ index: Int) -> Int {
            guard index < log.kept.count else { return all.endIndex }
            return Log.bisect(all.startIndex..<all.endIndex) { all[$0] >= log.kept[index].seq }
        }
        let unordered = all[position(scan.lowerBound)..<position(scan.upperBound)]
        return unordered.filter { log.event($0).map { $0.at >= from } ?? false }.count
            + position(sorted.upperBound) - position(sorted.lowerBound)
    }

    /// The `did`s for the event `seq` in view, in order.
    public func dids(for seq: Int) -> [Event] { log.dids(for: seq).filter { $0.seq < upTo } }

    /// How the `did` `seq` ended, if it has in view.
    public func ended(_ did: Int) -> Event? { log.ended(did).flatMap { $0.seq < upTo ? $0 : nil } }

    /// How HISTORY shows the `did` `d`: its message, and whether
    /// it's still in progress (open, with no end in view); nil for one it
    /// leaves out, which failed or ended failed.
    public func shown(_ d: Event) -> (message: String, inProgress: Bool)? {
        guard d["ok"]?.bool == true, let message = d["message"]?.string else { return nil }
        guard d["open"]?.bool == true else { return (message, false) }
        guard let end = ended(d.seq) else { return (message, true) }
        return end["outcome"]?.string == "done" ? (message, false) : nil
    }

    /// Whether the event `seq` has a `pass` in view.
    public func answered(_ seq: Int) -> Bool { seq > log.goneTo && (log.passFor[seq].map { $0 < upTo } ?? false) }
}
