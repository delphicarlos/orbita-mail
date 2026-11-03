import Foundation

public extension ProviderClient {
    func mailPage(folder: MailFolder, cursor: String? = nil, remoteFolderID: String? = nil) async throws -> MailPage {
        if !account.provider.usesOAuth { return try await serverClient().mailPage(folder: folder, cursor: cursor, remoteFolderID: remoteFolderID) }
        if account.provider == .microsoft {
            let url: URL
            if let cursor {
                guard let next = URL(string: cursor), Self.allowed(next, provider: .microsoft) else { throw OrbitaError.invalidData("Página de mensagens inválida.") }
                url = next
            } else {
                url = try graph("/me/mailFolders/\(pathID(remoteFolderID ?? folder.graphName))/messages", query: [
                    "$top": "40", "$orderby": "receivedDateTime desc",
                    "$select": "id,conversationId,subject,from,toRecipients,ccRecipients,receivedDateTime,createdDateTime,sentDateTime,bodyPreview,isRead,flag,hasAttachments,internetMessageId"
                ])
            }
            let page = try await json(url)
            guard let values = page["value"] as? [JSONObject] else { throw OrbitaError.invalidData("Página de mensagens incompleta.") }
            return MailPage(messages: try values.map { try Self.graphMessage($0, accountID: account.id) },
                            nextCursor: page.string("@odata.nextLink").nilIfEmpty)
        }
        var query = ["q": folder.gmailQuery, "maxResults": "40", "includeSpamTrash": "true"]
        if let remoteFolderID { query.removeValue(forKey: "q"); query["labelIds"] = remoteFolderID }
        if let cursor { query["pageToken"] = cursor }
        let page = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/messages", query: query))
        let identifiers = try page.objects("messages").map { try $0.required("id") }
        // Limit in-flight requests; Gmail's list endpoint returns IDs, not message headers.
        var messages: [MailMessage] = []
        for offset in stride(from: 0, to: identifiers.count, by: 4) {
            let batch = Array(identifiers[offset..<min(offset + 4, identifiers.count)])
            let values = try await withThrowingTaskGroup(of: MailMessage.self) { group in
                for identifier in batch {
                    group.addTask {
                        let data = try await self.json(Self.makeURL("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(identifier))", query: ["format": "metadata"]))
                        return try Self.googleMessage(data, accountID: self.account.id)
                    }
                }
                var collected: [MailMessage] = []
                for try await message in group { collected.append(message) }
                return collected
            }
            messages += values
        }
        return MailPage(messages: messages.sorted { $0.date > $1.date }, nextCursor: page.string("nextPageToken").nilIfEmpty)
    }

    static func graphMessage(_ json: JSONObject, accountID: String) throws -> MailMessage {
        let sender = json.object("from").object("emailAddress")
        guard let date = Time.parse(json.string("receivedDateTime")) ?? Time.parse(json.string("sentDateTime")) ?? Time.parse(json.string("createdDateTime")) else { throw OrbitaError.invalidData("Mensagem sem data válida.") }
        return MailMessage(remoteID: try json.required("id"), accountID: accountID, threadID: json.string("conversationId"),
                           subject: json.string("subject"), sender: sender.string("address"), senderName: sender.string("name"),
                           to: json.objects("toRecipients").map { $0.object("emailAddress").string("address") },
                           cc: json.objects("ccRecipients").map { $0.object("emailAddress").string("address") },
                           date: date, preview: json.string("bodyPreview"), isRead: json.flag("isRead"),
                           isFlagged: json.object("flag").string("flagStatus") == "flagged",
                           hasAttachments: json.flag("hasAttachments"), internetMessageID: json.string("internetMessageId"))
    }

    static func googleMessage(_ json: JSONObject, accountID: String) throws -> MailMessage {
        let headers = json.object("payload").objects("headers")
        func header(_ name: String) -> String { headers.first { $0.string("name").lowercased() == name.lowercased() }?.string("value") ?? "" }
        let sender = Mailbox.addresses(header("From")).first ?? header("From")
        let labels = json["labelIds"] as? [String] ?? []
        guard let milliseconds = Double(json.string("internalDate")) else { throw OrbitaError.invalidData("Mensagem Google sem data válida.") }
        return MailMessage(remoteID: try json.required("id"), accountID: accountID, threadID: json.string("threadId"),
                           subject: header("Subject"), sender: sender, senderName: header("From").components(separatedBy: "<").first?.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) ?? sender,
                           to: Mailbox.addresses(header("To")), cc: Mailbox.addresses(header("Cc")),
                           date: Date(timeIntervalSince1970: milliseconds / 1000), preview: json.string("snippet"),
                           isRead: !labels.contains("UNREAD"), isFlagged: labels.contains("STARRED"),
                           hasAttachments: Self.googleParts(json.object("payload")).contains { !$0.string("filename").isEmpty },
                           internetMessageID: header("Message-ID"))
    }

    func mailBody(_ message: MailMessage) async throws -> MailBody {
        try validateAccount(message.accountID)
        if !account.provider.usesOAuth { return try await serverClient().body(message) }
        if account.provider == .microsoft {
            let value = try await json(graph("/me/messages/\(pathID(message.remoteID))", query: ["$select": "body"]))
            let body = value.object("body")
            let attachments = try await graphPages(graph("/me/messages/\(pathID(message.remoteID))/attachments", query: ["$select": "id,name,contentType,size,isInline"]))
                .filter { !$0.flag("isInline") && $0.string("@odata.type") != "#microsoft.graph.referenceAttachment" }
                .map { MailAttachment(id: try $0.required("id"), name: $0.string("name"), mimeType: $0.string("contentType"), size: Int($0.number("size"))) }
            let html = body.string("contentType").lowercased() == "html"
            return MailBody(text: html ? "" : body.string("content"), html: html ? body.string("content") : "", attachments: attachments)
        }
        let value = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))", query: ["format": "full"]))
        let parts = Self.googleParts(value.object("payload"))
        var text = "", html = "", attachments: [MailAttachment] = []
        for part in parts {
            let body = part.object("body"), name = part.string("filename"), mime = part.string("mimeType")
            if !name.isEmpty {
                if !body.string("attachmentId").isEmpty {
                    attachments.append(MailAttachment(id: body.string("attachmentId"), name: name, mimeType: mime, size: Int(body.number("size"))))
                }
                continue
            }
            guard mime == "text/plain" || mime == "text/html" else { continue }
            let bytes: Data
            if let embedded = Data(base64URL: body.string("data")), !embedded.isEmpty { bytes = embedded }
            else if !body.string("attachmentId").isEmpty {
                bytes = try await attachmentData(message: message, attachmentID: body.string("attachmentId"))
            } else { continue }
            let content = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? ""
            if mime == "text/html" { html += content } else { text += content }
        }
        return MailBody(text: text, html: html, attachments: attachments)
    }

    static func googleParts(_ root: JSONObject) -> [JSONObject] {
        [root] + root.objects("parts").flatMap { googleParts($0) }
    }

    func attachmentData(message: MailMessage, attachmentID: String) async throws -> Data {
        try validateAccount(message.accountID)
        if !account.provider.usesOAuth { return try await serverClient().attachment(message, id: attachmentID) }
        let url = account.provider == .microsoft
            ? try graph("/me/messages/\(pathID(message.remoteID))/attachments/\(pathID(attachmentID))")
            : try google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))/attachments/\(pathID(attachmentID))")
        let value = try await json(url)
        let result = account.provider == .microsoft ? Data(base64Encoded: value.string("contentBytes")) : Data(base64URL: value.string("data"))
        guard let result else { throw OrbitaError.invalidData("Este tipo de anexo não está disponível para download nesta versão.") }
        return result
    }

    func setRead(_ message: MailMessage, read: Bool) async throws {
        try validateAccount(message.accountID)
        if !account.provider.usesOAuth { try await serverClient().setFlag(message, flag: "\\Seen", enabled: read); return }
        if account.provider == .microsoft {
            _ = try await request(graph("/me/messages/\(pathID(message.remoteID))"), method: "PATCH", body: ["isRead": read])
        } else {
            _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))/modify"), method: "POST",
                                  body: [read ? "removeLabelIds" : "addLabelIds": ["UNREAD"]])
        }
    }

    func setFlag(_ message: MailMessage, flagged: Bool) async throws {
        try validateAccount(message.accountID)
        if !account.provider.usesOAuth { try await serverClient().setFlag(message, flag: "\\Flagged", enabled: flagged); return }
        if account.provider == .microsoft {
            _ = try await request(graph("/me/messages/\(pathID(message.remoteID))"), method: "PATCH",
                                  body: ["flag": ["flagStatus": flagged ? "flagged" : "notFlagged"]])
        } else {
            _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))/modify"), method: "POST",
                                  body: [flagged ? "addLabelIds" : "removeLabelIds": ["STARRED"]])
        }
    }

    func move(_ message: MailMessage, to folder: MailFolder, fromMailbox: MailboxFolder? = nil) async throws {
        try validateAccount(message.accountID)
        if let fromMailbox { try validateAccount(fromMailbox.accountID) }
        if !account.provider.usesOAuth { try await serverClient().move(message, to: folder); return }
        guard folder == .archive || folder == .trash || folder == .inbox || folder == .junk else { throw OrbitaError.invalidData("Destino não suportado para esta ação.") }
        if account.provider == .microsoft {
            _ = try await request(graph("/me/messages/\(pathID(message.remoteID))/move"), method: "POST", body: ["destinationId": folder.graphName])
        } else if folder == .trash {
            _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))/trash"), method: "POST")
        } else {
            let add: [String] = folder == .inbox ? ["INBOX"] : folder == .junk ? ["SPAM"] : []
            var remove: [String] = folder == .inbox ? ["SPAM", "TRASH"] : ["INBOX"]
            if let fromMailbox, fromMailbox.standard == nil { remove.append(fromMailbox.remoteID) }
            _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/\(pathID(message.remoteID))/modify"), method: "POST",
                                  body: ["addLabelIds": add, "removeLabelIds": remove])
        }
    }

    func send(_ draft: MailDraft) async throws {
        try validateAccount(draft.accountID); try MailValidation.validate(draft)
        if !account.provider.usesOAuth { try await serverClient().send(draft); return }
        if account.provider == .microsoft {
            func recipients(_ text: String) throws -> [JSONObject] {
                try MailValidation.recipients(text).map { ["emailAddress": ["address": $0]] }
            }
            let message: JSONObject = ["subject": draft.subject, "body": ["contentType": "Text", "content": draft.composedText],
                                      "toRecipients": try recipients(draft.to), "ccRecipients": try recipients(draft.cc), "bccRecipients": try recipients(draft.bcc),
                                      "attachments": draft.attachments.map { ["@odata.type": "#microsoft.graph.fileAttachment", "name": $0.name,
                                                                              "contentType": $0.mimeType, "contentBytes": $0.data.base64EncodedString()] }]
            if let remoteID = draft.replyToRemoteID {
                _ = try await request(graph("/me/messages/\(pathID(remoteID))/reply"), method: "POST", body: ["message": message])
            } else { _ = try await request(graph("/me/sendMail"), method: "POST", body: ["message": message, "saveToSentItems": true]) }
        } else {
            var body: JSONObject = ["raw": try MIME.message(draft, from: account.email).base64URL]
            if let threadID = draft.threadID, !threadID.isEmpty { body["threadId"] = threadID }
            _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/messages/send"), method: "POST", body: body)
        }
    }

    func validateAccount(_ accountID: String) throws {
        guard accountID == account.id else { throw OrbitaError.invalidData("A conta selecionada não corresponde à origem deste item.") }
    }
}

public extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

public enum Mailbox {
    public static func addresses(_ value: String) -> [String] {
        let pattern = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let text = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
    }
}

public enum MIME {
    private static func wrappedBase64(_ data: Data) -> String {
        let string = data.base64EncodedString()
        return stride(from: 0, to: string.count, by: 76).map { index in
            let begin = string.index(string.startIndex, offsetBy: index)
            let end = string.index(begin, offsetBy: min(76, string.count - index))
            return String(string[begin..<end])
        }.joined(separator: "\r\n")
    }
    public static func message(_ draft: MailDraft, from: String, includeBcc: Bool = true) throws -> Data {
        try MailValidation.validate(draft)
        guard try MailValidation.recipients(from).count == 1 else { throw OrbitaError.invalidData("Remetente inválido.") }
        let boundary = "orbita_" + UUID().uuidString
        var headers = ["From: \(from)", "To: \(try MailValidation.recipients(draft.to).joined(separator: ", "))",
                       "Subject: =?UTF-8?B?\(Data(draft.subject.utf8).base64EncodedString())?=", "MIME-Version: 1.0"]
        if !draft.cc.isEmpty { headers.append("Cc: \(try MailValidation.recipients(draft.cc).joined(separator: ", "))") }
        if includeBcc && !draft.bcc.isEmpty { headers.append("Bcc: \(try MailValidation.recipients(draft.bcc).joined(separator: ", "))") }
        if let reply = draft.inReplyTo, !reply.isEmpty {
            guard reply.rangeOfCharacter(from: .controlCharacters) == nil else { throw OrbitaError.invalidData("Identificação da resposta inválida.") }
            headers += ["In-Reply-To: \(reply)", "References: \(reply)"]
        }
        headers.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        var content = headers.joined(separator: "\r\n") + "\r\n\r\n"
        content += "--\(boundary)\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrappedBase64(Data(draft.composedText.utf8)))\r\n"
        for attachment in draft.attachments {
            let filename = attachment.name.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\"", with: "'")
            let safeType = attachment.mimeType.range(of: #"^[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+$"#, options: .regularExpression) != nil ? attachment.mimeType : "application/octet-stream"
            content += "--\(boundary)\r\nContent-Type: \(safeType)\r\nContent-Disposition: attachment; filename*=UTF-8''\(pathID(filename))\r\nContent-Transfer-Encoding: base64\r\n\r\n\(wrappedBase64(attachment.data))\r\n"
        }
        content += "--\(boundary)--\r\n"
        return Data(content.utf8)
    }
}
