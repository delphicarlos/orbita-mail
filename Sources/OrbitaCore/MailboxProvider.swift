import Foundation

public extension ProviderClient {
    func mailboxes() async throws -> [MailboxFolder] {
        if account.provider == .pop3 { return [] }
        if account.provider == .imap {
            let service = try serverClient(), config = service.configuration
            let names = IMAPReply.folderNames(try await service.incoming("LIST \"\" \"*\""))
            guard names.count <= 2000 else { throw OrbitaError.invalidData("Mais de 2 mil pastas IMAP; a lista anterior foi preservada.") }
            var result: [MailboxFolder] = []
            for offset in stride(from: 0, to: names.count, by: 4) {
                let batch = Array(names[offset..<min(offset + 4, names.count)])
                result += try await withThrowingTaskGroup(of: MailboxFolder.self) { group in
                    for (name, _) in batch { group.addTask {
                        let standard = MailFolder.allCases.first { config.folders[$0.rawValue]?.caseInsensitiveCompare(name) == .orderedSame }
                        var folder = MailboxFolder(accountID: self.account.id, remoteID: name, name: name, standard: standard)
                        let bytes = try await service.incoming("STATUS \(IMAPReply.quoted(IMAPReply.encodeMailbox(name))) (UNSEEN MESSAGES)")
                        let response = String(decoding: bytes, as: UTF8.self)
                        guard let unseen = IMAPReply.firstMatch(#"\bUNSEEN\s+(\d+)"#, response).flatMap(Int.init),
                              let total = IMAPReply.firstMatch(#"\bMESSAGES\s+(\d+)"#, response).flatMap(Int.init) else { throw OrbitaError.invalidData("O IMAP não confirmou os totais da pasta \(name).") }
                        folder.unreadCount = unseen; folder.totalCount = total; return folder
                    } }
                    var values: [MailboxFolder] = []; for try await value in group { values.append(value) }; return values
                }
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        if account.provider == .exchange { return try await serverClient().ews().mailboxes() }
        if account.provider == .google {
            let list = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/labels"))
            guard let labels = list["labels"] as? [JSONObject], labels.count <= 2000 else { throw OrbitaError.invalidData("Lista de marcadores Google incompleta ou extensa demais.") }
            let roles: [String: MailFolder] = ["INBOX": .inbox, "SENT": .sent, "DRAFT": .drafts, "TRASH": .trash, "SPAM": .junk]
            var folders: [MailboxFolder] = []
            let visible = labels.filter { $0.string("type") == "user" || roles[$0.string("id")] != nil }
            for offset in stride(from: 0, to: visible.count, by: 4) {
                let batch = Array(visible[offset..<min(offset + 4, visible.count)])
                folders += try await withThrowingTaskGroup(of: MailboxFolder.self) { group in
                    for label in batch {
                        let id = try label.required("id"), name = label.string("name")
                        group.addTask {
                            let detail = try await self.json(Self.makeURL("https://gmail.googleapis.com/gmail/v1/users/me/labels/\(pathID(id))"))
                            return MailboxFolder(accountID: self.account.id, remoteID: id, name: name, standard: roles[id],
                                unreadCount: (detail["messagesUnread"] as? NSNumber)?.intValue, totalCount: (detail["messagesTotal"] as? NSNumber)?.intValue)
                        }
                    }
                    var values: [MailboxFolder] = []; for try await value in group { values.append(value) }; return values
                }
            }
            // Gmail Archive is a search, not a label with a server unread total.
            return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        var roles: [String: MailFolder] = [:]
        for role in MailFolder.allCases {
            let detail = try await json(graph("/me/mailFolders/\(role.graphName)", query: ["$select": "id"]))
            roles[try detail.required("id")] = role
        }
        var pending: [(String, String?)] = [("/me/mailFolders", nil)], result: [MailboxFolder] = [], seen = Set<String>()
        while !pending.isEmpty {
            let (path, parent) = pending.removeFirst()
            let values = try await graphPages(graph(path, query: ["$top": "100", "$select": "id,displayName,parentFolderId,unreadItemCount,totalItemCount,childFolderCount,isHidden"]))
            for value in values where !value.flag("isHidden") {
                let id = try value.required("id")
                guard seen.insert(id).inserted else { continue }
                guard seen.count <= 5000 else { throw OrbitaError.invalidData("Mais de 5 mil pastas Microsoft; a lista anterior foi preservada.") }
                result.append(MailboxFolder(accountID: account.id, remoteID: id, name: value.string("displayName"), parentID: parent,
                    standard: roles[id], unreadCount: (value["unreadItemCount"] as? NSNumber)?.intValue, totalCount: (value["totalItemCount"] as? NSNumber)?.intValue))
                if value.number("childFolderCount") > 0 { pending.append(("/me/mailFolders/\(pathID(id))/childFolders", id)) }
            }
        }
        return result
    }

    func createMailbox(name: String) async throws -> MailboxFolder {
        let name = try MailboxFolder.validateName(name)
        guard account.provider != .pop3 else { throw OrbitaError.invalidData("POP3 não oferece pastas remotas. Use IMAP se disponível.") }
        let existing = try await mailboxes()
        guard !existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw OrbitaError.invalidData("Já existe uma pasta ou marcador com esse nome.") }
        do {
            switch account.provider {
            case .microsoft:
                let created = try await json(graph("/me/mailFolders"), method: "POST", body: ["displayName": name, "isHidden": false])
                return MailboxFolder(accountID: account.id, remoteID: try created.required("id"), name: created.string("displayName"), unreadCount: 0, totalCount: 0)
            case .google:
                let created = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/labels"), method: "POST", body: ["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"])
                return MailboxFolder(accountID: account.id, remoteID: try created.required("id"), name: created.string("name"), unreadCount: 0, totalCount: 0)
            case .imap:
                _ = try await serverClient().incoming("CREATE " + IMAPReply.quoted(IMAPReply.encodeMailbox(name)))
                return MailboxFolder(accountID: account.id, remoteID: name, name: name, unreadCount: 0, totalCount: 0)
            case .exchange: return try await serverClient().ews().createMailbox(name: name)
            case .pop3: throw OrbitaError.invalidData("POP3 não oferece pastas.")
            }
        } catch {
            // Creation is not retried: reconcile a possibly accepted response by reading.
            if let confirmed = try? await mailboxes().filter({ !existing.map(\.remoteID).contains($0.remoteID) && $0.name == name }), confirmed.count == 1 { return confirmed[0] }
            throw OrbitaError.uncertain("A criação da pasta não foi confirmada. Atualize a lista antes de tentar novamente. " + error.localizedDescription)
        }
    }

    func move(_ message: MailMessage, toMailbox destination: MailboxFolder, from source: MailboxFolder? = nil) async throws {
        try validateAccount(message.accountID); try validateAccount(destination.accountID)
        if let source { try validateAccount(source.accountID) }
        if let standard = destination.standard { try await move(message, to: standard, fromMailbox: source); return }
        switch account.provider {
        case .microsoft: _ = try await request(graph("/me/messages/\(pathID(message.remoteID))/move"), method: "POST", body: ["destinationId": destination.remoteID])
        case .google:
            let removal = ["INBOX"] + (source?.standard == nil ? source.map { [$0.remoteID] } ?? [] : [])
            guard !removal.contains(destination.remoteID) else { return }
            _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))/modify"), method: "POST", body: ["addLabelIds": [destination.remoteID], "removeLabelIds": removal])
        case .imap:
            let id = try IMAPIdentity.parse(message.remoteID)
            _ = try await serverClient().incoming("UID MOVE \(id.uid) \(IMAPReply.quoted(IMAPReply.encodeMailbox(destination.remoteID)))", folder: id.folder, validity: id.validity)
        case .exchange:
            _ = try await serverClient().ews().call("<m:MoveItem><m:ToFolderId><t:FolderId Id=\"\(MailXML.escape(destination.remoteID))\"/></m:ToFolderId><m:ItemIds>\(EWSClient.itemID(message.remoteID))</m:ItemIds></m:MoveItem>")
        case .pop3: throw OrbitaError.invalidData("POP3 não oferece movimentação entre pastas.")
        }
    }
}

extension EWSClient {
    func mailboxes() async throws -> [MailboxFolder] {
        let roles = MailFolder.allCases.filter { $0 != .archive }
        let ids = roles.map { "<t:DistinguishedFolderId Id=\"\($0.graphName)\"/>" }.joined()
        let root = try await call("<m:GetFolder><m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape><m:FolderIds>\(ids)</m:FolderIds></m:GetFolder>")
        let known = root.descendants("Folders").flatMap(\.children)
        guard known.count == roles.count else { throw OrbitaError.invalidData("O Exchange não confirmou as pastas padrão.") }
        var roleIDs: [String: MailFolder] = [:]
        for (index, node) in known.enumerated() { if let id = node.child("FolderId")?.attributes["Id"] { roleIDs[id] = roles[index] } }
        return try await folders().filter { let type = $0.value("FolderClass").lowercased(); return type.isEmpty || type.hasPrefix("ipf.note") }.map { node in
            guard let id = node.child("FolderId")?.attributes["Id"] else { throw OrbitaError.invalidData("Pasta Exchange sem identificação.") }
            let name = node.value("DisplayName")
            let standard = roleIDs[id] ?? (["archive", "archives", "arquivo"].contains(name.lowercased()) ? .archive : nil)
            return MailboxFolder(accountID: account.id, remoteID: id, name: name, parentID: node.child("ParentFolderId")?.attributes["Id"], standard: standard,
                unreadCount: Int(node.value("UnreadCount")), totalCount: Int(node.value("TotalCount")))
        }
    }
    func createMailbox(name: String) async throws -> MailboxFolder {
        let root = try await call("<m:CreateFolder><m:ParentFolderId><t:DistinguishedFolderId Id=\"msgfolderroot\"/></m:ParentFolderId><m:Folders><t:Folder><t:FolderClass>IPF.Note</t:FolderClass><t:DisplayName>\(MailXML.escape(name))</t:DisplayName></t:Folder></m:Folders></m:CreateFolder>")
        guard let node = root.descendants("Folders").first?.children.first, let id = node.child("FolderId")?.attributes["Id"] else { throw OrbitaError.uncertain("O Exchange não confirmou a nova pasta; atualize antes de repetir.") }
        return MailboxFolder(accountID: account.id, remoteID: id, name: node.value("DisplayName"), unreadCount: 0, totalCount: 0)
    }
}
