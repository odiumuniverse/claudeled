// Blinker.swift -- the loop that turns session state into light.

import Foundation

final class Blinker {
    private let registry: KeyboardRegistry
    private let queue = DispatchQueue(label: "claudeled.blink")
    private var running = true

    init(registry: KeyboardRegistry) { self.registry = registry }

    func stop() {
        running = false
        registry.set(false)
    }

    func start() {
        queue.async { [self] in
            var lastPrune = Date.distantPast
            // Re-read once a second alongside the prune, so changing the timeout from
            // the menu or the CLI takes effect without a restart.
            var timeout = BlinkTimeout.forever
            while running {
                if Date().timeIntervalSince(lastPrune) > 1 {
                    pruneSessions()
                    timeout = Config.load().blinkTimeout
                    lastPrune = Date()
                }
                guard shouldBlink(sessions: readSessions(), timeout: timeout) else {
                    registry.set(false)
                    Thread.sleep(forTimeInterval: 0.25)
                    continue
                }
                for (index, milliseconds) in blinkPattern.enumerated() {
                    guard running else { break }
                    registry.set(index % 2 == 0)
                    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
                }
                registry.set(false)
            }
        }
    }
}
