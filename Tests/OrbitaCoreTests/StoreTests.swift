import XCTest
@testable import OrbitaCore

final class StoreTests: XCTestCase {
    private func store() throws -> LocalStore {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/test-data/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try LocalStore(url: root.appendingPathComponent("cache.sqlite"))
    }
    func testSnapshotsRemoveCancelledOccurrenceOnlyInSuccessfulWindowAndSource() async throws {
        let store = try store(), accounts = DemoData.accounts
        let start = Time.dayDate("2026-11-03")!, end = Time.dayDate("2026-11-04")!
        let sourceA = AgendaSource(accountID: accounts[0].id, remoteID: "cal", name: "A", kind: .event)
        let sourceB = AgendaSource(accountID: accounts[1].id, remoteID: "cal", name: "B", kind: .event)
        let inWindow = AgendaItem(accountID: accounts[0].id, sourceID: "cal", sourceName: "A", remoteID: "occurrence-1", kind: .event, title: "A", start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200))
        var outside = inWindow; outside.remoteID = "occurrence-2"; outside.start = end.addingTimeInterval(3600); outside.end = end.addingTimeInterval(7200)
        var otherAccount = inWindow; otherAccount.accountID = accounts[1].id
        try await store.replaceAgenda([inWindow, outside], source: sourceA, interval: nil)
        try await store.replaceAgenda([otherAccount], source: sourceB, interval: nil)
        try await store.replaceAgenda([], source: sourceA, interval: DateInterval(start: start, end: end))
        let remaining = try await store.values(AgendaItem.self, bucket: "event")
        XCTAssertEqual(Set(remaining.map(\.id)), Set([outside.id, otherAccount.id]))
    }
    func testInvalidCrossAccountMailBatchRollsBackWithoutLosingPreviousCache() async throws {
        let store = try store(), messages = DemoData.messages()
        let original = messages[0], alien = messages[1]
        try await store.saveMail([original], account: original.accountID, folder: "inbox", replace: true)
        do { try await store.saveMail([original, alien], account: original.accountID, folder: "inbox", replace: true); XCTFail("Expected account validation") }
        catch {}
        let remaining = try await store.values(MailMessage.self, bucket: "mail")
        XCTAssertEqual(remaining.map(\.id), [original.id])
    }
    func testReopenPersistsAccountsDraftsAndIndependentSources() async throws {
        let store = try store(), account = DemoData.accounts[0]
        try await store.put(account, id: account.id, bucket: "account")
        var draft = MailDraft(accountID: account.id); draft.subject = "Draft"; draft.deliveryState = "uncertain"
        try await store.put(draft, id: draft.id, bucket: "draft", account: account.id)
        let readAccounts = try await store.values(Account.self, bucket: "account")
        let readDrafts = try await store.values(MailDraft.self, bucket: "draft", account: account.id)
        XCTAssertEqual(readAccounts, [account]); XCTAssertEqual(readDrafts.first?.deliveryState, "uncertain")
        try await store.removeAccount(account.id)
        let afterRemoval = try await store.values(MailDraft.self, bucket: "draft")
        XCTAssertTrue(afterRemoval.isEmpty)
    }
    func testRemovingSourceClearsOnlyThatSourcesAgenda() async throws {
        let store = try store(), account = DemoData.accounts[0]
        let sources = DemoData.sources().filter { $0.accountID == account.id }
        for kind in [AgendaKind.event, .task] { try await store.replaceSources(sources.filter { $0.kind == kind }, account: account.id, kind: kind) }
        for source in sources { try await store.replaceAgenda(DemoData.agenda().filter { $0.accountID == account.id && $0.kind == source.kind }, source: source, interval: nil) }
        try await store.replaceSources([], account: account.id, kind: .event)
        let events = try await store.values(AgendaItem.self, bucket: "event")
        let tasks = try await store.values(AgendaItem.self, bucket: "task")
        XCTAssertTrue(events.isEmpty); XCTAssertFalse(tasks.isEmpty)
    }
    func testImportedAccountsStayPendingWithoutCreatingAuthenticatedAccounts() async throws {
        let store = try store()
        let account = ImportedAccount(email: "person@example.com", displayName: "Person", provider: .google, sourceKind: "IMAP")
        let signature = WritingPreset(name: "Work", text: "Regards", kind: .signature)
        try await store.saveImportedSettings(accounts: [account], presets: [signature])
        try await store.saveImportedSettings(accounts: [account], presets: [signature])
        let authenticated = try await store.values(Account.self, bucket: "account")
        let candidates = try await store.values(ImportedAccount.self, bucket: "imported-account")
        let presets = try await store.values(WritingPreset.self, bucket: "writing-preset")
        XCTAssertTrue(authenticated.isEmpty)
        XCTAssertEqual(candidates.count, 1); XCTAssertEqual(presets.count, 1)
    }

    func testFolderSnapshotCannotReplaceAnotherAccountsFolders() async throws {
        let storage = try store()
        let original = MailboxFolder(accountID: "a", remoteID: "folder", name: "A", unreadCount: 500)
        try await storage.replaceMailboxes([original], account: "a")
        do { try await storage.replaceMailboxes([MailboxFolder(accountID: "b", remoteID: "folder", name: "B")], account: "a"); XCTFail("Account mismatch") } catch {}
        let saved = try await storage.values(MailboxFolder.self, bucket: "mailbox", account: "a")
        XCTAssertEqual(saved, [original])
    }
    func testCustomFolderCacheIsIndependentFromInboxAndOtherAccounts() async throws {
        let storage = try store()
        let a = MailMessage(remoteID: "same", accountID: "a", subject: "A", sender: "sender@example.com", date: Date(), preview: "")
        var b = a; b.accountID = "b"; b.subject = "B"
        try await storage.saveMail([a], account: "a", folder: "custom:clients", replace: true)
        try await storage.saveMail([b], account: "b", folder: "custom:clients", replace: true)
        try await storage.saveMail([], account: "a", folder: "inbox", replace: true)
        let left = try await storage.values(MailMessage.self, bucket: "mail", account: "a", source: "custom:clients")
        let right = try await storage.values(MailMessage.self, bucket: "mail", account: "b", source: "custom:clients")
        XCTAssertEqual(left.first?.subject, "A"); XCTAssertEqual(right.first?.subject, "B")
    }
}
