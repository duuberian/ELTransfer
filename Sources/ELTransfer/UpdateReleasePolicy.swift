import Foundation
import Sparkle

/// Keep Sparkle's standard build comparator, while rejecting older product releases.
enum UpdateReleasePolicy {
  static func allows(version: String, build: String, currentVersion: String, currentBuild: String) -> Bool {
    guard numericVersion(version), numericVersion(currentVersion) else { return false }
    let comparator = SUStandardVersionComparator.default
    return comparator.compareVersion(version, toVersion: currentVersion) != .orderedAscending
      && comparator.compareVersion(build, toVersion: currentBuild) == .orderedDescending
  }

  static func bestItem(in items: [SUAppcastItem], currentVersion: String, currentBuild: String) -> SUAppcastItem? {
    // Sparkle supplies compatible top-level candidates and retains its OS, channel,
    // skipped-version and delta-selection rules around this delegate hook.
    items.filter {
      allows(version: $0.displayVersionString, build: $0.versionString,
        currentVersion: currentVersion, currentBuild: currentBuild)
    }.max {
      let comparator = SUStandardVersionComparator.default
      let versionOrder = comparator.compareVersion($0.displayVersionString, toVersion: $1.displayVersionString)
      return versionOrder == .orderedSame
        ? comparator.compareVersion($0.versionString, toVersion: $1.versionString) == .orderedAscending
        : versionOrder == .orderedAscending
    }
  }

  private static func numericVersion(_ version: String) -> Bool {
    version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
  }
}
