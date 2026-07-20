// Stats.swift -- turning the event log into time.
//
// Every pair of consecutive events in a session brackets a gap, and the *earlier*
// event says what was happening during it:
//
//   prompt -> ...   Claude was working (a turn, or a tool running)
//   stop   -> ...   Claude was waiting for you
//   notify -> ...   Claude was blocked on a permission prompt
//
// A gap longer than the idle cap is not counted at all: you went to lunch, or shut
// the lid, and no honest number can tell that apart from thinking hard. Those are
// reported separately rather than silently dropped, because a total that quietly
// discards hours is worse than one that says how many.

import Foundation

struct Totals: Equatable {
    var worked: TimeInterval = 0
    var waiting: TimeInterval = 0
    var blocked: TimeInterval = 0
    var away: TimeInterval = 0

    var counted: TimeInterval { worked + waiting + blocked }
}

struct ProjectTotals: Equatable {
    let name: String
    let totals: Totals
}

struct Report: Equatable {
    var totals = Totals()
    var projects: [ProjectTotals] = []
    var sessions = 0
}

func summarise(_ events: [LoggedEvent], cap: TimeInterval) -> Report {
    var byProject: [String: Totals] = [:]
    var report = Report()

    let bySession = Dictionary(grouping: events, by: \.s)
    report.sessions = bySession.count

    for (_, sessionEvents) in bySession {
        let ordered = sessionEvents.sorted { $0.t < $1.t }
        for (earlier, later) in zip(ordered, ordered.dropFirst()) {
            let gap = later.t - earlier.t
            guard gap > 0 else { continue }
            var totals = byProject[earlier.p] ?? Totals()
            if gap > cap {
                totals.away += gap
            } else {
                switch earlier.e {
                case .prompt: totals.worked += gap
                case .stop:   totals.waiting += gap
                case .notify: totals.blocked += gap
                }
            }
            byProject[earlier.p] = totals
        }
    }

    for (name, totals) in byProject {
        report.totals.worked += totals.worked
        report.totals.waiting += totals.waiting
        report.totals.blocked += totals.blocked
        report.totals.away += totals.away
        report.projects.append(ProjectTotals(name: name, totals: totals))
    }
    // Busiest first, by name when tied, so the order does not wobble between runs.
    report.projects.sort {
        $0.totals.counted == $1.totals.counted
            ? $0.name < $1.name
            : $0.totals.counted > $1.totals.counted
    }
    return report
}

// MARK: - periods
//
// Rolling windows rather than calendar ones: "the last 30 days" is a number you can
// compare with last week's, where "this month" shrinks to nothing every first of the
// month.

enum Period: String, CaseIterable {
    case week, month, year, all

    var label: String {
        switch self {
        case .week:  return "last 7 days"
        case .month: return "last 30 days"
        case .year:  return "last 365 days"
        case .all:   return "all time"
        }
    }

    /// nil means "no lower bound": read every log file there is.
    func start(now: Date) -> Date? {
        switch self {
        case .week:  return now.addingTimeInterval(-7 * 24 * 3600)
        case .month: return now.addingTimeInterval(-30 * 24 * 3600)
        case .year:  return now.addingTimeInterval(-365 * 24 * 3600)
        case .all:   return nil
        }
    }

    func report(now: Date = Date(), cap: TimeInterval) -> Report {
        summarise(readEvents(from: start(now: now), to: now), cap: cap)
    }
}

struct Summary: Equatable {
    let label: String
    let report: Report
}

// MARK: - rendering

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
}

private func footer(_ report: Report, cap: TimeInterval) -> String {
    var text = "\(report.sessions) session\(report.sessions == 1 ? "" : "s")"
    if report.totals.away > 0 {
        text += " · \(formatDuration(report.totals.away)) skipped as away "
            + "(gaps over \(formatDuration(cap)))"
    }
    return text
}

func renderText(_ summaries: [Summary], projects: Report, cap: TimeInterval) -> String {
    var lines: [String] = []
    let labelWidth = (summaries.map(\.label.count).max() ?? 0) + 2

    for summary in summaries {
        var parts = ["worked \(formatDuration(summary.report.totals.worked))",
                     "waiting on you \(formatDuration(summary.report.totals.waiting))"]
        if summary.report.totals.blocked > 0 {
            parts.append("blocked \(formatDuration(summary.report.totals.blocked))")
        }
        lines.append(summary.label.padding(toLength: labelWidth, withPad: " ", startingAt: 0)
                     + parts.joined(separator: " · "))
    }

    if !projects.projects.isEmpty {
        let width = max(7, projects.projects.map(\.name.count).max() ?? 7)
        lines.append("")
        lines.append("project".padding(toLength: width, withPad: " ", startingAt: 0)
                     + "    worked   waiting")
        for project in projects.projects {
            lines.append(
                project.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  " + formatDuration(project.totals.worked).leftPadded(to: 8)
                + "  " + formatDuration(project.totals.waiting).leftPadded(to: 8))
        }
    }

    lines.append("")
    lines.append(footer(projects, cap: cap))
    return lines.joined(separator: "\n")
}

func renderMarkdown(_ report: Report, label: String, cap: TimeInterval) -> String {
    var lines = ["### Claude Code — \(label)", ""]
    lines.append("| | time |")
    lines.append("| --- | ---: |")
    lines.append("| Claude worked | \(formatDuration(report.totals.worked)) |")
    lines.append("| waiting on you | \(formatDuration(report.totals.waiting)) |")
    if report.totals.blocked > 0 {
        lines.append("| blocked on a prompt | \(formatDuration(report.totals.blocked)) |")
    }

    if !report.projects.isEmpty {
        lines.append(contentsOf: ["", "| project | worked | waiting |", "| --- | ---: | ---: |"])
        for project in report.projects {
            lines.append("| \(project.name) | \(formatDuration(project.totals.worked)) "
                         + "| \(formatDuration(project.totals.waiting)) |")
        }
    }

    lines.append(contentsOf: ["", footer(report, cap: cap)])
    return lines.joined(separator: "\n")
}

/// Seconds, as integers: whoever consumes this can format them their own way, and a
/// fractional second of "waiting" helps nobody.
func renderJSON(_ report: Report, period: Period, now: Date, cap: TimeInterval) -> String {
    func totals(_ totals: Totals) -> [String: Int] {
        ["worked": Int(totals.worked.rounded()),
         "waiting": Int(totals.waiting.rounded()),
         "blocked": Int(totals.blocked.rounded()),
         "away": Int(totals.away.rounded())]
    }
    let payload: [String: Any] = [
        "period": period.rawValue,
        "from": period.start(now: now).map { Int($0.timeIntervalSince1970) } as Any,
        "to": Int(now.timeIntervalSince1970),
        "idleCapSeconds": Int(cap),
        "sessions": report.sessions,
        "totals": totals(report.totals),
        "projects": report.projects.map { project -> [String: Any] in
            var entry = totals(project.totals) as [String: Any]
            entry["name"] = project.name
            return entry
        },
    ]
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - the default view

let noEventsYet = "no events logged yet — the log starts filling on your next Claude Code turn"

/// Today plus the last seven days, which is what `claudeled stats` prints bare.
func statsText(now: Date = Date(), cap: TimeInterval = Config.load().idleCap) -> String {
    let week = readEvents(from: now.addingTimeInterval(-7 * 24 * 3600), to: now)
    guard !week.isEmpty else { return noEventsYet }

    let startOfToday = Calendar.current.startOfDay(for: now)
    let weekReport = summarise(week, cap: cap)
    return renderText([Summary(label: "today",
                               report: summarise(week.filter { $0.at >= startOfToday }, cap: cap)),
                       Summary(label: "last 7 days", report: weekReport)],
                      projects: weekReport, cap: cap)
}
