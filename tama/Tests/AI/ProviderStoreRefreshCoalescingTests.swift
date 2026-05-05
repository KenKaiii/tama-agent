import Foundation
@testable import Tama
import Testing

// MARK: - Mock refresher

/// Records every call to `refresh` and simulates a configurable async delay so
/// concurrent callers actually race.
actor MockCredentialsRefresher: CredentialsRefresher {
    /// Number of times `refresh` was entered.
    private(set) var callCount = 0

    /// How long the fake network hop takes.  Long enough for two concurrent
    /// callers to both reach the guard before the first one finishes.
    nonisolated let delay: Duration = .milliseconds(50)

    /// Token returned on every successful refresh.
    nonisolated let newAccessToken = "refreshed-access-token"

    func refresh(
        provider: AIProvider,
        refreshToken _: String,
        accountId _: String?
    ) async throws -> ProviderCredential {
        callCount += 1
        try await Task.sleep(for: delay)
        return ProviderCredential.oauth(
            accessToken: newAccessToken,
            refreshToken: "new-refresh-token",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            accountId: provider == .gemini ? "proj-test" : "user-test"
        )
    }
}

// MARK: - Helpers

/// An already-expired OAuth credential.
private func expiredCredential(refreshToken: String = "old-refresh-token") -> ProviderCredential {
    ProviderCredential.oauth(
        accessToken: "old-access-token",
        refreshToken: refreshToken,
        expiresAt: Date(timeIntervalSinceNow: -1), // expired 1 second ago
        accountId: "user-test"
    )
}

// MARK: - Tests

@Suite("ProviderStore refresh coalescing")
@MainActor
struct ProviderStoreRefreshCoalescingTests {

    /// Two concurrent `validAccessToken` calls on an expired token must trigger
    /// exactly one OAuth refresh, and both must receive the new access token.
    @Test("concurrent expired-token calls coalesce into a single refresh")
    func concurrentCallsCoalesceRefresh() async throws {
        let mock = MockCredentialsRefresher()
        let store = ProviderStore.makeForTesting(refresher: mock)
        store.setCredential(expiredCredential(), for: .openai)

        // Launch both calls without awaiting either — they need to race on
        // the same main-actor hop where the task guard is checked.
        async let token1 = store.validAccessToken(for: .openai)
        async let token2 = store.validAccessToken(for: .openai)

        let (t1, t2) = try await (token1, token2)
        let count = await mock.callCount

        #expect(count == 1, "OAuth refresh must be called exactly once; got \(count)")
        #expect(t1 == mock.newAccessToken)
        #expect(t2 == mock.newAccessToken)
    }

    /// A second call after the first has already completed sees a fresh
    /// (non-expired) token and must NOT trigger another refresh.
    @Test("sequential calls do not double-refresh after token is updated")
    func sequentialCallsDoNotDoubleRefresh() async throws {
        let mock = MockCredentialsRefresher()
        let store = ProviderStore.makeForTesting(refresher: mock)
        store.setCredential(expiredCredential(), for: .openai)

        let t1 = try await store.validAccessToken(for: .openai)
        // By now the credential in the store is the freshly refreshed one.
        let t2 = try await store.validAccessToken(for: .openai)
        let count = await mock.callCount

        #expect(count == 1, "Only one refresh for sequential calls; got \(count)")
        #expect(t1 == mock.newAccessToken)
        #expect(t2 == mock.newAccessToken)
    }

    /// Refreshes for two different providers are independent — each gets its
    /// own task and its own refresh call.
    @Test("concurrent calls for different providers each refresh independently")
    func differentProvidersRefreshIndependently() async throws {
        let mock = MockCredentialsRefresher()
        let store = ProviderStore.makeForTesting(refresher: mock)
        store.setCredential(expiredCredential(), for: .openai)
        store.setCredential(expiredCredential(), for: .anthropic)

        async let t1 = store.validAccessToken(for: .openai)
        async let t2 = store.validAccessToken(for: .anthropic)

        _ = try await (t1, t2)
        let count = await mock.callCount

        #expect(count == 2, "Each provider must be refreshed once; got \(count)")
    }

    /// A non-expired API key must be returned immediately without any refresh.
    @Test("valid non-expired token returns without refresh")
    func validTokenSkipsRefresh() async throws {
        let mock = MockCredentialsRefresher()
        let store = ProviderStore.makeForTesting(refresher: mock)
        store.setCredential(
            ProviderCredential.oauth(
                accessToken: "still-valid",
                refreshToken: "rt",
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                accountId: "u"
            ),
            for: .openai
        )

        let token = try await store.validAccessToken(for: .openai)
        let count = await mock.callCount

        #expect(count == 0, "No refresh for a valid token")
        #expect(token == "still-valid")
    }
}
