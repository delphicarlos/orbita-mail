import Foundation

final class MailXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [MailXMLNode] = []
    init(_ name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func child(_ name: String) -> MailXMLNode? { children.first { $0.name == name } }
    func value(_ name: String) -> String { child(name)?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    func descendants(_ name: String) -> [MailXMLNode] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
}
enum MailXML {
    private final class Reader: NSObject, XMLParserDelegate {
        let root = MailXMLNode("root")
        var stack: [MailXMLNode] = []
        var nodes = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            nodes += 1
            guard nodes <= 100_000, stack.count < 50 else { parser.abortParsing(); return }
            let node = MailXMLNode(elementName.components(separatedBy: ":").last!, attributes: attributeDict)
            (stack.last ?? root).children.append(node); stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { if !stack.isEmpty { stack.removeLast() } }
    }
    static func parse(_ bytes: Data) throws -> MailXMLNode {
        guard bytes.count <= 32_000_000 else { throw OrbitaError.invalidData("Resposta XML excede o limite desta versão.") }
        let prefix = String(decoding: bytes, as: UTF8.self).uppercased()
        guard !prefix.contains("<!DOCTYPE"), !prefix.contains("<!ENTITY") else { throw OrbitaError.invalidData("Declarações de entidade XML não são aceitas.") }
        let delegate = Reader(), parser = XMLParser(data: bytes)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw OrbitaError.invalidData("Resposta XML inválida ou excessivamente complexa.") }
        return delegate.root
    }
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
}

struct EWSClient: Sendable {
    let account: Account
    let configuration: MailServerConfiguration
    let credentials: @Sendable () async throws -> ServerCredentials
    let wire: MailWireTransport
    let endpoint: URL
    init(account: Account, configuration: MailServerConfiguration, credentials: @escaping @Sendable () async throws -> ServerCredentials, wire: @escaping MailWireTransport) throws {
        self.account = account; self.configuration = configuration; self.credentials = credentials; self.wire = wire
        endpoint = try MailServerConfiguration.secureWebURL(configuration.ewsURL)
        guard !["outlook.office365.com", "outlook.office.com"].contains(endpoint.host?.lowercased() ?? "") else {
            throw OrbitaError.invalidData("Para Exchange Online/Microsoft 365, use a conexão Microsoft por OAuth. EWS destina-se ao Exchange próprio que a TI disponibiliza.")
        }
    }
    static func field(_ name: String) -> String { "<t:FieldURI FieldURI=\"\(name)\"/>" }
    static func itemID(_ id: String, key: String? = nil) -> String {
        "<t:ItemId Id=\"\(MailXML.escape(id))\"" + (key.map { " ChangeKey=\"\(MailXML.escape($0))\"" } ?? "") + "/>"
    }
    func call(_ body: String) async throws -> MailXMLNode {
        let secret = try await credentials()
        let envelope = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types" xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"><s:Header><t:RequestServerVersion Version="Exchange2013_SP1"/><t:TimeZoneContext><t:TimeZoneDefinition Id="UTC"/></t:TimeZoneContext></s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
        let data = try await wire(MailWireRequest(url: endpoint, username: configuration.username, password: secret.password,
                                                 upload: Data(envelope.utf8), ntlm: configuration.ewsAuthentication == .ntlm,
                                                 headers: ["Content-Type: text/xml; charset=utf-8", "Accept: text/xml"], method: "POST"))
        let root = try MailXML.parse(data)
        let codes = root.descendants("ResponseCode").map(\.text)
        guard !codes.isEmpty else { throw OrbitaError.invalidData("O endereço não retornou uma confirmação EWS válida. Confira a URL com a TI.") }
        if let code = codes.first(where: { $0 != "NoError" }) {
            if ["ErrorAccessDenied", "ErrorInvalidClientAccessToken", "ErrorImpersonateUserDenied"].contains(code) { throw OrbitaError.authentication("O Exchange recusou acesso à operação (\(code)). Confira as permissões com a TI.") }
            if code.lowercased().contains("outlookruleblob") { throw OrbitaError.invalidData("O Exchange exige uma alteração nas regras locais do Outlook. O Órbita preservou essas regras; configure a regra no Outlook ou consulte a TI.") }
            throw OrbitaError.invalidData("O Exchange não concluiu a operação (\(code)). A cópia anterior foi preservada.")
        }
        return root
    }
    func verify() async throws {
        _ = try await call("<m:GetFolder><m:FolderShape><t:BaseShape>IdOnly</t:BaseShape></m:FolderShape><m:FolderIds><t:DistinguishedFolderId Id=\"inbox\"/></m:FolderIds></m:GetFolder>")
    }
    func folderID(_ folder: MailFolder) async throws -> String {
        if folder != .archive { return "<t:DistinguishedFolderId Id=\"\(folder.graphName)\"/>" }
        let root = try await folders()
        guard let found = root.first(where: { ["archive", "arquivo", "archives"].contains($0.value("DisplayName").lowercased()) }), let id = found.child("FolderId")?.attributes["Id"] else {
            throw OrbitaError.invalidData("Pasta Arquivo não encontrada neste Exchange. Nenhum item foi movido.")
        }
        return "<t:FolderId Id=\"\(MailXML.escape(id))\"/>"
    }
    func folders() async throws -> [MailXMLNode] {
        var offset = 0, result: [MailXMLNode] = []
        for _ in 0..<100 {
            let root = try await call("<m:FindFolder Traversal=\"Deep\"><m:FolderShape><t:BaseShape>Default</t:BaseShape><t:AdditionalProperties>\(Self.field("folder:FolderClass"))\(Self.field("folder:EffectiveRights"))</t:AdditionalProperties></m:FolderShape><m:IndexedPageFolderView MaxEntriesReturned=\"100\" Offset=\"\(offset)\" BasePoint=\"Beginning\"/><m:ParentFolderIds><t:DistinguishedFolderId Id=\"msgfolderroot\"/></m:ParentFolderIds></m:FindFolder>")
            guard let page = root.descendants("RootFolder").first, let folders = page.child("Folders") else { throw OrbitaError.invalidData("Lista de pastas EWS incompleta.") }
            result += folders.children
            if page.attributes["IncludesLastItemInRange"] == "true" { return result }
            guard let next = page.attributes["IndexedPagingOffset"].flatMap(Int.init), next > offset else { throw OrbitaError.invalidData("Paginação de pastas Exchange inválida.") }
            offset = next
        }
        throw OrbitaError.invalidData("Quantidade de pastas Exchange excede o limite de 10 mil.")
    }
    func mailPage(folder: MailFolder, cursor: String?, remoteFolderID: String? = nil) async throws -> MailPage {
        let offset = cursor.flatMap(Int.init) ?? 0
        guard offset >= 0, offset <= 1_000_000 else { throw OrbitaError.invalidData("Página Exchange inválida.") }
        let properties = ["item:Subject", "item:DateTimeReceived", "item:DateTimeSent", "item:HasAttachments", "item:ConversationId", "item:Preview", "message:From", "message:ToRecipients", "message:CcRecipients", "message:IsRead", "message:InternetMessageId", "item:Flag"].map(Self.field).joined()
        let parent: String
        if let remoteFolderID { parent = "<t:FolderId Id=\"\(MailXML.escape(remoteFolderID))\"/>" }
        else { parent = try await folderID(folder) }
        let root = try await call("<m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape><m:IndexedPageItemView MaxEntriesReturned=\"40\" Offset=\"\(offset)\" BasePoint=\"Beginning\"/><m:SortOrder><t:FieldOrder Order=\"Descending\">\(Self.field("item:DateTimeReceived"))</t:FieldOrder></m:SortOrder><m:ParentFolderIds>\(parent)</m:ParentFolderIds></m:FindItem>")
        guard let page = root.descendants("RootFolder").first, let items = page.child("Items") else { throw OrbitaError.invalidData("Lista de mensagens Exchange incompleta.") }
        // FindItem omits full mailbox addresses. Fetch the page's details in a
        // single GetItem batch so replies use actual sender/recipient addresses.
        let ids = try items.children.map { item -> String in
            guard let id = item.child("ItemId")?.attributes["Id"] else { throw OrbitaError.invalidData("Mensagem Exchange sem identificação.") }
            return id
        }
        let details: [MailXMLNode]
        if ids.isEmpty { details = [] }
        else {
            let loaded = try await call("<m:GetItem><m:ItemShape><t:BaseShape>IdOnly</t:BaseShape><t:AdditionalProperties>\(properties)</t:AdditionalProperties></m:ItemShape><m:ItemIds>\(ids.map { Self.itemID($0) }.joined())</m:ItemIds></m:GetItem>")
            details = loaded.descendants("Items").flatMap(\.children)
            guard Set(details.compactMap { $0.child("ItemId")?.attributes["Id"] }) == Set(ids) else { throw OrbitaError.invalidData("Detalhes de mensagens Exchange incompletos.") }
        }
        let values = try details.map { item -> MailMessage in
            guard let id = item.child("ItemId")?.attributes["Id"] else { throw OrbitaError.invalidData("Mensagem Exchange sem identificação.") }
            let sender = item.child("From")?.child("Mailbox")
            return MailMessage(remoteID: id, accountID: account.id, threadID: item.child("ConversationId")?.attributes["Id"] ?? "", subject: item.value("Subject"),
                               sender: sender?.value("EmailAddress") ?? "", senderName: sender?.value("Name") ?? "",
                               to: item.child("ToRecipients")?.children.map { $0.value("EmailAddress") } ?? [],
                               cc: item.child("CcRecipients")?.children.map { $0.value("EmailAddress") } ?? [],
                               date: Time.parse(item.value("DateTimeReceived")) ?? Time.parse(item.value("DateTimeSent")) ?? Date(timeIntervalSince1970: 0),
                               preview: item.value("Preview"), isRead: item.value("IsRead") == "true", isFlagged: item.child("Flag")?.value("FlagStatus") == "Flagged",
                               hasAttachments: item.value("HasAttachments") == "true", internetMessageID: item.value("InternetMessageId"))
        }
        let next = page.attributes["IncludesLastItemInRange"] == "true" ? nil : page.attributes["IndexedPagingOffset"]
        if let next { guard let number = Int(next), number > offset else { throw OrbitaError.invalidData("Paginação de mensagens Exchange inválida.") } }
        return MailPage(messages: values, nextCursor: next)
    }
    func get(_ id: String, mime: Bool = false) async throws -> MailXMLNode {
        let shape = mime ? "<t:BaseShape>IdOnly</t:BaseShape><t:IncludeMimeContent>true</t:IncludeMimeContent>" : "<t:BaseShape>AllProperties</t:BaseShape>"
        let root = try await call("<m:GetItem><m:ItemShape>\(shape)</m:ItemShape><m:ItemIds>\(Self.itemID(id))</m:ItemIds></m:GetItem>")
        guard let value = root.descendants("Items").first?.children.first else { throw OrbitaError.invalidData("Item Exchange não encontrado.") }
        return value
    }
    func raw(_ message: MailMessage) async throws -> Data {
        let item = try await get(message.remoteID, mime: true)
        guard let data = Data(base64Encoded: item.value("MimeContent"), options: .ignoreUnknownCharacters), !data.isEmpty else { throw OrbitaError.invalidData("O Exchange não retornou o conteúdo MIME.") }
        return data
    }
    func setFlag(_ message: MailMessage, flag: String, enabled: Bool) async throws {
        let current = try await get(message.remoteID)
        let field = flag == "\\Seen" ? "message:IsRead" : "item:Flag"
        let value = flag == "\\Seen" ? "<t:IsRead>\(enabled ? "true" : "false")</t:IsRead>" : "<t:Flag><t:FlagStatus>\(enabled ? "Flagged" : "NotFlagged")</t:FlagStatus></t:Flag>"
        try await update(current, field: field, type: "Message", value: value)
    }
    func update(_ item: MailXMLNode, field: String, type: String, value: String) async throws {
        guard let identity = item.child("ItemId"), let id = identity.attributes["Id"], let key = identity.attributes["ChangeKey"] else { throw OrbitaError.invalidData("O Exchange não forneceu a versão do item; atualize antes de alterar.") }
        _ = try await call("<m:UpdateItem ConflictResolution=\"NeverOverwrite\" MessageDisposition=\"SaveOnly\" SendMeetingInvitationsOrCancellations=\"SendToNone\"><m:ItemChanges><t:ItemChange>\(Self.itemID(id, key: key))<t:Updates><t:SetItemField>\(Self.field(field))<t:\(type)>\(value)</t:\(type)></t:SetItemField></t:Updates></t:ItemChange></m:ItemChanges></m:UpdateItem>")
    }
    func move(_ message: MailMessage, to folder: MailFolder) async throws {
        let destination = try await folderID(folder)
        _ = try await call("<m:MoveItem><m:ToFolderId>\(destination)</m:ToFolderId><m:ItemIds>\(Self.itemID(message.remoteID))</m:ItemIds></m:MoveItem>")
    }
    func send(_ draft: MailDraft) async throws {
        let raw = try MIME.message(draft, from: account.email)
        func recipients(_ value: String, tag: String) throws -> String {
            let addresses = try MailValidation.recipients(value)
            return addresses.isEmpty ? "" : "<t:\(tag)>" + addresses.map { "<t:Mailbox><t:EmailAddress>\(MailXML.escape($0))</t:EmailAddress></t:Mailbox>" }.joined() + "</t:\(tag)>"
        }
        let to = try recipients(draft.to, tag: "ToRecipients"), cc = try recipients(draft.cc, tag: "CcRecipients"), bcc = try recipients(draft.bcc, tag: "BccRecipients")
        _ = try await call("<m:CreateItem MessageDisposition=\"SendAndSaveCopy\"><m:SavedItemFolderId><t:DistinguishedFolderId Id=\"sentitems\"/></m:SavedItemFolderId><m:Items><t:Message><t:MimeContent CharacterSet=\"UTF-8\">\(raw.base64EncodedString())</t:MimeContent>\(to)\(cc)\(bcc)</t:Message></m:Items></m:CreateItem>")
    }
    func sources(kind: AgendaKind) async throws -> [AgendaSource] {
        try await folders().filter { $0.value("FolderClass").lowercased().hasPrefix(kind == .event ? "ipf.appointment" : "ipf.task") }.map {
            guard let id = $0.child("FolderId")?.attributes["Id"] else { throw OrbitaError.invalidData("Pasta de agenda Exchange sem identificação.") }
            return AgendaSource(accountID: account.id, remoteID: id, name: $0.value("DisplayName"), kind: kind, canEdit: $0.child("EffectiveRights")?.value("Modify") == "true")
        }
    }
    func agenda(source: AgendaSource, interval: DateInterval) async throws -> [AgendaItem] {
        var offset = 0, result: [AgendaItem] = []
        for _ in 0..<100 {
            let view = source.kind == .event
                ? "<m:CalendarView MaxEntriesReturned=\"1000\" StartDate=\"\(Time.iso(interval.start))\" EndDate=\"\(Time.iso(interval.end))\"/>"
                : "<m:IndexedPageItemView MaxEntriesReturned=\"100\" Offset=\"\(offset)\" BasePoint=\"Beginning\"/>"
            let fields = source.kind == .event ? ["calendar:Start", "calendar:End", "calendar:IsAllDayEvent", "calendar:IsMeeting", "calendar:IsOrganizer", "calendar:MyResponseType", "calendar:UID", "calendar:Location", "calendar:StartTimeZone", "calendar:EndTimeZone"] : ["task:DueDate", "task:IsComplete", "task:Status"]
            let root = try await call("<m:FindItem Traversal=\"Shallow\"><m:ItemShape><t:BaseShape>Default</t:BaseShape><t:AdditionalProperties>\(fields.map(Self.field).joined())</t:AdditionalProperties></m:ItemShape>\(view)<m:ParentFolderIds><t:FolderId Id=\"\(MailXML.escape(source.remoteID))\"/></m:ParentFolderIds></m:FindItem>")
            guard let page = root.descendants("RootFolder").first, let items = page.child("Items") else { throw OrbitaError.invalidData("Agenda Exchange incompleta.") }
            result += try items.children.map { try self.agendaItem($0, source: source) }
            if page.attributes["IncludesLastItemInRange"] == "true" { return result }
            guard source.kind == .task, let next = page.attributes["IndexedPagingOffset"].flatMap(Int.init), next > offset else { throw OrbitaError.invalidData("O intervalo contém eventos demais para a resposta Exchange. A fonte anterior foi preservada.") }
            offset = next
        }
        throw OrbitaError.invalidData("Lista Exchange maior que 10 mil tarefas.")
    }
    func agendaItem(_ value: MailXMLNode, source: AgendaSource) throws -> AgendaItem {
        guard let id = value.child("ItemId")?.attributes["Id"] else { throw OrbitaError.invalidData("Compromisso/tarefa Exchange sem identificação.") }
        var item = AgendaItem(accountID: account.id, sourceID: source.remoteID, sourceName: source.name, remoteID: id, kind: source.kind,
                              title: value.value("Subject"), canEdit: source.canEdit)
        if source.kind == .task {
            item.isCompleted = value.value("IsComplete") == "true" || value.value("Status") == "Completed"
            if !value.value("DueDate").isEmpty { item.day = String(value.value("DueDate").prefix(10)) }
            return item
        }
        guard let start = Time.parse(value.value("Start")), let end = Time.parse(value.value("End")) else { throw OrbitaError.invalidData("Compromisso Exchange sem datas válidas.") }
        if value.value("IsAllDayEvent") == "true" {
            let startZone = value.child("StartTimeZone")?.attributes["Id"] ?? "UTC", endZone = value.child("EndTimeZone")?.attributes["Id"] ?? startZone
            item.day = try Time.graphAllDay(["dateTime": value.value("Start"), "timeZone": "UTC"], originalZone: startZone)
            item.endDay = try Time.graphAllDay(["dateTime": value.value("End"), "timeZone": "UTC"], originalZone: endZone)
        } else { item.start = start; item.end = end }
        item.location = value.value("Location"); item.iCalUID = value.value("UID")
        let response = value.value("MyResponseType")
        item.response = ["Accept": "accepted", "Tentative": "tentative", "Decline": "declined", "Organizer": "organizer", "NoResponseReceived": "notResponded", "Unknown": "notResponded"][response] ?? response
        item.canRespond = source.canEdit && value.value("IsMeeting") == "true" && value.value("IsOrganizer") != "true" && response != "Organizer"
        return item
    }
    func respond(_ item: AgendaItem, response: InvitationResponse) async throws -> AgendaItem {
        let current = try await get(item.remoteID)
        let source = AgendaSource(accountID: item.accountID, remoteID: item.sourceID, name: item.sourceName, kind: .event, canEdit: item.canEdit)
        let existing = try agendaItem(current, source: source)
        guard existing.canRespond else { throw OrbitaError.invalidData("Esta conta não pode responder a esse convite Exchange.") }
        if existing.response != response.rawValue {
            guard let key = current.child("ItemId")?.attributes["ChangeKey"] else { throw OrbitaError.invalidData("O Exchange não forneceu a versão do convite.") }
            let action = response == .accepted ? "AcceptItem" : response == .tentative ? "TentativelyAcceptItem" : "DeclineItem"
            do { _ = try await call("<m:CreateItem MessageDisposition=\"SendAndSaveCopy\"><m:Items><t:\(action)><t:ReferenceItemId Id=\"\(MailXML.escape(item.remoteID))\" ChangeKey=\"\(MailXML.escape(key))\"/></t:\(action)></m:Items></m:CreateItem>") }
            catch { if case OrbitaError.authentication = error { throw error } } // Reconcile once; never repeat the write automatically.
        }
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000) }
            if let updated = try? await get(item.remoteID), let result = try? agendaItem(updated, source: source), result.response == response.rawValue { return result }
        }
        throw OrbitaError.uncertain("A resposta Exchange ainda não foi confirmada. Confira o organizador antes de responder novamente.")
    }
    func complete(_ item: AgendaItem, completed: Bool) async throws -> AgendaItem {
        let current = try await get(item.remoteID)
        try await update(current, field: "task:Status", type: "Task", value: "<t:Status>\(completed ? "Completed" : "NotStarted")</t:Status>")
        let source = AgendaSource(accountID: item.accountID, remoteID: item.sourceID, name: item.sourceName, kind: .task, canEdit: item.canEdit)
        let changed = try await agendaItem(get(item.remoteID), source: source)
        guard changed.isCompleted == completed else { throw OrbitaError.uncertain("O Exchange ainda não confirmou o estado da tarefa.") }
        return changed
    }
}
