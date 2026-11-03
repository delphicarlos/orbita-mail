import XCTest
@testable import OrbitaCore

final class CoreTests: XCTestCase {
    func testPKCEKnownRFCVector() {
        XCTAssertEqual(OAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testOAuthStatePathAndDuplicateParametersAreRejected() throws {
        XCTAssertEqual(try OAuth.callbackCode("/oauth/callback?state=expected&code=abc", expectedState: "expected"), "abc")
        for target in ["/oauth/callback?state=wrong&code=abc", "/wrong?state=expected&code=abc", "/oauth/callback?state=expected&state=expected&code=abc", "/oauth/callback?state=expected&error=access_denied"] {
            XCTAssertThrowsError(try OAuth.callbackCode(target, expectedState: "expected"))
        }
    }

    func testFormEscapesPlusAndPKCEAuthorizationUsesFixedOrigin() throws {
        let form = String(data: OAuth.form(["code": "a+b&c=d"]), encoding: .utf8)!
        XCTAssertTrue(form.contains("a%2Bb%26c%3Dd"))
        let url = try OAuth.authorizationURL(provider: .google, clientID: "desktop-id", redirect: "http://127.0.0.1:123/callback", state: "test-state", verifier: "test-verifier")
        XCTAssertEqual(url.host, "accounts.google.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains { $0.name == "code_challenge_method" && $0.value == "S256" })
        XCTAssertThrowsError(try OAuth.authorizationURL(provider: .google, clientID: "", redirect: "", state: "", verifier: ""))
    }

    func testProviderRejectsForeignOriginsAndCredentialsInURLs() {
        for text in ["https://graph.microsoft.com.evil.example/v1.0/me", "http://graph.microsoft.com/v1.0/me", "https://user:pass@graph.microsoft.com/v1.0/me", "https://graph.microsoft.com/beta/me"] {
            XCTAssertFalse(ProviderClient.allowed(URL(string: text)!, provider: .microsoft))
        }
        XCTAssertFalse(ProviderClient.allowed(URL(string: "https://www.googleapis.com/calendar/v3/me")!, provider: .microsoft))
        XCTAssertTrue(ProviderClient.allowed(URL(string: "https://graph.microsoft.com/v1.0/me")!, provider: .microsoft))
    }

    func testScopedIDsCannotCollideAcrossAccountsAndSeparators() {
        XCTAssertNotEqual(scopedID("a:b", "c"), scopedID("a", "b:c"))
        let messages = DemoData.messages()
        XCTAssertEqual(Set(messages.map(\.id)).count, messages.count)
        XCTAssertNotEqual(DemoData.agenda()[0].id, DemoData.agenda()[1].id)
    }

    func testCalendarKeepsDateOnlyAndUndatedTasks() throws {
        let source = AgendaSource(accountID: "account", remoteID: "list", name: "Tasks", kind: .task)
        let task = try ProviderClient.googleAgenda(["id": "dated", "title": "Task", "due": "2026-11-03T00:00:00.000Z"], source: source)
        XCTAssertEqual(task.day, "2026-11-03")
        XCTAssertNil(task.start)
        let undated = try ProviderClient.googleAgenda(["id": "undated", "title": "Task"], source: source)
        XCTAssertNil(undated.displayDate)
        XCTAssertThrowsError(try ProviderClient.googleAgenda(["id": "bad", "due": "not-a-date"], source: source))
    }

    func testTimedEventsRequireAnExplicitTimezone() throws {
        let source = AgendaSource(accountID: "a", remoteID: "cal", name: "Calendar", kind: .event)
        let valid: JSONObject = ["id": "event", "start": ["dateTime": "2026-11-03T12:00:00-03:00"], "end": ["dateTime": "2026-11-03T13:00:00-03:00"]]
        let item = try ProviderClient.googleAgenda(valid, source: source)
        XCTAssertEqual(item.start, Time.parse("2026-11-03T15:00:00Z"))
        XCTAssertThrowsError(try ProviderClient.googleAgenda(["id": "event", "start": ["dateTime": "2026-11-03T12:00:00"], "end": ["dateTime": "2026-11-03T13:00:00"]], source: source))
        XCTAssertThrowsError(try Time.graphDate(["dateTime": "2026-11-03T12:00:00", "timeZone": "Unknown"]))
    }
    func testMicrosoftAllDayPreservesOriginalLocalDateAcrossUTC() throws {
        let value = try Time.graphAllDay(["dateTime": "2026-11-02T15:00:00.0000000", "timeZone": "UTC"], originalZone: "Tokyo Standard Time")
        XCTAssertEqual(value, "2026-11-03")
        XCTAssertThrowsError(try Time.graphAllDay(["dateTime": "2026-11-03T00:00:00", "timeZone": "UTC"], originalZone: "tzone://Custom/Unknown"))
    }

    func testOverlappingAccountsHaveSeparateCalendarColumns() {
        let day = Time.dayDate("2026-11-03")!
        let items = DemoData.agenda(now: day)
        let placements = AgendaLayout.placements(items, day: day)
        let duplicateMeeting = placements.filter { $0.item.remoteID == "weekly" }
        XCTAssertEqual(duplicateMeeting.count, 2)
        XCTAssertEqual(Set(duplicateMeeting.map(\.column)).count, 2)
        XCTAssertTrue(duplicateMeeting.allSatisfy { $0.columns == 2 })
        XCTAssertTrue(AgendaLayout.conflicts(items[2], among: items))
    }

    func testMIMEEncodesUnicodeAndPreventsHeaderInjection() throws {
        var draft = MailDraft(accountID: "a"); draft.to = "person@example.com"; draft.subject = "Reunião amanhã"; draft.text = "Olá, mundo!"
        draft.attachments = [OutgoingAttachment(name: "relatório.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))]
        let content = String(data: try MIME.message(draft, from: "sender@example.com"), encoding: .utf8)!
        XCTAssertTrue(content.contains("Subject: =?UTF-8?B?"))
        XCTAssertTrue(content.contains("filename*=UTF-8''relat%C3%B3rio.pdf"))
        XCTAssertTrue(content.contains("Content-Transfer-Encoding: base64"))
        draft.subject = "Hello\r\nBcc: victim@example.com"
        XCTAssertThrowsError(try MIME.message(draft, from: "sender@example.com"))
        draft.subject = "Hello"; draft.to = "person@example.com\r\nBcc: victim@example.com"
        XCTAssertThrowsError(try MIME.message(draft, from: "sender@example.com"))
    }

    func testMailValidationRejectsEmptyRecipientsAndOversizedAttachments() {
        var draft = MailDraft(accountID: "a")
        XCTAssertThrowsError(try MailValidation.validate(draft))
        draft.to = "person@example.com"
        draft.attachments = [OutgoingAttachment(name: "large", mimeType: "application/octet-stream", data: Data(count: 2_500_001))]
        XCTAssertThrowsError(try MailValidation.validate(draft))
    }
    func testMicrosoftDraftWithoutReceivedDateUsesCreationDate() throws {
        let message = try ProviderClient.graphMessage(["id": "draft", "subject": "Draft", "createdDateTime": "2026-11-03T12:00:00Z"], accountID: "account")
        XCTAssertEqual(message.date, Time.parse("2026-11-03T12:00:00Z"))
    }

    func testHTMLDisablesScriptsRemoteContentAndPrivilegedLinks() {
        let document = SafeHTML.document(text: "<script>test</script>", html: "")
        XCTAssertTrue(document.contains("&lt;script&gt;"))
        XCTAssertTrue(document.contains("script-src 'none'"))
        XCTAssertTrue(document.contains("form-action 'none'"))
        XCTAssertTrue(document.contains("connect-src 'none'"))
        for url in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "https://u:p@example.com"] {
            XCTAssertFalse(SafeHTML.externalLinkAllowed(URL(string: url)!))
        }
        XCTAssertTrue(SafeHTML.externalLinkAllowed(URL(string: "https://example.com")!))
        XCTAssertEqual(MailBody(html: "<style>hidden</style><script>bad()</script><p>Olá &amp; obrigado</p><p>Até breve</p>").plainText,
                       "Olá & obrigado\nAté breve\n")
    }
}
