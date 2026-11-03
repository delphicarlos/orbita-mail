import Foundation

struct DAVObjectIdentity: Codable {
    var href: String
    var uid: String
    var recurrence: String
    var encoded: String { try! JSONEncoder().encode(self).base64URL }
    static func parse(_ raw: String) throws -> Self {
        guard let data = Data(base64URL: raw), let value = try? JSONDecoder().decode(Self.self, from: data), !value.uid.isEmpty else { throw OrbitaError.invalidData("Identificação CalDAV inválida.") }
        return value
    }
}
struct DAVReply {
    var headers: [String: String]
    var body: Data
    static func parse(_ data: Data) throws -> Self {
        var remaining = data, finalHeaders: [String: String] = [:], status = 0
        while remaining.starts(with: Data("HTTP/".utf8)), let end = remaining.range(of: Data("\r\n\r\n".utf8)) {
            let text = String(decoding: remaining[..<end.lowerBound], as: UTF8.self), lines = text.components(separatedBy: "\r\n")
            status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            finalHeaders = [:]
            for line in lines.dropFirst() {
                guard let index = line.firstIndex(of: ":") else { continue }
                finalHeaders[String(line[..<index]).lowercased()] = line[line.index(after: index)...].trimmingCharacters(in: .whitespaces)
            }
            remaining = remaining.subdata(in: end.upperBound..<remaining.endIndex)
        }
        guard (200..<300).contains(status) else { throw OrbitaError.network(status, status == 412 ? "O calendário foi alterado no servidor. Atualize antes de tentar novamente." : "O servidor CalDAV não confirmou a operação.") }
        return DAVReply(headers: finalHeaders, body: remaining)
    }
}
struct CalDAVClient: Sendable {
    let account: Account
    let configuration: MailServerConfiguration
    let credentials: @Sendable () async throws -> ServerCredentials
    let wire: MailWireTransport
    let endpoint: URL
    init(account: Account, configuration: MailServerConfiguration, credentials: @escaping @Sendable () async throws -> ServerCredentials, wire: @escaping MailWireTransport) throws {
        guard !configuration.caldavURL.isEmpty else { throw OrbitaError.invalidData("Esta conta usa somente email. Configure CalDAV para adicionar agenda e tarefas, se o provedor oferecer esse serviço.") }
        self.account = account; self.configuration = configuration; self.credentials = credentials; self.wire = wire
        endpoint = try MailServerConfiguration.secureWebURL(configuration.caldavURL)
    }
    func resolve(_ href: String) throws -> URL {
        guard let url = URL(string: href, relativeTo: endpoint)?.absoluteURL, url.scheme == "https", url.user == nil, url.password == nil,
              url.host?.lowercased() == endpoint.host?.lowercased(), (url.port ?? 443) == (endpoint.port ?? 443), url.fragment == nil else {
            throw OrbitaError.invalidData("O CalDAV apontou para outro servidor. Informe a URL correta manualmente; a senha não foi encaminhada.")
        }
        return url
    }
    func request(_ url: URL, method: String, xml: String? = nil, data: Data? = nil, headers: [String] = []) async throws -> DAVReply {
        _ = try resolve(url.absoluteString)
        let secret = try await credentials()
        let body = data ?? xml.map { Data($0.utf8) }
        let content = data == nil ? "application/xml; charset=utf-8" : "text/calendar; charset=utf-8"
        let response = try await wire(MailWireRequest(url: url,
            username: configuration.sameCalDAVAuthentication ? configuration.username : configuration.caldavUsername,
            password: configuration.sameCalDAVAuthentication ? secret.password : secret.caldavPassword,
            upload: body, headers: ["Content-Type: " + content, "Expect:"] + headers, method: method, includeHeaders: true))
        return try DAVReply.parse(response)
    }
    func propfind(_ url: URL, properties: String, depth: Int = 0) async throws -> MailXMLNode {
        let xml = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop>\(properties)</d:prop></d:propfind>"
        let root = try await MailXML.parse(request(url, method: "PROPFIND", xml: xml, headers: ["Depth: \(depth)"]).body)
        guard !root.descendants("multistatus").isEmpty else { throw OrbitaError.invalidData("O endereço não retornou uma coleção CalDAV válida.") }
        return root
    }
    func prop(_ response: MailXMLNode) -> MailXMLNode? {
        response.children.first { $0.name == "propstat" && $0.value("status").contains(" 200 ") }?.child("prop")
    }
    func home() async throws -> URL {
        let root = try await propfind(endpoint, properties: "<d:resourcetype/><d:current-user-principal/><c:calendar-home-set/>")
        for response in root.descendants("response") {
            guard let prop = prop(response) else { continue }
            if prop.child("resourcetype")?.child("calendar") != nil { return endpoint }
            if let href = prop.child("calendar-home-set")?.child("href")?.text { return try resolve(href) }
            if let href = prop.child("current-user-principal")?.child("href")?.text {
                let principal = try resolve(href)
                let details = try await propfind(principal, properties: "<c:calendar-home-set/>")
                if let target = details.descendants("calendar-home-set").first?.child("href")?.text { return try resolve(target) }
            }
        }
        // A calendar-home URL itself may omit principal discovery but still support Depth 1.
        return endpoint
    }
    func verify() async throws -> Bool {
        _ = try await sources(kind: .event)
        let options = try? await request(endpoint, method: "OPTIONS")
        return options?.headers["dav"]?.lowercased().contains("calendar-schedule") == true
    }
    func sources(kind: AgendaKind) async throws -> [AgendaSource] {
        let home = try await home()
        let root = try await propfind(home, properties: "<d:resourcetype/><d:displayname/><d:current-user-privilege-set/><c:supported-calendar-component-set/>", depth: 1)
        var values: [AgendaSource] = []
        for response in root.descendants("response") {
            guard let prop = prop(response), prop.child("resourcetype")?.child("calendar") != nil,
                  let href = response.child("href")?.text else { continue }
            let components = prop.child("supported-calendar-component-set")?.children.compactMap { $0.attributes["name"] } ?? ["VEVENT"]
            guard components.contains(kind == .event ? "VEVENT" : "VTODO") else { continue }
            let url = try resolve(href.trimmingCharacters(in: .whitespacesAndNewlines))
            let rights = prop.child("current-user-privilege-set")
            let editable = rights?.descendants("write-content").isEmpty == false || rights?.descendants("write").isEmpty == false || rights?.descendants("all").isEmpty == false
            values.append(AgendaSource(accountID: account.id, remoteID: url.absoluteString,
                name: prop.value("displayname").nilIfEmpty ?? url.lastPathComponent, kind: kind, canEdit: editable))
        }
        return values
    }
    func agenda(source: AgendaSource, interval: DateInterval) async throws -> [AgendaItem] {
        let url = try resolve(source.remoteID), event = source.kind == .event
        let expand = event ? "<c:expand start=\"\(ICalendar.utc(interval.start))\" end=\"\(ICalendar.utc(interval.end))\"/>" : ""
        let range = event ? "<c:time-range start=\"\(ICalendar.utc(interval.start))\" end=\"\(ICalendar.utc(interval.end))\"/>" : ""
        let xml = "<?xml version=\"1.0\"?><c:calendar-query xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\"><d:prop><d:getetag/><c:calendar-data>\(expand)</c:calendar-data></d:prop><c:filter><c:comp-filter name=\"VCALENDAR\"><c:comp-filter name=\"\(event ? "VEVENT" : "VTODO")\">\(range)</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>"
        let root = try await MailXML.parse(request(url, method: "REPORT", xml: xml, headers: ["Depth: 1"]).body)
        let responses = root.descendants("response")
        guard responses.count <= 10_000 else { throw OrbitaError.invalidData("O CalDAV retornou mais de 10 mil objetos.") }
        var result: [AgendaItem] = []
        for response in responses {
            guard let href = response.child("href")?.text, let calendar = prop(response)?.child("calendar-data") else { continue }
            let remote = try resolve(href)
            let root = try ICalendar.parse(Data(calendar.text.utf8))
            for component in root.children where component.name == (event ? "VEVENT" : "VTODO") {
                if event && !component.value("RRULE").isEmpty { throw OrbitaError.invalidData("O servidor CalDAV não expandiu as recorrências para o período. A fonte anterior foi preservada.") }
                if component.value("STATUS") == "CANCELLED" { continue }
                result.append(try item(component, href: remote.absoluteString, source: source))
            }
        }
        return result
    }
    func item(_ component: ICalendarComponent, href: String, source: AgendaSource) throws -> AgendaItem {
        let uid = component.value("UID")
        guard !uid.isEmpty else { throw OrbitaError.invalidData("Objeto CalDAV sem UID.") }
        let recurrence = component.value("RECURRENCE-ID")
        var item = AgendaItem(accountID: account.id, sourceID: source.remoteID, sourceName: source.name,
            remoteID: DAVObjectIdentity(href: href, uid: uid, recurrence: recurrence).encoded, kind: source.kind,
            title: ICalendar.text(component.value("SUMMARY")), canEdit: source.canEdit)
        if source.kind == .task {
            item.isCompleted = component.value("STATUS") == "COMPLETED"
            if let due = component.property("DUE") {
                let date = try ICalendar.date(due)
                item.day = date.1 ?? date.0.map(Time.dayKey)
            }
            return item
        }
        guard let start = component.property("DTSTART") else { throw OrbitaError.invalidData("Compromisso CalDAV sem início.") }
        let begin = try ICalendar.date(start); item.start = begin.0; item.day = begin.1
        if let finish = component.property("DTEND") { let end = try ICalendar.date(finish); item.end = end.0; item.endDay = end.1 }
        else if let day = item.day, !component.value("DURATION").isEmpty {
            guard let seconds = duration(component.value("DURATION")), seconds > 0, seconds.truncatingRemainder(dividingBy: 86400) == 0,
                  let begin = Time.dayDate(day), let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: Int(seconds / 86400), to: begin) else {
                throw OrbitaError.invalidData("Duração de dia inteiro CalDAV não suportada.")
            }
            item.endDay = Time.dayKey(end)
        } else if item.day == nil {
            // DURATION is valid iCalendar; refuse unsupported forms instead of inventing an end.
            if let duration = duration(component.value("DURATION")), let start = item.start { item.end = start.addingTimeInterval(duration) }
            else if component.value("DURATION").isEmpty { item.end = item.start }
            else { throw OrbitaError.invalidData("Duração CalDAV não suportada.") }
        }
        item.location = ICalendar.text(component.value("LOCATION")); item.iCalUID = uid
        let own = component.properties.first { $0.name == "ATTENDEE" && address($0.value).caseInsensitiveCompare(account.email) == .orderedSame }
        let organizer = address(component.value("ORGANIZER"))
        item.response = organizer.caseInsensitiveCompare(account.email) == .orderedSame ? "organizer" : ["ACCEPTED": "accepted", "TENTATIVE": "tentative", "DECLINED": "declined", "NEEDS-ACTION": "needsAction"][own?.parameters["PARTSTAT"] ?? "NEEDS-ACTION"] ?? "needsAction"
        item.canRespond = source.canEdit && configuration.caldavScheduling && own != nil && item.response != "organizer" && recurrence.isEmpty && component.value("RRULE").isEmpty && own?.parameters["SCHEDULE-AGENT"] != "CLIENT"
        return item
    }
    func address(_ value: String) -> String { value.lowercased().hasPrefix("mailto:") ? String(value.dropFirst(7)) : value }
    func duration(_ value: String) -> TimeInterval? {
        guard !value.isEmpty, let regex = try? NSRegularExpression(pattern: #"^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let scale: [Double] = [604800, 86400, 3600, 60, 1]
        let seconds: Double = (1...5).reduce(0) { total, group in
            guard let range = Range(match.range(at: group), in: value), let number = Double(value[range]) else { return total }
            return total + number * scale[group - 1]
        }
        guard seconds.isFinite, seconds >= 0, seconds <= 3_155_760_000, value != "P", value != "PT" else { return nil }
        return seconds
    }
    func mutate(_ item: AgendaItem, change: (ICalendarComponent) throws -> Void) async throws -> AgendaItem {
        let id = try DAVObjectIdentity.parse(item.remoteID), url = try resolve(id.href)
        let response = try await request(url, method: "GET")
        guard let etag = response.headers["etag"], !etag.isEmpty, !MailServerConfiguration.hasControls(etag) else { throw OrbitaError.invalidData("O CalDAV não forneceu ETag. Atualize; nenhuma alteração foi enviada.") }
        let root = try ICalendar.parse(response.body)
        guard let component = root.children.first(where: { $0.value("UID") == id.uid && $0.value("RECURRENCE-ID") == id.recurrence }) else { throw OrbitaError.invalidData("Objeto CalDAV mudou. Atualize antes de alterar.") }
        try change(component)
        var headers = ["If-Match: " + etag]
        if let tag = response.headers["schedule-tag"], !MailServerConfiguration.hasControls(tag) { headers.append("If-Schedule-Tag-Match: " + tag) }
        _ = try await request(url, method: "PUT", data: root.serialized, headers: headers)
        let confirmed = try await ICalendar.parse(request(url, method: "GET").body)
        guard let updated = confirmed.children.first(where: { $0.value("UID") == id.uid && $0.value("RECURRENCE-ID") == id.recurrence }) else { throw OrbitaError.uncertain("O objeto CalDAV não foi confirmado após a alteração.") }
        let source = AgendaSource(accountID: item.accountID, remoteID: item.sourceID, name: item.sourceName, kind: item.kind, canEdit: item.canEdit)
        return try self.item(updated, href: id.href, source: source)
    }
    func complete(_ item: AgendaItem, completed: Bool) async throws -> AgendaItem {
        guard item.kind == .task, item.canEdit else { throw OrbitaError.invalidData("Esta tarefa CalDAV está disponível somente para leitura.") }
        let updated = try await mutate(item) {
            $0.set("STATUS", completed ? "COMPLETED" : "NEEDS-ACTION"); $0.set("PERCENT-COMPLETE", completed ? "100" : "0")
            $0.set("COMPLETED", completed ? ICalendar.utc(Date()) : nil)
        }
        guard updated.isCompleted == completed else { throw OrbitaError.uncertain("O servidor CalDAV não confirmou o estado da tarefa.") }
        return updated
    }
    func respond(_ item: AgendaItem, response: InvitationResponse) async throws -> AgendaItem {
        guard item.kind == .event, item.canRespond else { throw OrbitaError.invalidData("Resposta automática indisponível: o CalDAV precisa oferecer agendamento e o convite deve ser individual, sem recorrência.") }
        do {
            let result = try await mutate(item) { component in
                guard component.value("RRULE").isEmpty, component.value("RECURRENCE-ID").isEmpty,
                      let index = component.properties.firstIndex(where: { $0.name == "ATTENDEE" && self.address($0.value).caseInsensitiveCompare(account.email) == .orderedSame }),
                      component.properties[index].parameters["SCHEDULE-AGENT"] != "CLIENT" else { throw OrbitaError.invalidData("O convite CalDAV não permite esta resposta automática.") }
                component.properties[index].parameters["PARTSTAT"] = response.rawValue.uppercased()
                component.properties[index].parameters["RSVP"] = "FALSE"
            }
            guard result.response == response.rawValue else { throw OrbitaError.uncertain("O CalDAV ainda não confirmou a resposta.") }
            return result
        } catch let error as OrbitaError {
            switch error { case .network(let status, _) where [400, 401, 403, 404, 409, 412, 429].contains(status): throw error
            case .invalidData, .authentication: throw error
            default: throw OrbitaError.uncertain("A resposta CalDAV não foi confirmada. Confira o organizador antes de repetir.") }
        } catch { throw OrbitaError.uncertain("A resposta CalDAV não foi confirmada. Confira o organizador antes de repetir.") }
    }
}
