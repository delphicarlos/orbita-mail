import Foundation

struct StandardMailClient: Sendable {
    let account: Account
    let configuration: MailServerConfiguration
    let vault: TokenVault
    let wire: MailWireTransport

    private func credentials() async throws -> ServerCredentials {
        guard let value = try await vault.load(ServerCredentials.self, key: ServerCredentials.key(account.id)), !value.password.isEmpty else {
            throw OrbitaError.authentication("Informe novamente a senha desta conta em Contas.")
        }
        return value
    }
    func url(_ scheme: String, host: String, port: Int, path: String = "") throws -> URL {
        var value = URLComponents(); value.scheme = scheme; value.host = host; value.port = port
        value.percentEncodedPath = path
        guard let url = value.url else { throw OrbitaError.invalidData("Endereço do servidor inválido.") }
        return url
    }
    func incomingURL(folder: String? = nil, validity: UInt32? = nil, message: Int? = nil) throws -> URL {
        let pop = account.provider == .pop3
        let scheme = (pop ? "pop3" : "imap") + (configuration.incomingSecurity == .tls ? "s" : "")
        var path = "/"
        if let folder { path += pathID(IMAPReply.encodeMailbox(folder)) }
        if let validity { path += ";UIDVALIDITY=\(validity)" }
        if let message { path += "\(message)" }
        return try url(scheme, host: configuration.incomingHost, port: configuration.incomingPort, path: path)
    }
    func incoming(_ command: String, folder: String? = nil, validity: UInt32? = nil, upload: Data? = nil) async throws -> Data {
        let secret = try await credentials()
        return try await wire(MailWireRequest(url: incomingURL(folder: folder, validity: validity), username: configuration.username,
                                             password: secret.password, command: command.isEmpty ? nil : command, upload: upload))
    }
    func verify() async throws -> MailServerConfiguration {
        _ = try configuration.validated(provider: account.provider)
        if account.provider == .exchange { try await ews().verify(); return configuration }
        var resolved = configuration
        if account.provider == .pop3 { _ = try await popUIDs() }
        else {
            let listed = try await incoming("LIST \"\" \"*\"")
            if configuration.discoverFolders {
                let folders = IMAPReply.folderNames(listed)
                for (key, flag, common) in [("sent", "\\sent", ["sent", "sent items", "sent messages", "enviados"]),
                                            ("drafts", "\\drafts", ["drafts", "rascunhos"]),
                                            ("archive", "\\archive", ["archive", "archives", "arquivo"]),
                                            ("trash", "\\trash", ["trash", "deleted items", "lixeira"]),
                                            ("junk", "\\junk", ["junk", "spam", "junk e-mail"])] {
                    if let value = folders.first(where: { $0.1.contains(flag) }) ?? folders.first(where: { common.contains($0.0.lowercased()) }) { resolved.folders[key] = value.0 }
                }
            }
            _ = try IMAPReply.validity(await incoming("STATUS \(IMAPReply.quoted(IMAPReply.encodeMailbox(try resolved.folder(.inbox)))) (UIDVALIDITY)"))
        }
        let secret = try await credentials()
        let smtp = try url("smtp" + (configuration.smtpSecurity == .tls ? "s" : ""), host: configuration.smtpHost, port: configuration.smtpPort)
        _ = try await wire(MailWireRequest(url: smtp, username: configuration.sameSMTPAuthentication ? configuration.username : configuration.smtpUsername,
                                         password: configuration.sameSMTPAuthentication ? secret.password : secret.smtpPassword, command: "NOOP"))
        if !configuration.caldavURL.isEmpty { resolved.caldavScheduling = try await dav().verify() }
        return resolved
    }
    func ews() throws -> EWSClient { try EWSClient(account: account, configuration: configuration, credentials: { try await self.credentials() }, wire: wire) }
    func dav() throws -> CalDAVClient { try CalDAVClient(account: account, configuration: configuration, credentials: { try await self.credentials() }, wire: wire) }
    func mailPage(folder: MailFolder, cursor: String?, remoteFolderID: String? = nil) async throws -> MailPage {
        if account.provider == .exchange { return try await ews().mailPage(folder: folder, cursor: cursor, remoteFolderID: remoteFolderID) }
        if account.provider == .pop3 { return try await popPage(folder: folder, cursor: cursor) }
        let name = try remoteFolderID ?? configuration.folder(folder)
        let validity = try IMAPReply.validity(await incoming("STATUS \(IMAPReply.quoted(IMAPReply.encodeMailbox(name))) (UIDVALIDITY)"))
        var criteria = "ALL"
        if let cursor {
            let previous = try IMAPIdentity.parse(cursor)
            guard previous.folder == name, previous.validity == validity else { throw OrbitaError.invalidData("A caixa IMAP mudou. Atualize antes de carregar mais mensagens.") }
            guard previous.uid > 1 else { return MailPage(messages: []) }
            criteria = "UID 1:\(previous.uid - 1)"
        }
        let matches = try IMAPReply.search(await incoming("UID SEARCH \(criteria)", folder: name, validity: validity)).sorted(by: >)
        let identifiers = Array(matches.prefix(40))
        guard !identifiers.isEmpty else { return MailPage(messages: []) }
        let command = "UID FETCH \(identifiers.map(String.init).joined(separator: ",")) (UID FLAGS INTERNALDATE BODY.PEEK[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID CONTENT-TYPE)])"
        let values = try IMAPReply.fetches(await incoming(command, folder: name, validity: validity))
        let requested = Set(identifiers)
        let messages = try values.filter { requested.contains($0.uid) }.map { fetch in
            try InternetMessage.parse(fetch.literal).message(accountID: account.id,
                remoteID: IMAPIdentity(folder: name, validity: validity, uid: fetch.uid).encoded,
                isRead: fetch.flags.lowercased().contains("\\seen"), isFlagged: fetch.flags.lowercased().contains("\\flagged"),
                fallbackDate: fetch.date ?? Date(timeIntervalSince1970: 0))
        }
        return MailPage(messages: messages.sorted { $0.date > $1.date }, nextCursor: matches.count > 40 ? IMAPIdentity(folder: name, validity: validity, uid: identifiers.last!).encoded : nil)
    }
    func raw(_ message: MailMessage) async throws -> Data {
        if account.provider == .exchange { return try await ews().raw(message) }
        if account.provider == .pop3 {
            let before = try await popUIDs()
            guard let row = before.first(where: { $0.1 == message.remoteID }) else { throw OrbitaError.invalidData("A mensagem POP3 não está mais no servidor.") }
            let bytes = try await incoming("RETR \(row.0)")
            guard try await popUIDs().contains(where: { $0.0 == row.0 && $0.1 == row.1 }) else { throw OrbitaError.invalidData("A caixa POP3 mudou durante a leitura. Atualize para conferir a mensagem.") }
            let parsed = try InternetMessage.parse(bytes)
            if !message.internetMessageID.isEmpty && parsed.headers["message-id"] != message.internetMessageID { throw OrbitaError.invalidData("A identidade da mensagem POP3 mudou; a leitura foi interrompida.") }
            return bytes
        }
        let identity = try IMAPIdentity.parse(message.remoteID)
        let value = try IMAPReply.fetches(await incoming("UID FETCH \(identity.uid) (UID BODY.PEEK[])", folder: identity.folder, validity: identity.validity))
        guard let found = value.first(where: { $0.uid == identity.uid }) else { throw OrbitaError.invalidData("Mensagem não encontrada no IMAP. Atualize a caixa.") }
        return found.literal
    }
    func body(_ message: MailMessage) async throws -> MailBody { try InternetMessage.parse(await raw(message)).mailBody }
    func attachment(_ message: MailMessage, id: String) async throws -> Data {
        let parsed = try InternetMessage.parse(await raw(message))
        guard let value = parsed.attachments.first(where: { $0.id == id }) else { throw OrbitaError.invalidData("Anexo não encontrado nesta mensagem.") }
        return value.data
    }
    func setFlag(_ message: MailMessage, flag: String, enabled: Bool) async throws {
        if account.provider == .exchange { try await ews().setFlag(message, flag: flag, enabled: enabled); return }
        if account.provider == .pop3 { return } // POP3 has no remote read/flag state; the UI stores this locally.
        guard ["\\Seen", "\\Flagged"].contains(flag) else { throw OrbitaError.invalidData("Marcação IMAP inválida.") }
        let identity = try IMAPIdentity.parse(message.remoteID)
        _ = try await incoming("UID STORE \(identity.uid) \(enabled ? "+" : "-")FLAGS.SILENT (\(flag))", folder: identity.folder, validity: identity.validity)
    }
    func move(_ message: MailMessage, to folder: MailFolder) async throws {
        if account.provider == .exchange { try await ews().move(message, to: folder); return }
        guard account.provider == .imap else { throw OrbitaError.invalidData("POP3 não oferece pastas nem movimentação. Nenhuma mensagem foi excluída do servidor.") }
        let identity = try IMAPIdentity.parse(message.remoteID), name = try configuration.folder(folder)
        // MOVE is atomic and avoids an EXPUNGE that could purge unrelated messages.
        _ = try await incoming("UID MOVE \(identity.uid) \(IMAPReply.quoted(IMAPReply.encodeMailbox(name)))", folder: identity.folder, validity: identity.validity)
    }
    func send(_ draft: MailDraft) async throws {
        if account.provider == .exchange { try await ews().send(draft); return }
        let secret = try await credentials()
        var recipients: [String] = []
        for address in try MailValidation.recipients(draft.to) + MailValidation.recipients(draft.cc) + MailValidation.recipients(draft.bcc) {
            if !recipients.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) { recipients.append(address) }
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let prefix = Data("Date: \(formatter.string(from: Date()))\r\nMessage-ID: <\(UUID().uuidString)@\(account.email.split(separator: "@").last ?? "orbita.local")>\r\n".utf8)
        let payload = prefix + (try MIME.message(draft, from: account.email, includeBcc: false))
        let smtp = try url("smtp" + (configuration.smtpSecurity == .tls ? "s" : ""), host: configuration.smtpHost, port: configuration.smtpPort)
        _ = try await wire(MailWireRequest(url: smtp, username: configuration.sameSMTPAuthentication ? configuration.username : configuration.smtpUsername,
                                         password: configuration.sameSMTPAuthentication ? secret.password : secret.smtpPassword, upload: payload, sender: account.email, recipients: recipients))
        if account.provider == .imap && configuration.saveSentCopy {
            do { _ = try await incoming("", folder: configuration.folder(.sent), upload: prefix + MIME.message(draft, from: account.email)) }
            catch { throw OrbitaError.uncertain("O SMTP aceitou o envio, mas a cópia em Enviados não foi confirmada. Não reenvie; confira o destinatário e a pasta configurada.") }
        }
    }
    func popUIDs() async throws -> [(Int, String)] {
        let bytes = try await incoming("UIDL")
        let rows = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\n").compactMap { line -> (Int, String)? in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let index = Int(fields[0]), index > 0, fields[1].utf8.count <= 70,
                  fields[1].utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
            return (index, String(fields[1]))
        }
        guard Set(rows.map(\.1)).count == rows.count else { throw OrbitaError.invalidData("O POP3 retornou identificadores repetidos.") }
        return rows
    }
    func popPage(folder: MailFolder, cursor: String?) async throws -> MailPage {
        guard folder == .inbox else { throw OrbitaError.invalidData("POP3 fornece somente a caixa de entrada. Enviados e rascunhos desta conta são locais.") }
        let rows = try await popUIDs().sorted { $0.0 > $1.0 }
        var candidates = rows[...]
        if let cursor {
            guard let position = rows.firstIndex(where: { $0.1 == cursor }) else { throw OrbitaError.invalidData("A caixa POP3 mudou. Atualize antes de carregar mais.") }
            candidates = rows.suffix(from: rows.index(after: position))
        }
        let page = Array(candidates.prefix(20)); var messages: [MailMessage] = []
        for offset in stride(from: 0, to: page.count, by: 4) {
            let batch = Array(page[offset..<min(offset + 4, page.count)])
            messages += try await withThrowingTaskGroup(of: MailMessage.self) { group in
                for row in batch { group.addTask {
                    let data: Data
                    do { data = try await incoming("TOP \(row.0) 0") }
                    catch is POPHeaderUnsupported { data = try await incoming("RETR \(row.0)") }
                    return try InternetMessage.parse(data).message(accountID: account.id, remoteID: row.1)
                } }
                var result: [MailMessage] = []; for try await value in group { result.append(value) }; return result
            }
        }
        let after = try await popUIDs()
        guard page.allSatisfy({ row in after.contains(where: { $0.0 == row.0 && $0.1 == row.1 }) }) else { throw OrbitaError.invalidData("A caixa POP3 mudou durante a sincronização. A cópia anterior foi preservada.") }
        return MailPage(messages: messages.sorted { $0.date > $1.date }, nextCursor: candidates.count > 20 ? page.last?.1 : nil)
    }
}
