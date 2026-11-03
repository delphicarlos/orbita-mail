import XCTest
@testable import OrbitaCore

private actor OrganizationHTTP {
    struct Reply { var method: String; var path: String; var json: JSONObject = [:]; var failure = false }
    var replies: [Reply]
    var captured: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        captured.append(request)
        guard let index = replies.firstIndex(where: { $0.method == request.httpMethod && $0.path == request.url?.path }) else { throw OrbitaError.invalidData("Unexpected fixture request") }
        let reply = replies.remove(at: index)
        if reply.failure { throw URLError(.timedOut) }
        return (try JSONSerialization.data(withJSONObject: reply.json), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
    }
    func requests() -> [URLRequest] { captured }
}
private actor OrganizationWire {
    var replies: [Data]
    var captured: [MailWireRequest] = []
    init(_ replies: [Data]) { self.replies = replies }
    func send(_ request: MailWireRequest) throws -> Data {
        captured.append(request)
        guard !replies.isEmpty else { throw OrbitaError.invalidData("Unexpected wire request") }
        return replies.removeFirst()
    }
    func requests() -> [MailWireRequest] { captured }
}

final class MailOrganizationTests: XCTestCase {
    private func client(_ provider: Provider, replies: [OrganizationHTTP.Reply], management: Bool = true) async throws -> (ProviderClient, OrganizationHTTP, Account) {
        let account = Account(provider: provider, email: "fixture@example.com", name: "Fixture", clientID: "fixture")
        let vault = TokenVault(service: "br.com.intellitouch.orbita-tests." + UUID().uuidString)
        try await vault.save(OAuthToken(accessToken: "synthetic", refreshToken: "synthetic", expiresAt: .distantFuture, scope: OAuth.scopes(provider, mailSettings: management)), key: account.id)
        addTeardownBlock { try await vault.remove(key: account.id) }
        let fixture = OrganizationHTTP(replies)
        return (ProviderClient(account: account, vault: vault, transport: { try await fixture.send($0) }), fixture, account)
    }
    private func message(_ account: Account) -> MailMessage { MailMessage(remoteID: "message", accountID: account.id, subject: "Fixture", sender: "sender@example.com", date: Date(), preview: "") }
    private let vacationPath = "/gmail/v1/users/me/settings/vacation"

    func testMailManagementScopesAreOptionalAndRequireExplicitOptIn() throws {
        for provider in [Provider.google, .microsoft] {
            XCTAssertFalse(OAuth.scopes(provider).contains("settings")); XCTAssertFalse(OAuth.scopes(provider).contains("MailboxSettings"))
            let url = try OAuth.authorizationURL(provider: provider, clientID: "fixture", redirect: "http://127.0.0.1/callback", state: "state", verifier: "verifier", mailSettings: true)
            let scope = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "scope" }!.value!
            XCTAssertTrue(scope.contains(provider == .google ? "gmail.settings.basic" : "MailboxSettings.ReadWrite"))
        }
    }
    func testOldConsentNeverSendsMailSettingsRequests() async throws {
        let (service, fixture, _) = try await client(.google, replies: [], management: false)
        do { _ = try await service.routingRules(); XCTFail("Permission required") } catch OrbitaError.authentication {} catch { XCTFail("Wrong error") }
        let requests = await fixture.requests(); XCTAssertTrue(requests.isEmpty)
    }
    func testGoogleUnreadCountUsesServerTotalRatherThanLoadedPage() async throws {
        let (service, fixture, _) = try await client(.google, replies: [
            .init(method: "GET", path: "/gmail/v1/users/me/labels", json: ["labels": [["id": "INBOX", "name": "INBOX", "type": "system"], ["id": "client", "name": "Clientes", "type": "user"]]]),
            .init(method: "GET", path: "/gmail/v1/users/me/labels/INBOX", json: ["messagesUnread": 1453, "messagesTotal": 15000]),
            .init(method: "GET", path: "/gmail/v1/users/me/labels/client", json: ["messagesUnread": 71, "messagesTotal": 90])
        ])
        let boxes = try await service.mailboxes()
        XCTAssertEqual(boxes.first { $0.standard == .inbox }?.unreadCount, 1453)
        XCTAssertEqual(boxes.first { $0.standard == nil }?.unreadCount, 71)
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 3)
    }
    func testGoogleFolderCreationDoesNotCreateOrSendMessages() async throws {
        let (service, fixture, _) = try await client(.google, replies: [
            .init(method: "GET", path: "/gmail/v1/users/me/labels", json: ["labels": []]),
            .init(method: "POST", path: "/gmail/v1/users/me/labels", json: ["id": "new-label", "name": "Clientes"])
        ])
        let box = try await service.createMailbox(name: "  Clientes  ")
        XCTAssertEqual(box.remoteID, "new-label")
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 2)
        let body = try HTTP.object(requests[1].httpBody!)
        XCTAssertEqual(body.string("name"), "Clientes")
    }
    func testCustomFolderMessagesAndCrossAccountMovesUseOriginalAccount() async throws {
        let (service, fixture, account) = try await client(.microsoft, replies: [.init(method: "GET", path: "/v1.0/me/mailFolders/custom/messages", json: ["value": []])])
        let other = MailboxFolder(accountID: "other", remoteID: "folder", name: "Other")
        do { try await service.move(message(account), toMailbox: other); XCTFail("Account mismatch") } catch {}
        let requests = await fixture.requests(); XCTAssertTrue(requests.isEmpty)
        _ = try await service.mailPage(folder: .inbox, remoteFolderID: "custom")
        let fetched = await fixture.requests()
        XCTAssertEqual(fetched.last?.url?.path, "/v1.0/me/mailFolders/custom/messages")

    }
    func testGoogleMoveRetainsUnrelatedLabelsAndRemovesSource() async throws {
        let (service, fixture, account) = try await client(.google, replies: [.init(method: "POST", path: "/gmail/v1/users/me/messages/message/modify")])
        let source = MailboxFolder(accountID: account.id, remoteID: "old", name: "Old")
        try await service.move(message(account), toMailbox: MailboxFolder(accountID: account.id, remoteID: "new", name: "New"), from: source)
        let requests = await fixture.requests(), body = try HTTP.object(requests[0].httpBody!)
        XCTAssertEqual(body["addLabelIds"] as? [String], ["new"])
        XCTAssertTrue((body["removeLabelIds"] as? [String] ?? []).contains("old"))
        XCTAssertTrue((body["removeLabelIds"] as? [String] ?? []).contains("INBOX"))
        XCTAssertFalse((body["removeLabelIds"] as? [String] ?? []).contains("unrelated"))
    }
    func testRuleRequiresConditionsAndNeverForwardsToThirdParties() throws {
        var rule = RoutingRule(accountID: "fixture", name: "Clientes", destinationID: "folder")
        XCTAssertThrowsError(try rule.validated())
        rule.sender = "client@example.com"; rule.recipient = "team@example.com"; rule.subject = "Contrato"; rule.body = "validar"
        XCTAssertNoThrow(try rule.validated())
        let graph = RuleEncoding.microsoft(rule, sequence: 8)
        XCTAssertEqual(graph.object("actions").string("moveToFolder"), "folder")
        XCTAssertNil(graph.object("actions")["forwardTo"])
        XCTAssertEqual(graph.object("conditions").keys.count, 4)
        let gmail = RuleEncoding.google(rule)
        XCTAssertNil(gmail.object("action")["forward"])
        XCTAssertEqual(gmail.object("action")["removeLabelIds"] as? [String], ["INBOX"])
    }
    func testGoogleRuleCreatesServerFilterForFutureMail() async throws {
        let (service, fixture, account) = try await client(.google, replies: [
            .init(method: "GET", path: "/gmail/v1/users/me/labels", json: ["labels": [["id": "dest", "name": "Clientes", "type": "user"]]]),
            .init(method: "GET", path: "/gmail/v1/users/me/labels/dest", json: ["messagesUnread": 0, "messagesTotal": 0]),
            .init(method: "GET", path: "/gmail/v1/users/me/settings/filters", json: [:]),
            .init(method: "POST", path: "/gmail/v1/users/me/settings/filters", json: ["id": "filter-1"])
        ])
        let rule = RoutingRule(accountID: account.id, name: "Clientes", sender: "client@example.com", subject: "Contrato", destinationID: "dest")
        let created = try await service.createRoutingRule(rule)
        XCTAssertEqual(created.id, "filter-1")
        let requests = await fixture.requests(); XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertFalse(requests.contains { $0.url!.path.contains("messages") })
    }
    func testAutoReplyConcurrentChangePreventsOverwrite() async throws {
        let original: JSONObject = ["enableAutoReply": false, "responseSubject": "A", "responseBodyPlainText": "Original"]
        let updated: JSONObject = ["enableAutoReply": true, "responseSubject": "Other", "responseBodyPlainText": "Changed elsewhere"]
        let (service, fixture, _) = try await client(.google, replies: [.init(method: "GET", path: vacationPath, json: original), .init(method: "GET", path: vacationPath, json: updated)])
        var desired = try await service.autoReplies(); desired.enabled = true; desired.internalMessage = "My response"
        do { _ = try await service.saveAutoReplies(desired); XCTFail("Must not overwrite concurrent edit") } catch OrbitaError.invalidData {} catch { XCTFail("Wrong error") }
        let requests = await fixture.requests(); XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" })
    }
    func testAutoReplyTimeoutReconcilesWithReadWithoutRepeatingWrite() async throws {
        let off: JSONObject = ["enableAutoReply": false, "responseSubject": "Away", "responseBodyPlainText": "Returning soon"]
        let on: JSONObject = ["enableAutoReply": true, "responseSubject": "Away", "responseBodyPlainText": "Returning soon"]
        let (service, fixture, _) = try await client(.google, replies: [
            .init(method: "GET", path: vacationPath, json: off), .init(method: "GET", path: vacationPath, json: off),
            .init(method: "PUT", path: vacationPath, failure: true), .init(method: "GET", path: vacationPath, json: on)
        ])
        var desired = try await service.autoReplies(); desired.enabled = true
        let saved = try await service.saveAutoReplies(desired)
        XCTAssertTrue(saved.enabled)
        let requests = await fixture.requests(); XCTAssertEqual(requests.filter { $0.httpMethod == "PUT" }.count, 1)
    }
    func testMicrosoftAutoReplyEscapesMessageAndKeepsExternalAudienceDisabled() async throws {
        let path = "/v1.0/me/mailboxSettings/automaticRepliesSetting"
        let off: JSONObject = ["status": "disabled", "internalReplyMessage": "", "externalReplyMessage": "", "externalAudience": "none"]
        let on: JSONObject = ["status": "alwaysEnabled", "internalReplyMessage": "&lt;script&gt;literal&lt;/script&gt;", "externalReplyMessage": "", "externalAudience": "none"]
        let (service, fixture, _) = try await client(.microsoft, replies: [.init(method: "GET", path: path, json: off), .init(method: "GET", path: path, json: off), .init(method: "PATCH", path: "/v1.0/me/mailboxSettings"), .init(method: "GET", path: path, json: on)])
        var desired = try await service.autoReplies(); desired.enabled = true; desired.internalMessage = "<script>literal</script>"
        _ = try await service.saveAutoReplies(desired)
        let requests = await fixture.requests(), patch = try HTTP.object(requests.first { $0.httpMethod == "PATCH" }!.httpBody!).object("automaticRepliesSetting")
        XCTAssertEqual(patch.string("externalAudience"), "none")
        XCTAssertEqual(patch.string("internalReplyMessage"), "&lt;script&gt;literal&lt;/script&gt;")
    }
    func testAutoReplyDatesAndExternalBodiesAreValidated() {
        var value = AutoReplySettings(); value.enabled = true; value.internalMessage = "Returning soon"; value.scheduled = true
        value.end = value.start.addingTimeInterval(-1)
        XCTAssertThrowsError(try value.validated(provider: .google))
        value.hasEnd = false
        XCTAssertNoThrow(try value.validated(provider: .google))
        XCTAssertThrowsError(try value.validated(provider: .microsoft))
        value.scheduled = false; value.externalAudience = "all"
        XCTAssertThrowsError(try value.validated(provider: .microsoft))
    }
    func testSignatureIsASeparateDraftSnapshotAndAppearsOnceInMIME() throws {
        var draft = MailDraft(accountID: "fixture"); draft.to = "local@example.com"; draft.text = "Message"; draft.signatureText = "Fixture signature"; draft.signatureID = "signature"
        let parsed = try InternetMessage.parse(MIME.message(draft, from: "fixture@example.com"))
        XCTAssertEqual(parsed.text.components(separatedBy: "Fixture signature").count - 1, 1)
        XCTAssertEqual(draft.text, "Message")
        let restored = try JSONDecoder().decode(MailDraft.self, from: JSONEncoder().encode(draft))
        XCTAssertEqual(restored.composedText, draft.composedText)
        var legacy = try HTTP.object(JSONEncoder().encode(draft)); legacy.removeValue(forKey: "signatureID"); legacy.removeValue(forKey: "signatureText")
        XCTAssertNil(try JSONDecoder().decode(MailDraft.self, from: JSONSerialization.data(withJSONObject: legacy)).signatureText)
    }
    func testEWSRuleCreationNeverRemovesOutlookClientRules() async throws {
        let account = Account(provider: .exchange, email: "fixture@example.com", name: "Fixture", clientID: "")
        var config = MailServerConfiguration(); config.ewsURL = "https://exchange.example.com/EWS/Exchange.asmx"; config.username = account.email
        let rule = RoutingRule(id: "unique", accountID: account.id, name: "Fixture", sender: "a&b@example.com", subject: "A < B", destinationID: "target")
        func xml(_ body: String) -> Data { Data(("<Response><ResponseCode>NoError</ResponseCode>" + body + "</Response>").utf8) }
        let fixture = OrganizationWire([xml("<InboxRules/>"), xml(""), xml("<InboxRules><Rule><RuleId>created</RuleId><DisplayName>\(MailXML.escape(rule.serverName))</DisplayName><Priority>1</Priority><IsEnabled>true</IsEnabled><Conditions/><Actions/></Rule></InboxRules>")])
        let service = try EWSClient(account: account, configuration: config, credentials: { ServerCredentials(password: "synthetic") }, wire: { try await fixture.send($0) })
        let created = try await service.createRoutingRule(rule); XCTAssertEqual(created.id, "created")
        let requests = await fixture.requests(), body = String(decoding: requests[1].upload!, as: UTF8.self)
        XCTAssertTrue(body.contains("<m:RemoveOutlookRuleBlob>false</m:RemoveOutlookRuleBlob>"))
        XCTAssertFalse(body.contains("<m:RemoveOutlookRuleBlob>true"))
        XCTAssertTrue(body.contains("a&amp;b@example.com")); XCTAssertTrue(body.contains("A &lt; B"))
    }
}
