import Foundation

/// ELTransfer owns timing; Sparkle owns the update session and installation.
struct UpdateCheckSchedule {
  static let interval: TimeInterval = 60
  private(set) var nextCheck = Date.distantPast
  private(set) var failures = 0
  private(set) var inFlight = false
  private var lastAttempt = Date.distantPast

  func isDue(now: Date, online: Bool, canCheck: Bool) -> Bool {
    online && canCheck && !inFlight && now >= nextCheck
  }

  mutating func begin(now: Date = Date()) {
    inFlight = true
    lastAttempt = now
  }

  mutating func connectionRestored(now: Date) {
    guard failures > 0, !inFlight else { return }
    // Reconnects can shorten backoff, but network flapping cannot hammer the feed.
    nextCheck = min(nextCheck, max(now, lastAttempt.addingTimeInterval(60)))
  }

  mutating func succeeded(now: Date) {
    failures = 0
    nextCheck = lastAttempt.addingTimeInterval(Self.interval)
    inFlight = false
  }

  mutating func finished(now: Date) {
    guard inFlight else { return }
    inFlight = false
    failures += 1
    nextCheck = lastAttempt.addingTimeInterval(Self.interval)
  }
}
