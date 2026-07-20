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

// MARK: - rendering

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total)s" }
    let minutes = total / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
}

func renderReport(today: Report, week: Report, cap: TimeInterval) -> String {
    var lines: [String] = []

    func summary(_ label: String, _ report: Report) -> String {
        var parts = ["worked \(formatDuration(report.totals.worked))",
                     "waiting on you \(formatDuration(report.totals.waiting))"]
        if report.totals.blocked > 0 {
            parts.append("blocked \(formatDuration(report.totals.blocked))")
        }
        return "\(label.padding(toLength: 11, withPad: " ", startingAt: 0))\(parts.joined(separator: " · "))"
    }

    lines.append(summary("today", today))
    lines.append(summary("this week", week))

    if !week.projects.isEmpty {
        let width = max(7, week.projects.map(\.name.count).max() ?? 7)
        lines.append("")
        lines.append("\("project".padding(toLength: width, withPad: " ", startingAt: 0))  "
                     + "  worked   waiting")
        for project in week.projects {
            lines.append(
                project.name.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  " + formatDuration(project.totals.worked).leftPadded(to: 8)
                + "  " + formatDuration(project.totals.waiting).leftPadded(to: 8))
        }
    }

    lines.append("")
    var footer = "\(week.sessions) session\(week.sessions == 1 ? "" : "s") this week"
    if week.totals.away > 0 {
        footer += " · \(formatDuration(week.totals.away)) skipped as away "
            + "(gaps over \(formatDuration(cap)))"
    }
    lines.append(footer)

    return lines.joined(separator: "\n")
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - the default view

/// Today plus the last seven days, which is what `claudeled stats` prints bare.
func statsText(now: Date = Date(), cap: TimeInterval = Config.load().idleCap) -> String {
    let startOfToday = Calendar.current.startOfDay(for: now)
    let weekAgo = now.addingTimeInterval(-7 * 24 * 3600)

    let week = readEvents(from: weekAgo, to: now)
    guard !week.isEmpty else {
        return "no events logged yet — the log starts filling on your next Claude Code turn"
    }
    let today = week.filter { $0.at >= startOfToday }

    return renderReport(today: summarise(today, cap: cap),
                        week: summarise(week, cap: cap),
                        cap: cap)
}
