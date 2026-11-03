import XCTest
@testable import OrbitaCore

private actor WireFixture {
    var replies: [Data]
    var captured: [MailWireRequest] = []
    let rejectTOP: Bool
    init(_ replies: [Data], rejectTOP: Bool = false) { self.replies = replies; self.rejectTOP = rejectTOP }
    func send(_ request: MailWireRequest) throws -> Data {
        captured.append(request)
        if rejectTOP && request.command?.hasPrefix("TOP ") == true { throw POPHeaderUnsupported() }
        guard !replies.isEmpty else { throw OrbitaError.invalidData("Unexpected fixture request") }
        return replies.removeFirst()
    }
    func requests() -> [MailWireRequest] { captured }
}

final class ServerProviderTests: XCTestCase {
    private func config() -> MailServerConfiguration {
        var value = MailServerConfiguration(); value.username = "fixture@example.com"
        value.incomingHost = "imap.example.com"; value.smtpHost = "smtp.example.com"
        value.ewsURL = "https://exchange.example.com/EWS/Exchange.asmx"
        return value
    }
    private func client(_ provider: Provider, replies: [Data], configuration: MailServerConfiguration? = nil, rejectTOP: Bool = false) async throws -> (StandardMailClient, WireFixture, Account) {
        let config = configuration ?? config()
        let account = Account(provider: provider, email: "fixture@example.com", name: "Fixture", clientID: "", serverConfiguration: config)
        let vault = TokenVault(service: "br.com.intellitouch.orbita-tests." + UUID().uuidString)
        try await vault.save(ServerCredentials(password: "synthetic"), key: ServerCredentials.key(account.id))
        addTeardownBlock { try await vault.remove(key: ServerCredentials.key(account.id)) }
        let fixture = WireFixture(replies, rejectTOP: rejectTOP)
        return (StandardMailClient(account: account, configuration: config, vault: vault, wire: { try await fixture.send($0) }), fixture, account)
    }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func dav(_ body: String, status: Int = 200) -> Data { bytes("HTTP/1.1 \(status) Fixture\r\nETag: \"version-1\"\r\nSchedule-Tag: \"schedule-1\"\r\n\r\n" + body) }
    private func ews(_ content: String = "") -> Data { bytes("<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\"><s:Body><Response><ResponseCode>NoError</ResponseCode>\(content)</Response></s:Body></s:Envelope>") }
    private var invitation: String { """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Fixture//EN
    BEGIN:VEVENT
    UID:event-1
    DTSTART:20261103T120000Z
    DTEND:20261103T130000Z
    SUMMARY:Reunião
    ORGANIZER:mailto:organizer@example.com
    ATTENDEE;CN="Pessoa; convidada";PARTSTAT=NEEDS-ACTION;RSVP=TRUE:mailto:fixture@example.com
    ATTENDEE;PARTSTAT=TENTATIVE:mailto:other@example.com
    X-CUSTOM:preserve me
    END:VEVENT
    END:VCALENDAR
    """ }

    func testServerConfigurationRejectsCredentialsInURLsAndInvalidHosts() throws {
        for host in ["https://example.com", "user@example.com", "example.com/path", "example.com\ncommand", ""] {
            var value = config(); value.incomingHost = host
            XCTAssertThrowsError(try value.validated(provider: .imap))
        }
        for url in ["http://example.com/EWS", "https://user:secret@example.com/EWS", "https://example.com/?token=secret"] {
            var value = config(); value.ewsURL = url
            XCTAssertThrowsError(try value.validated(provider: .exchange))
        }
        var value = config(); value.caldavURL = "https://dav.example.com/"; value.sameCalDAVAuthentication = false; value.caldavUsername = "user:password"
        XCTAssertThrowsError(try value.validated(provider: .imap))
        XCTAssertNoThrow(try config().validated(provider: .imap))
    }
    func testLegacyOAuthAccountDecodesWithoutServerConfiguration() throws {
        let raw = bytes(#"{"id":"google:p@example.com","provider":"google","email":"p@example.com","name":"P","clientID":"client","colorIndex":0}"#)
        XCTAssertNil(try JSONDecoder().decode(Account.self, from: raw).serverConfiguration)
        for provider in [Provider.imap, .pop3, .exchange] {
            XCTAssertThrowsError(try OAuth.authorizationURL(provider: provider, clientID: "", redirect: "", state: "", verifier: ""))
            XCTAssertFalse(ProviderClient.allowed(URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!, provider: provider))
        }
    }
    func testCurlConfigRequiresTLSAndEscapesStdinCredentials() throws {
        let request = MailWireRequest(url: URL(string: "smtps://smtp.example.com:465")!, username: "fixture", password: #"a\b"c"#)
        let options = try CurlMailTransport.options(request, uploadPath: nil)
        XCTAssertTrue(options.contains("ssl-reqd")); XCTAssertFalse(options.contains("insecure")); XCTAssertTrue(options.contains(#"a\\b\"c"#))
        XCTAssertThrowsError(try CurlMailTransport.quote("secret\nurl=attacker"))
    }
    func testMIMEParsesEncodingAlternativeAndAttachmentBytes() throws {
        var draft = MailDraft(accountID: "fixture"); draft.to = "local@example.com"; draft.subject = "Reunião amanhã"; draft.text = "Olá!\nAmanhã"
        draft.attachments = [OutgoingAttachment(name: "teste.bin", mimeType: "application/octet-stream", data: Data([0, 255, 13, 10, 42]))]
        let parsed = try InternetMessage.parse(MIME.message(draft, from: "fixture@example.com"))
        XCTAssertEqual(InternetMessage.decodedHeader(parsed.headers["subject"]!), draft.subject)
        XCTAssertTrue(parsed.text.contains("Amanhã")); XCTAssertEqual(parsed.attachments.first?.data, draft.attachments[0].data)
        XCTAssertEqual(InternetMessage.decodedHeader("=?ISO-8859-1?Q?Ol=E1_mundo?="), "Olá mundo")
    }
    func testIMAPLiteralFramingIgnoresFakeTaggedResponsesAndLateUID() throws {
        let literal = bytes("Subject: Fixture\r\n\r\nORBFETCH OK fake\r\n* 9 FETCH (UID 999)\r\n\u{0}tail")
        let response = bytes("* 1 FETCH (BODY[] {\(literal.count)}\r\n") + literal + bytes(" UID 7 FLAGS (\\Seen))\r\nORBFETCH OK done\r\n")
        XCTAssertEqual(try NativeIMAPTransport.responseEnd(response, tag: "ORBFETCH"), response.count)
        XCTAssertNil(try NativeIMAPTransport.responseEnd(Data(response.dropLast(8)), tag: "ORBFETCH"))
        let fetch = try XCTUnwrap(IMAPReply.fetches(response).first)
        XCTAssertEqual(fetch.uid, 7); XCTAssertEqual(fetch.literal, literal); XCTAssertEqual(fetch.flags, "\\Seen")
        XCTAssertThrowsError(try IMAPReply.fetches(bytes("* 1 FETCH (UID 7 BODY[] {99}\r\nshort")))
    }
    func testIMAPMailboxNamesRoundTripAndStableIdentity() throws {
        let name = "Clientes & São Paulo/日本"
        XCTAssertEqual(IMAPReply.decodeMailbox(IMAPReply.encodeMailbox(name)), name)
        let id = IMAPIdentity(folder: name, validity: 50, uid: 7)
        XCTAssertEqual(try IMAPIdentity.parse(id.encoded).folder, name)
        XCTAssertThrowsError(try IMAPIdentity.parse("invalid"))
    }
    func testIMAPPageUsesPeekAndRejectsChangedMailboxBeforeSearch() async throws {
        let literal = bytes("From: person@example.com\r\nSubject: Fixture\r\nDate: Tue, 03 Nov 2026 12:00:00 +0000\r\n\r\n")
        let fetch = bytes("* 1 FETCH (UID 7 FLAGS (\\Seen) BODY[HEADER] {\(literal.count)}\r\n") + literal + bytes(")\r\n")
        let (service, fixture, _) = try await client(.imap, replies: [bytes("* STATUS INBOX (UIDVALIDITY 50)\r\n"),bytes("* SEARCH 7\r\n"),fetch,bytes("* STATUS INBOX (UIDVALIDITY 51)\r\n")])
        let page = try await service.mailPage(folder: .inbox, cursor: nil)
        XCTAssertEqual(page.messages.count, 1); XCTAssertTrue(page.messages[0].isRead)
        do { _ = try await service.mailPage(folder: .inbox, cursor: IMAPIdentity(folder: "INBOX", validity: 50, uid: 7).encoded); XCTFail("Mailbox changed") } catch {}
        let requests = await fixture.requests()
        XCTAssertEqual(requests.count, 4); XCTAssertTrue(requests[2].command!.contains("BODY.PEEK")); XCTAssertTrue(requests[2].url.absoluteString.contains("UIDVALIDITY=50"))
    }
    func testSMTPBccIsEnvelopeOnlyAndSentCopyFailureIsUncertain() async throws {
        var config = config(); config.saveSentCopy = false
        let (service, fixture, account) = try await client(.imap, replies: [Data()], configuration: config)
        var draft = MailDraft(accountID: account.id); draft.to = "local@example.com"; draft.bcc = "hidden@example.com"; draft.text = "Private"
        try await service.send(draft)
        let sent = await fixture.requests()[0]
        XCTAssertEqual(sent.recipients, ["local@example.com", "hidden@example.com"])
        XCTAssertFalse(String(decoding: sent.upload!, as: UTF8.self).contains("hidden@example.com"))
        let (copying, capture, _) = try await client(.imap, replies: [Data()])
        do { try await copying.send(draft); XCTFail("Expected uncertain copy") } catch OrbitaError.uncertain {} catch { XCTFail("Wrong error \(error)") }
        let requests = await capture.requests(); XCTAssertEqual(requests.count, 2)
    }
    func testPOPRejectsChangedSequenceWithoutDeletingMessages() async throws {
        let (service, fixture, _) = try await client(.pop3, replies: [bytes("1 original\r\n"),bytes("Subject: Other\r\n\r\n"),bytes("1 replacement\r\n")])
        do { _ = try await service.mailPage(folder: .inbox, cursor: nil); XCTFail("Changed POP sequence") } catch {}
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 3)
        XCTAssertFalse(requests.contains { $0.command?.contains("DELE") == true })
    }
    func testXMLRejectsEntityExpansion() {
        XCTAssertThrowsError(try MailXML.parse(bytes("<!DOCTYPE x [<!ENTITY private SYSTEM 'file:///etc/passwd'>]><x>&private;</x>")))
    }
    func testEWSUsesNTLMAndVersionedNeverOverwriteUpdates() async throws {
        let (service, fixture, account) = try await client(.exchange, replies: [ews("<Items><Message><ItemId Id=\"item\" ChangeKey=\"version&amp;1\"/></Message></Items>"),ews()])
        let message = MailMessage(remoteID: "item", accountID: account.id, subject: "Fixture", sender: "p@example.com", to: [], date: Date(), preview: "")
        try await service.setFlag(message, flag: "\\Seen", enabled: true)
        let requests = await fixture.requests()
        XCTAssertTrue(requests.allSatisfy(\.ntlm)); XCTAssertEqual(requests.count, 2)
        let body = String(decoding: requests[1].upload!, as: UTF8.self)
        XCTAssertTrue(body.contains("NeverOverwrite")); XCTAssertTrue(body.contains("ChangeKey=\"version&amp;1\"")); XCTAssertTrue(body.contains("<t:IsRead>true"))
    }
    func testCalendarRoundTripPreservesUnknownPropertiesAndUnicodeFolding() throws {
        let root = try ICalendar.parse(bytes(invitation))
        root.children[0].set("DESCRIPTION", String(repeating: "ação ", count: 50))
        let serialized = root.serialized
        for line in String(decoding: serialized, as: UTF8.self).components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75) }
        let again = try ICalendar.parse(serialized)
        XCTAssertEqual(again.children[0].value("X-CUSTOM"), "preserve me")
        XCTAssertEqual(again.children[0].value("DESCRIPTION"), String(repeating: "ação ", count: 50))
        XCTAssertEqual(again.children[0].properties.first { $0.name == "ATTENDEE" }?.parameters["CN"], "\"Pessoa; convidada\"")
    }
    func testCalDAVResponsePreservesParticipantsAndUsesETag() async throws {
        var config = config(); config.caldavURL = "https://dav.example.com/calendar/"; config.caldavScheduling = true
        let accepted = invitation.replacingOccurrences(of: "PARTSTAT=NEEDS-ACTION;RSVP=TRUE", with: "PARTSTAT=ACCEPTED;RSVP=FALSE")
        let (service, fixture, account) = try await client(.imap, replies: [dav(invitation),dav("", status: 204),dav(accepted)], configuration: config)
        let dav = try service.dav(), component = try ICalendar.parse(bytes(invitation)).children[0]
        let item = try dav.item(component, href: "/calendar/event.ics", source: AgendaSource(accountID: account.id, remoteID: config.caldavURL, name: "Calendar", kind: .event))
        XCTAssertTrue(item.canRespond)
        let changed = try await dav.respond(item, response: .accepted); XCTAssertEqual(changed.response, "accepted")
        let requests = await fixture.requests(); XCTAssertEqual(requests.map(\.method), ["GET", "PUT", "GET"])
        XCTAssertTrue(requests[1].headers.contains("If-Match: \"version-1\""))
        let body = try ICalendar.parse(requests[1].upload!).children[0]
        XCTAssertEqual(body.value("X-CUSTOM"), "preserve me")
        XCTAssertEqual(body.properties.first { $0.value == "mailto:other@example.com" }?.parameters["PARTSTAT"], "TENTATIVE")
    }
    func testCalDAVConflictNeverRepeatsWriteOrForwardsCredentials() async throws {
        var config = config(); config.caldavURL = "https://dav.example.com/calendar/"; config.caldavScheduling = true
        let (service, fixture, account) = try await client(.imap, replies: [dav(invitation),dav("", status: 412)], configuration: config)
        let dav = try service.dav()
        XCTAssertThrowsError(try dav.resolve("https://attacker.example/event.ics"))
        let item = try dav.item(ICalendar.parse(bytes(invitation)).children[0], href: "/calendar/event.ics", source: AgendaSource(accountID: account.id, remoteID: config.caldavURL, name: "Calendar", kind: .event))
        do { _ = try await dav.respond(item, response: .accepted); XCTFail("Expected conflict") } catch OrbitaError.network(let status, _) { XCTAssertEqual(status, 412) }
        let requests = await fixture.requests(); XCTAssertEqual(requests.count, 2)
    }

    func testEWSInvitationAcceptWritesOnceAndConfirmsRemoteResponse() async throws {
        func event(_ response: String) -> Data {
            ews("<Items><CalendarItem><ItemId Id=\"event\" ChangeKey=\"v1\"/><Subject>Meeting</Subject><Start>2026-11-03T12:00:00Z</Start><End>2026-11-03T13:00:00Z</End><IsMeeting>true</IsMeeting><IsOrganizer>false</IsOrganizer><MyResponseType>\(response)</MyResponseType></CalendarItem></Items>")
        }
        let (service, fixture, account) = try await client(.exchange, replies: [event("NoResponseReceived"),ews(),event("Accept")])
        let item = AgendaItem(accountID: account.id, sourceID: "calendar", sourceName: "Calendar", remoteID: "event", kind: .event, title: "Meeting", canRespond: true)
        let result = try await service.ews().respond(item, response: .accepted)
        XCTAssertEqual(result.response, "accepted")
        let requests = await fixture.requests()
        XCTAssertEqual(requests.count, 3)
        let writes = requests.filter { String(decoding: $0.upload!, as: UTF8.self).contains("<m:CreateItem") }
        XCTAssertEqual(writes.count, 1)
        XCTAssertTrue(String(decoding: writes[0].upload!, as: UTF8.self).contains("<t:AcceptItem><t:ReferenceItemId Id=\"event\" ChangeKey=\"v1\""))
    }
    func testCalDAVTaskCompletionPreservesOtherPropertiesAndConfirms() async throws {
        let task = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VTODO\r\nUID:task-1\r\nSUMMARY:Task\r\nDUE;VALUE=DATE:20261103\r\nSTATUS:NEEDS-ACTION\r\nX-CUSTOM:keep\r\nEND:VTODO\r\nEND:VCALENDAR\r\n"
        var config = config(); config.caldavURL = "https://dav.example.com/calendar/"
        let (service, fixture, account) = try await client(.imap, replies: [dav(task),dav("", status: 204),dav(task.replacingOccurrences(of: "NEEDS-ACTION", with: "COMPLETED"))], configuration: config)
        let dav = try service.dav()
        let source = AgendaSource(accountID: account.id, remoteID: config.caldavURL, name: "Tasks", kind: .task)
        let item = try dav.item(ICalendar.parse(bytes(task)).children[0], href: "/calendar/task.ics", source: source)
        XCTAssertEqual(item.day, "2026-11-03")
        let completed = try await dav.complete(item, completed: true)
        XCTAssertTrue(completed.isCompleted)
        let requests = await fixture.requests()
        let changed = try ICalendar.parse(requests[1].upload!).children[0]
        XCTAssertEqual(changed.value("X-CUSTOM"), "keep"); XCTAssertEqual(changed.value("PERCENT-COMPLETE"), "100")
    }
    func testCalDAVAllDayDurationAndRecurringInvitationLimit() async throws {
        var config = config(); config.caldavURL = "https://dav.example.com/calendar/"; config.caldavScheduling = true
        let (service, _, account) = try await client(.imap, replies: [], configuration: config)
        let root = try ICalendar.parse(bytes(invitation)), event = root.children[0]
        event.set("DTSTART", "20261103"); event.set("DTEND", nil); event.set("DURATION", "P2D")
        let source = AgendaSource(accountID: account.id, remoteID: config.caldavURL, name: "Calendar", kind: .event)
        let dav = try service.dav(), item = try dav.item(event, href: "/calendar/event.ics", source: source)
        XCTAssertEqual(item.day, "2026-11-03"); XCTAssertEqual(item.endDay, "2026-11-05")
        event.set("RECURRENCE-ID", "20261103")
        XCTAssertFalse(try dav.item(event, href: "/calendar/event.ics", source: source).canRespond)
    }

    func testPOPHeaderFallbackReadsWithoutDeleting() async throws {
        let (service, fixture, _) = try await client(.pop3, replies: [bytes("1 stable\r\n"),bytes("Subject: Fixture\r\n\r\nbody"),bytes("1 stable\r\n")], rejectTOP: true)
        let page = try await service.mailPage(folder: .inbox, cursor: nil)
        XCTAssertEqual(page.messages.first?.subject, "Fixture")
        let requests = await fixture.requests()
        XCTAssertEqual(requests.compactMap(\.command), ["UIDL", "TOP 1 0", "RETR 1", "UIDL"])
    }
    func testMalformedMIMEAndOversizedLiteralAreRejected() {
        XCTAssertThrowsError(try InternetMessage.parse(bytes("Content-Type: multipart/mixed; boundary=x\r\n\r\n--x\r\nContent-Type: text/plain\r\n\r\ntruncated")))
        XCTAssertThrowsError(try NativeIMAPTransport.responseEnd(bytes("* 1 FETCH (BODY[] {99999999999999999999999999}\r\nORBFETCH OK fake\r\n"), tag: "ORBFETCH"))
    }

    func testEWSMailPageLoadsFullAddressesForReplies() async throws {
        let listing = ews("<RootFolder IncludesLastItemInRange=\"true\"><Items><Message><ItemId Id=\"mail\"/></Message></Items></RootFolder>")
        let detail = ews("<Items><Message><ItemId Id=\"mail\"/><From><Mailbox><Name>Sender</Name><EmailAddress>sender@example.com</EmailAddress></Mailbox></From><ToRecipients><Mailbox><EmailAddress>fixture@example.com</EmailAddress></Mailbox></ToRecipients><Subject>Fixture</Subject><Preview>Preview</Preview><DateTimeReceived>2026-11-03T12:00:00Z</DateTimeReceived></Message></Items>")
        let (service, fixture, _) = try await client(.exchange, replies: [listing,detail])
        let page = try await service.mailPage(folder: .inbox, cursor: nil)
        XCTAssertEqual(page.messages.first?.sender, "sender@example.com")
        XCTAssertEqual(page.messages.first?.to, ["fixture@example.com"])
        let requests = await fixture.requests()
        XCTAssertTrue(String(decoding: requests[1].upload!, as: UTF8.self).contains("<m:GetItem>"))
    }
}
