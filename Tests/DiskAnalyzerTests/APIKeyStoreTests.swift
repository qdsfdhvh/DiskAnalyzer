import XCTest
@testable import DiskAnalyzer

// MARK: - In-memory key store

private final class InMemoryKeyStore: APIKeyStoring, @unchecked Sendable {
    var keys: [String: String] = [:]
    var storeCalls = 0

    func store(key: String, for account: String) throws {
        storeCalls += 1
        keys[account] = key
    }

    func loadKey(for account: String) throws -> String? {
        keys[account]
    }

    func deleteKey(for account: String) throws {
        keys.removeValue(forKey: account)
    }
}

// MARK: - Tests

final class APIKeyStoreTests: XCTestCase {

    func testStoreAndLoadRoundTrip() throws {
        let store = InMemoryKeyStore()
        try store.store(key: "sk-test-123", for: "openai")
        XCTAssertEqual(try store.loadKey(for: "openai"), "sk-test-123")
    }

    func testOverwriteReplacesValue() throws {
        let store = InMemoryKeyStore()
        try store.store(key: "old", for: "openai")
        try store.store(key: "new", for: "openai")
        XCTAssertEqual(try store.loadKey(for: "openai"), "new")
    }

    func testDeleteRemovesValue() throws {
        let store = InMemoryKeyStore()
        try store.store(key: "sk", for: "openai")
        try store.deleteKey(for: "openai")
        XCTAssertNil(try store.loadKey(for: "openai"))
    }

    func testLoadMissingReturnsNil() throws {
        let store = InMemoryKeyStore()
        XCTAssertNil(try store.loadKey(for: "missing-account"))
    }

    func testAccountsAreIsolated() throws {
        let store = InMemoryKeyStore()
        try store.store(key: "a", for: "account-a")
        try store.store(key: "b", for: "account-b")
        XCTAssertEqual(try store.loadKey(for: "account-a"), "a")
        XCTAssertEqual(try store.loadKey(for: "account-b"), "b")
    }
}
