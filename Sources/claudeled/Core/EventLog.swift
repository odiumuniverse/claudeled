// EventLog.swift -- the append-only record of what the hooks saw.
//
// Session files hold only the latest event, because that is all the light needs.
// Statistics need the history, so every hook also appends one line here.
//
// One file per month: rotation for free, "last month" is one file to read, and
// throwing away old data is `rm`. Roughly 4 MB a month on a heavy day-in-day-out
// workload.

import Foundation

var eventsDir: URL { configRoot.appendingPathComponent("events", isDirectory: true) }

struct LoggedEvent: Codable, Equatable {
    let t: Double          // seconds since the epoch
    let s: String          // session id
    let e: SessionEvent
    let p: String          // project: the basename of the session's cwd, never the path

    var at: Date { Date(timeIntervalSince1970: t) }
}

/// `SessionEnd` is deliberately not logged: it is not a `SessionEvent`, and a gap
/// needs two events to exist, so a session that simply stops producing them ends up
/// with an unpaired last event either way.
func logEvent(session: String, event: SessionEvent, project: String, at: Date = Date()) {
    let entry = LoggedEvent(t: at.timeIntervalSince1970, s: session, e: event, p: project)
    guard let line = try? JSONEncoder().encode(entry) else { return }

    try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
    let url = eventsDir.appendingPathComponent(monthFile(for: at))

    // Hooks from several sessions run as separate processes and can land at the same
    // moment. O_APPEND plus a single write() is what keeps their lines from
    // interleaving; JSONEncoder emits no newlines, so one line really is one write.
    // ponytail: fine for lines of this size, would need locking if entries ever grew.
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    var bytes = Array(line)
    bytes.append(UInt8(ascii: "\n"))
    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    close(fd)
}

func monthFile(for date: Date) -> String {
    let parts = Calendar.current.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d.jsonl", parts.year ?? 0, parts.month ?? 0)
}

/// Every event in the window, oldest first. `from` of nil means "no lower bound", which
/// reads every log file rather than computing a span across them.
///
/// Unparseable lines are skipped rather than fatal: a truncated write at the end of a
/// log must not cost you the whole report.
func readEvents(from: Date? = nil, to: Date = Date()) -> [LoggedEvent] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: eventsDir.path)
    else { return [] }

    let wanted = from.map { Set(monthsSpanned(from: $0, to: to)) }
    let decoder = JSONDecoder()
    var events: [LoggedEvent] = []
    for name in names.sorted()
    where name.hasSuffix(".jsonl") && (wanted?.contains(name) ?? true) {
        guard let text = try? String(contentsOf: eventsDir.appendingPathComponent(name),
                                     encoding: .utf8) else { continue }
        for line in text.split(separator: "\n") {
            guard let event = try? decoder.decode(LoggedEvent.self, from: Data(line.utf8)),
                  event.at <= to, from.map({ event.at >= $0 }) ?? true else { continue }
            events.append(event)
        }
    }
    return events.sorted { $0.t < $1.t }
}

func monthsSpanned(from: Date, to: Date) -> [String] {
    let calendar = Calendar.current
    var cursor = calendar.date(from: calendar.dateComponents([.year, .month], from: from)) ?? from
    var names: [String] = []
    while cursor <= to, names.count < 600 {   // 50 years, in case of a bad clock
        names.append(monthFile(for: cursor))
        guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
        cursor = next
    }
    return names
}

/// The hook gives us an absolute cwd. Only the last component is kept: full paths leak
/// client and employer names into anything you share.
func projectName(cwd: String?) -> String {
    let name = (cwd as NSString?)?.lastPathComponent ?? ""
    return name.isEmpty || name == "/" ? "unknown" : String(name.prefix(64))
}
