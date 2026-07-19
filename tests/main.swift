// tests.swift -- assert-based checks over Core.swift. No framework, no fixtures.
//   swiftc -O Core.swift tests.swift -o build/tests && ./build/tests

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ what: String,
           file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if condition {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)   (\(file):\(line))")
    }
}

func equal<T: Equatable>(_ got: T, _ want: T, _ what: String,
                         file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if got == want {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)")
        print("       got:  \(got)")
        print("       want: \(want)   (\(file):\(line))")
    }
}

func section(_ name: String) { print("\n\(name)") }

// Work in a scratch directory: never touch the user's real config.
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("claudeled-tests-\(getpid())")
configRoot = scratch
ensureDirs()
defer { try? FileManager.default.removeItem(at: scratch) }

// MARK: - keyboard selection
//
// "Empty means all" is the tricky part: the menu shows ticks, the config stores a list,
// and the two disagree about what "everything" looks like.

section("selection")

let both = ["Internal", "Magic"]

equal(Selection.toggle("Magic", current: [], drivable: both), ["Internal"],
      "unticking one of two, starting from 'all', leaves the other")

equal(Selection.toggle("Magic", current: ["Internal"], drivable: both), [],
      "ticking the second collapses back to 'all'")

equal(Selection.toggle("Internal", current: ["Internal"], drivable: both), ["Internal"],
      "unticking the last selected keyboard is refused, the light must stay drivable")

equal(Selection.toggle("Internal", current: [], drivable: ["Internal"]), [],
      "with a single keyboard attached, unticking it is refused")

equal(Selection.toggle("MX Keys", current: [], drivable: both), [],
      "toggling a keyboard that is not attached changes nothing")

equal(Selection.toggle("Magic", current: ["Internal", "Unplugged"], drivable: both), [],
      "a stale name in the config is dropped, and the result collapses to 'all'")

// MARK: - config round trip

section("config")

var cfg = Config(keyboards: ["Magic"])
cfg.save()
equal(Config.load(), cfg, "config survives a save/load round trip")

check(Config(keyboards: []).selects("anything"), "empty selection means every keyboard")
check(Config(keyboards: ["Magic"]).selects("Magic"), "a named keyboard is selected")
check(!Config(keyboards: ["Magic"]).selects("Internal"), "an unnamed keyboard is not")

try? FileManager.default.removeItem(at: configFile)
equal(Config.load(), Config(), "a missing config file loads defaults rather than failing")

// MARK: - blink decision

section("blink decision")

let now = Date()
func session(_ id: String, _ event: SessionEvent, pid: pid_t = 0, at: Date = Date()) -> Session {
    Session(id: id, pid: pid, event: event, at: at)
}

check(!shouldBlink(sessions: []), "no sessions, no blinking")
check(shouldBlink(sessions: [session("a", .stop)]), "a finished turn blinks")
check(shouldBlink(sessions: [session("a", .notify)]), "a permission prompt blinks")
check(!shouldBlink(sessions: [session("a", .prompt)]), "work in flight does not blink")
check(shouldBlink(sessions: [session("a", .prompt), session("b", .stop)]),
      "OR across windows: one waiting session is enough")
check(!shouldBlink(sessions: [session("a", .prompt), session("b", .prompt)]),
      "several busy sessions still do not blink")

// MARK: - staleness
//
// The requirement is that a kill -9'd terminal cannot leave the lamp blinking.

section("staleness")

let dead: (pid_t) -> Bool = { _ in false }
let living: (pid_t) -> Bool = { _ in true }

check(isStale(session("a", .stop, pid: 4242), alive: dead),
      "a session whose process is gone is stale")
check(!isStale(session("a", .stop, pid: 4242), alive: living),
      "a session whose process lives is kept")
check(!isStale(session("a", .stop, pid: 0), alive: dead),
      "pid 0 means unknown, so the pid check must not fire")
check(isStale(session("a", .stop, pid: 0, at: now.addingTimeInterval(-staleTTL - 1)),
              now: now, alive: dead),
      "an unidentified session older than the TTL is stale")
check(!isStale(session("a", .stop, pid: 0, at: now.addingTimeInterval(-60)),
               now: now, alive: dead),
      "a recent unidentified session is kept")

// MARK: - session files

section("session files")

record(session: "s1", event: .stop, pid: 1234)
record(session: "s2", event: .prompt, pid: 0)
equal(readSessions().count, 2, "both session files are read back")
check(readSessions().contains { $0.id == "s1" && $0.event == .stop }, "event survives the round trip")

record(session: "s1", event: .prompt, pid: 1234)
check(readSessions().contains { $0.id == "s1" && $0.event == .prompt },
      "recording again overwrites the event rather than adding a session")

forget("s1")
equal(readSessions().count, 1, "forgetting removes exactly one session")

try? "garbage".write(to: sessionsDir.appendingPathComponent("broken"),
                     atomically: true, encoding: .utf8)
equal(readSessions().count, 1, "an unparseable file is ignored, not crashed on")
try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent("broken"))

equal(safeSessionID("../../etc/passwd"), "_/_/etc/passwd".replacingOccurrences(of: "/", with: "_"),
      "a session id cannot escape its directory")

// MARK: - hook merging
//
// This one writes to the user's settings.json in production, so it gets the most care.

section("hook merging")

let foreign: [String: Any] = [
    "model": "opus",
    "hooks": [
        "Stop": [["hooks": [["type": "command", "command": "someone-elses-hook.sh"]]]],
        "PreToolUse": [["hooks": [["type": "command", "command": "another.sh"]]]],
    ],
]

let installed = HookPlan.install(into: foreign, executable: "/Applications/claudeled.app/x")

check(installed["model"] as? String == "opus", "unrelated top-level keys are preserved")

func commands(_ settings: [String: Any], _ event: String) -> [String] {
    let hooks = settings["hooks"] as? [String: Any] ?? [:]
    let groups = hooks[event] as? [[String: Any]] ?? []
    return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
}

check(commands(installed, "Stop").contains("someone-elses-hook.sh"),
      "a foreign hook on an event we also use is preserved")
check(commands(installed, "Stop").contains { $0.contains("claudeled") },
      "our hook is added alongside it")
check(commands(installed, "PreToolUse") == ["another.sh"],
      "an event we do not use is left completely alone")
check(HookPlan.installed(in: installed, executable: "/Applications/claudeled.app/x"),
      "install is detected afterwards")

let twice = HookPlan.install(into: installed, executable: "/Applications/claudeled.app/x")
equal(commands(twice, "Stop").filter { $0.contains("claudeled") }.count, 1,
      "installing twice does not duplicate our hook")

let moved = HookPlan.install(into: installed, executable: "/new/path/claudeled")
equal(commands(moved, "Stop").filter { $0.contains("claudeled") }.count, 1,
      "a moved bundle replaces the old entry instead of adding a second")
check(commands(moved, "Stop").contains { $0.contains("/new/path/claudeled") },
      "the replacement points at the new location")
check(commands(moved, "Stop").contains("someone-elses-hook.sh"),
      "moving still preserves foreign hooks")

let removed = HookPlan.remove(from: installed)
check(!commands(removed, "Stop").contains { $0.contains("claudeled") },
      "remove takes our hook out")
check(commands(removed, "Stop").contains("someone-elses-hook.sh"),
      "remove leaves foreign hooks in place")
check(!HookPlan.installed(in: removed, executable: "/Applications/claudeled.app/x"),
      "removal is detected")
check((removed["hooks"] as? [String: Any])?["Notification"] == nil,
      "an event that held only our hook is dropped entirely")

let virgin = HookPlan.remove(from: ["model": "opus"])
check(virgin["hooks"] == nil, "removing from settings without hooks does not invent a hooks key")

check(!HookPlan.events.contains { $0.claudeEvent == "SubagentStop" },
      "SubagentStop stays unhooked, or subagents would blink for the main agent")

// MARK: -

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("\(failures) FAILED")
    exit(1)
}
print("PASS")
