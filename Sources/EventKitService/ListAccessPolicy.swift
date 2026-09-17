import Foundation

/// Decides which reminder lists are reachable.
///
/// Extracted from `ReminderService` so the access rules can be exercised without
/// an `EKEventStore`, and so the "allowlist configured but nothing matched" case
/// has one place to fail closed.
public struct ListAccessPolicy: Sendable, Equatable {
    /// Identifiers the caller is limited to, or `nil` when no restriction is active.
    public let allowedIds: Set<String>?

    /// Unrestricted access to every list.
    public static let unrestricted = ListAccessPolicy(allowedIds: nil)

    public init(allowedIds: Set<String>?) {
        self.allowedIds = allowedIds
    }

    /// Whether an allowlist is in force.
    public var isRestricted: Bool {
        allowedIds != nil
    }

    public func isAllowed(_ id: String) -> Bool {
        guard let allowedIds else { return true }
        return allowedIds.contains(id)
    }

    /// Narrow `ids` to the permitted set, preserving order.
    public func filter(_ ids: [String]) -> [String] {
        guard let allowedIds else { return ids }
        return ids.filter { allowedIds.contains($0) }
    }

    /// Whether a filtered result of `count` lists means access has collapsed to nothing.
    ///
    /// EventKit treats an empty `calendars:` array as "every calendar", so handing it
    /// an empty filtered set would invert the allowlist into unrestricted access. A
    /// restricted policy that matches nothing must therefore yield no results rather
    /// than falling through to an unbounded query.
    public func isEmptyMatch(matchedCount: Int) -> Bool {
        isRestricted && matchedCount == 0
    }

    /// Configured identifiers that are not present in `available`.
    ///
    /// Used at startup to surface a mistyped or stale `--allowed-lists` entry instead
    /// of letting it silently narrow — or erase — the restriction.
    public func unresolvedIds(available: Set<String>) -> [String] {
        guard let allowedIds else { return [] }
        return allowedIds.subtracting(available).sorted()
    }
}

/// Outcome of checking a configured allowlist against the lists that exist.
public struct AllowedListValidation: Sendable, Equatable {
    public let isRestricted: Bool
    public let resolvedCount: Int
    public let unresolvedIds: [String]

    /// No allowlist configured, so nothing to validate.
    public static let unrestricted = AllowedListValidation(
        isRestricted: false,
        resolvedCount: 0,
        unresolvedIds: []
    )

    public init(isRestricted: Bool, resolvedCount: Int, unresolvedIds: [String]) {
        self.isRestricted = isRestricted
        self.resolvedCount = resolvedCount
        self.unresolvedIds = unresolvedIds
    }

    /// A restriction is configured but no configured list exists.
    ///
    /// Every query would be denied, so the server should refuse to start rather than
    /// run in a state the operator almost certainly did not intend.
    public var isFatal: Bool {
        isRestricted && resolvedCount == 0
    }
}
