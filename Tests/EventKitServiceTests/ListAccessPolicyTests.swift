import Foundation
import Testing

@testable import EventKitService

@Suite("List access policy tests")
struct ListAccessPolicyTests {
    @Test("Unrestricted policy allows every list")
    func unrestrictedAllowsEverything() {
        let policy = ListAccessPolicy.unrestricted

        #expect(!policy.isRestricted)
        #expect(policy.isAllowed("anything"))
        #expect(policy.filter(["a", "b"]) == ["a", "b"])
    }

    @Test("Restricted policy admits only configured lists")
    func restrictedAdmitsConfiguredOnly() {
        let policy = ListAccessPolicy(allowedIds: ["list-1"])

        #expect(policy.isRestricted)
        #expect(policy.isAllowed("list-1"))
        #expect(!policy.isAllowed("list-2"))
        #expect(policy.filter(["list-1", "list-2"]) == ["list-1"])
    }

    @Test("An allowlist matching nothing is treated as an empty match, not as unrestricted")
    func emptyMatchIsDetected() {
        let restricted = ListAccessPolicy(allowedIds: ["missing"])

        // The regression this guards: EventKit reads an empty calendars array as
        // "every calendar", so a restricted policy matching nothing must be caught
        // before a predicate is built.
        #expect(restricted.isEmptyMatch(matchedCount: 0))
        #expect(!restricted.isEmptyMatch(matchedCount: 1))
    }

    @Test("An unrestricted policy with no lists is not an empty match")
    func unrestrictedEmptyIsNotAnEmptyMatch() {
        // A machine with zero reminder lists is legitimately empty and must not be
        // confused with a misconfigured allowlist.
        #expect(!ListAccessPolicy.unrestricted.isEmptyMatch(matchedCount: 0))
    }

    @Test("Unresolved identifiers are reported for startup validation")
    func unresolvedIdsAreReported() {
        let policy = ListAccessPolicy(allowedIds: ["live", "stale", "typo"])

        #expect(policy.unresolvedIds(available: ["live", "other"]) == ["stale", "typo"])
        #expect(policy.unresolvedIds(available: ["live", "stale", "typo"]).isEmpty)
    }

    @Test("An unrestricted policy never reports unresolved identifiers")
    func unrestrictedReportsNoUnresolved() {
        #expect(ListAccessPolicy.unrestricted.unresolvedIds(available: []).isEmpty)
    }

    @Test("Validation is fatal only when a restriction resolves to nothing")
    func fatalOnlyWhenRestrictedAndUnresolved() {
        let noneResolved = AllowedListValidation(
            isRestricted: true,
            resolvedCount: 0,
            unresolvedIds: ["gone"]
        )
        let someResolved = AllowedListValidation(
            isRestricted: true,
            resolvedCount: 1,
            unresolvedIds: ["gone"]
        )

        #expect(noneResolved.isFatal)
        #expect(!someResolved.isFatal)
        #expect(!AllowedListValidation.unrestricted.isFatal)
    }
}
