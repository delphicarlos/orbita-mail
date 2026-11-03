import XCTest
@testable import OrbitaCore

private actor FixtureHTTP {
    struct Step {
        var method: String
        var path: String
        var status = 200
        var json: JSONObject = [:]
        var headers: [String: String] = [:]
        var networkFailure = false
    }
    private var steps: [Step]
    private var captured: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard !steps.isEmpty else { throw OrbitaError.invalidData("Unexpected extra request") }
        let step = steps.removeFirst()
        guard request.httpMethod == step.method, request.url?.path == step.path else {
            throw OrbitaError.invalidData("Unexpected fixture request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
        }
        if step.networkFailure { throw URLError(.timedOut) }
        return (try JSONSerialization.data(withJSONObject: step.json), HTTPURLResponse(url: request.url!, statusCode: step.status, httpVersion: nil, headerFields: step.headers)!)
    }
    func requests() -> [URLRequest] { captured }
    func remaining() -> Int { steps.count }
}

final class ProviderTests: XCTestCase {
    private func client(_ provider: Provider, steps: [FixtureHTTP.Step]) async throws -> (ProviderClient, FixtureHTTP, Account) {
        let account = Account(provider: provider, email: "fixture@example.com", name: "Fixture", clientID: "fixture-client")
        let vault = TokenVault(service: "br.com.intellitouch.orbita-tests." + UUID().uuidString)
        try await vault.save(OAuthToken(accessToken: "fixture-not-a-real-token", refreshToken: "fixture-refresh", expiresAt: .distantFuture), key: account.id)
        addTeardownBlock { try await vault.remove(key: account.id) }
        let fixture = FixtureHTTP(steps)
        let service = ProviderClient(account: account, vault: vault, transport: { try await fixture.send($0) })
        return (service, fixture, account)
    }

    func testMicrosoftCalendarEnumerationFollowsEveryPage() async throws {
        let (service, fixture, _) = try await client(.microsoft, steps: [
            .init(method: "GET", path: "/v1.0/me/calendars", json: ["value": [["id": "one", "name": "One", "canEdit": true]], "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/calendars?page=two"]),
            .init(method: "GET", path: "/v1.0/me/calendars", json: ["value": [["id": "two", "name": "Two", "canEdit": false]]])
        ])
        let sources = try await service.sources(kind: .event)
        XCTAssertEqual(sources.map(\.remoteID), ["one", "two"])
        XCTAssertFalse(sources[1].canEdit)
        let requests = await fixture.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-not-a-real-token" })
    }

    func testMicrosoftRejectsCredentialExfiltrationViaNextLink() async throws {
        let (service, fixture, _) = try await client(.microsoft, steps: [
            .init(method: "GET", path: "/v1.0/me/calendars", json: ["value": [], "@odata.nextLink": "https://attacker.example/steal"])
        ])
        do { _ = try await service.sources(kind: .event); XCTFail("Expected nextLink rejection") } catch {}
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 1)
    }

    func testGoogleEnumeratesAllTaskPagesIncludingHiddenAndAssigned() async throws {
        let (service, fixture, account) = try await client(.google, steps: [
            .init(method: "GET", path: "/tasks/v1/lists/list/tasks", json: ["kind": "tasks#tasks", "items": [["id": "dated", "title": "Dated", "due": "2026-11-03T00:00:00Z"]], "nextPageToken": "next-page"]),
            .init(method: "GET", path: "/tasks/v1/lists/list/tasks", json: ["kind": "tasks#tasks", "items": [["id": "undated", "title": "Undated"], ["id": "done", "title": "Done", "status": "completed"]]])
        ])
        let source = AgendaSource(accountID: account.id, remoteID: "list", name: "List", kind: .task)
        let items = try await service.agenda(source: source, interval: DateInterval(start: Date(), duration: 86400))
        XCTAssertEqual(items.count, 3); XCTAssertNil(items[1].displayDate); XCTAssertTrue(items[2].isCompleted)
        let requests = await fixture.requests()
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        for name in ["showCompleted", "showHidden", "showAssigned"] { XCTAssertTrue(query.contains { $0.name == name && $0.value == "true" }) }
        XCTAssertTrue(requests[1].url!.absoluteString.contains("pageToken=next-page"))
    }

    func testCalendarViewRequestsExpandedOccurrencesWithinExactWindow() async throws {
        let event: JSONObject = ["id": "occurrence", "subject": "Recurring", "start": ["dateTime": "2026-11-03T12:00:00", "timeZone": "UTC"], "end": ["dateTime": "2026-11-03T13:00:00", "timeZone": "UTC"], "isOrganizer": true]
        let (service, fixture, account) = try await client(.microsoft, steps: [.init(method: "GET", path: "/v1.0/me/calendars/calendar/calendarView", json: ["value": [event]])])
        let interval = DateInterval(start: Time.parse("2026-11-01T00:00:00Z")!, end: Time.parse("2026-12-01T00:00:00Z")!)
        let result = try await service.agenda(source: AgendaSource(accountID: account.id, remoteID: "calendar", name: "Calendar", kind: .event), interval: interval)
        XCTAssertEqual(result.count, 1)
        let request = await fixture.requests()[0]
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(query.contains { $0.name == "startDateTime" && $0.value == Time.iso(interval.start) })
        XCTAssertTrue(query.contains { $0.name == "endDateTime" && $0.value == Time.iso(interval.end) })
        XCTAssertTrue(request.value(forHTTPHeaderField: "Prefer")!.contains("ImmutableId"))
    }

    private func googleEvent(response: String) -> JSONObject {
        ["id": "event", "etag": "\"version-1\"", "summary": "Review", "start": ["dateTime": "2026-11-03T12:00:00Z"],
         "end": ["dateTime": "2026-11-03T13:00:00Z"], "organizer": ["email": "organizer@example.com"],
         "attendees": [["email": "fixture@example.com", "self": true, "responseStatus": response],
                       ["email": "other@example.com", "responseStatus": "accepted", "optional": true]]]
    }

    func testGoogleRSVPPreservesOtherAttendeesAndUsesETag() async throws {
        let (service, fixture, account) = try await client(.google, steps: [
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "needsAction")),
            .init(method: "PATCH", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "accepted")),
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "accepted"))
        ])
        let item = try ProviderClient.googleAgenda(googleEvent(response: "needsAction"), source: AgendaSource(accountID: account.id, remoteID: "calendar", name: "Calendar", kind: .event))
        let updated = try await service.respond(item, response: .accepted)
        XCTAssertEqual(updated.response, "accepted")
        let requests = await fixture.requests(), patch = requests[1]
        XCTAssertEqual(patch.value(forHTTPHeaderField: "If-Match"), "\"version-1\"")
        let body = try HTTP.object(patch.httpBody!)
        let attendees = body.objects("attendees")
        XCTAssertEqual(attendees.count, 2); XCTAssertTrue(attendees[1].flag("optional")); XCTAssertEqual(attendees[1].string("responseStatus"), "accepted")
        XCTAssertTrue(patch.url!.absoluteString.contains("sendUpdates=all"))
    }

    func testRSVPTimeoutReconcilesWithoutSendingAgain() async throws {
        let (service, fixture, account) = try await client(.google, steps: [
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "needsAction")),
            .init(method: "PATCH", path: "/calendar/v3/calendars/calendar/events/event", networkFailure: true),
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "accepted"))
        ])
        let item = try ProviderClient.googleAgenda(googleEvent(response: "needsAction"), source: AgendaSource(accountID: account.id, remoteID: "calendar", name: "Calendar", kind: .event))
        let updated = try await service.respond(item, response: .accepted)
        XCTAssertEqual(updated.response, "accepted")
        let requests = await fixture.requests(); XCTAssertEqual(requests.filter { $0.httpMethod == "PATCH" }.count, 1)
    }

    func testAlreadyAcceptedInvitationDoesNotSendAnotherResponse() async throws {
        let (service, fixture, account) = try await client(.google, steps: [
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "accepted")),
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "accepted"))
        ])
        let item = try ProviderClient.googleAgenda(googleEvent(response: "needsAction"), source: AgendaSource(accountID: account.id, remoteID: "calendar", name: "Calendar", kind: .event))
        _ = try await service.respond(item, response: .accepted)
        let requests = await fixture.requests(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }

    func testConcurrentRSVPVersionConflictDoesNotRetryWrite() async throws {
        let (service, fixture, account) = try await client(.google, steps: [
            .init(method: "GET", path: "/calendar/v3/calendars/calendar/events/event", json: googleEvent(response: "needsAction")),
            .init(method: "PATCH", path: "/calendar/v3/calendars/calendar/events/event", status: 412)
        ])
        let item = try ProviderClient.googleAgenda(googleEvent(response: "needsAction"), source: AgendaSource(accountID: account.id, remoteID: "calendar", name: "Calendar", kind: .event))
        do { _ = try await service.respond(item, response: .accepted); XCTFail("Expected version conflict") }
        catch OrbitaError.network(let status, _) { XCTAssertEqual(status, 412) }
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 2)
    }

    func testWrongAccountNeverMakesRemoteWrite() async throws {
        let (service, fixture, _) = try await client(.google, steps: [])
        let alien = DemoData.agenda()[2]
        do { _ = try await service.respond(alien, response: .accepted); XCTFail("Expected account rejection") } catch {}
        let requests = await fixture.requests(); XCTAssertTrue(requests.isEmpty)
    }

    func testRateLimitBlocksSubsequentCallsUntilRetryAfter() async throws {
        let (service, fixture, _) = try await client(.microsoft, steps: [.init(method: "GET", path: "/v1.0/me/calendars", status: 429, headers: ["Retry-After": "120"])])
        do { _ = try await service.sources(kind: .event); XCTFail("Expected rate limit") } catch {}
        do { _ = try await service.sources(kind: .event); XCTFail("Expected cooldown") } catch {}
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 1)
    }

    func testMicrosoftSendBuildsRecipientsAndDoesNotRetryAmbiguousPost() async throws {
        let (service, fixture, account) = try await client(.microsoft, steps: [.init(method: "POST", path: "/v1.0/me/sendMail", networkFailure: true)])
        var draft = MailDraft(accountID: account.id); draft.to = "recipient@example.com"; draft.subject = "Subject"; draft.text = "Text"
        do { try await service.send(draft); XCTFail("Expected timeout") } catch {}
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 1)
        let body = try HTTP.object(requests[0].httpBody!)
        XCTAssertEqual(body.object("message").objects("toRecipients")[0].object("emailAddress").string("address"), "recipient@example.com")
        XCTAssertEqual(body.object("message").object("body").string("content"), "Text")
    }

    func testTaskCompletionUsesOriginalListAndConfirmsRemoteState() async throws {
        let (service, fixture, account) = try await client(.google, steps: [
            .init(method: "GET", path: "/tasks/v1/lists/list/tasks/task", json: ["id": "task", "etag": "v1", "status": "needsAction"]),
            .init(method: "PATCH", path: "/tasks/v1/lists/list/tasks/task", json: ["id": "task", "status": "completed"]),
            .init(method: "GET", path: "/tasks/v1/lists/list/tasks/task", json: ["id": "task", "status": "completed"])
        ])
        let task = AgendaItem(accountID: account.id, sourceID: "list", sourceName: "List", remoteID: "task", kind: .task, title: "Task")
        let updated = try await service.complete(task, completed: true)
        XCTAssertTrue(updated.isCompleted)
        let requests = await fixture.requests(); XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Match"), "v1")
    }

    func testMicrosoftSendIncludesSignatureSnapshotExactlyOnce() async throws {
        let (service, fixture, account) = try await client(.microsoft, steps: [.init(method: "POST", path: "/v1.0/me/sendMail")])
        var draft = MailDraft(accountID: account.id); draft.to = "local@example.com"; draft.text = "Message"; draft.signatureText = "Fixture signature"
        try await service.send(draft)
        let requests = await fixture.requests()
        let body = try HTTP.object(requests[0].httpBody!).object("message").object("body").string("content")
        XCTAssertEqual(body, draft.composedText)
        XCTAssertEqual(body.components(separatedBy: "Fixture signature").count - 1, 1)
    }
}
