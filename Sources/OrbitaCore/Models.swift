import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case microsoft, google, imap, pop3, exchange
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .microsoft: "Microsoft 365 / Outlook"
        case .google: "Google / Gmail"
        case .imap: "Outro provedor · IMAP/SMTP"
        case .pop3: "POP3/SMTP"
        case .exchange: "Exchange próprio · EWS"
        }
    }
    public var usesOAuth: Bool { self == .microsoft || self == .google }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var provider: Provider
    public var email: String
    public var name: String
    public var clientID: String
    public var colorIndex: Int
    public var serverConfiguration: MailServerConfiguration?
    public init(provider: Provider, email: String, name: String, clientID: String, colorIndex: Int = 0, serverConfiguration: MailServerConfiguration? = nil) {
        self.id = provider.rawValue + ":" + email.lowercased()
        self.provider = provider; self.email = email; self.name = name
        self.clientID = clientID; self.colorIndex = colorIndex
        self.serverConfiguration = serverConfiguration
    }
}

public struct OAuthConfiguration: Codable, Sendable {
    public var microsoftClientID = ""
    public var googleClientID = ""
    public init() {}
    public func clientID(for provider: Provider) -> String {
        switch provider { case .microsoft: microsoftClientID; case .google: googleClientID; default: "" }
    }
}

public struct OAuthToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String
    public init(accessToken: String, refreshToken: String, expiresAt: Date, scope: String = "") {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scope = scope
    }
}

public enum MailFolder: String, Codable, CaseIterable, Identifiable, Sendable {
    case inbox, sent, drafts, archive, trash, junk
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .inbox: "Caixa de entrada"
        case .sent: "Enviados"
        case .drafts: "Rascunhos"
        case .archive: "Arquivo"
        case .trash: "Lixeira"
        case .junk: "Spam"
        }
    }
    public var symbol: String {
        switch self {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .trash: "trash"
        case .junk: "exclamationmark.shield"
        }
    }
    public var graphName: String {
        switch self { case .inbox: "inbox"; case .sent: "sentitems"; case .drafts: "drafts";
        case .archive: "archive"; case .trash: "deleteditems"; case .junk: "junkemail" }
    }
    public var gmailQuery: String {
        switch self { case .inbox: "in:inbox"; case .sent: "in:sent"; case .drafts: "in:drafts";
        case .archive: "-in:inbox -in:sent -in:drafts -in:trash -in:spam";
        case .trash: "in:trash"; case .junk: "in:spam" }
    }
}

public func scopedID(_ components: String...) -> String {
    // JSON framing prevents collisions when a provider ID itself contains separators.
    let bytes = try! JSONEncoder().encode(components)
    return bytes.base64EncodedString()
}

public struct MailMessage: Codable, Identifiable, Hashable, Sendable {
    public var remoteID: String
    public var accountID: String
    public var threadID: String
    public var subject: String
    public var sender: String
    public var senderName: String
    public var to: [String]
    public var cc: [String]
    public var date: Date
    public var preview: String
    public var isRead: Bool
    public var isFlagged: Bool
    public var hasAttachments: Bool
    public var internetMessageID: String
    public var id: String { scopedID(accountID, remoteID) }
    public init(remoteID: String, accountID: String, threadID: String = "", subject: String,
                sender: String, senderName: String = "", to: [String] = [], cc: [String] = [],
                date: Date, preview: String, isRead: Bool = false, isFlagged: Bool = false,
                hasAttachments: Bool = false, internetMessageID: String = "") {
        self.remoteID = remoteID; self.accountID = accountID; self.threadID = threadID
        self.subject = subject; self.sender = sender; self.senderName = senderName
        self.to = to; self.cc = cc; self.date = date; self.preview = preview
        self.isRead = isRead; self.isFlagged = isFlagged; self.hasAttachments = hasAttachments
        self.internetMessageID = internetMessageID
    }
}

public struct MailAttachment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var size: Int
    public init(id: String, name: String, mimeType: String, size: Int) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.size = size
    }
}

public struct MailBody: Codable, Sendable {
    public var text: String
    public var html: String
    public var attachments: [MailAttachment]
    public init(text: String = "", html: String = "", attachments: [MailAttachment] = []) {
        self.text = text; self.html = html; self.attachments = attachments
    }
    public var plainText: String {
        if !text.isEmpty { return text }
        return html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<br\s*/?>|</(?:p|div|tr|h[1-6])>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
    }
}

public struct MailPage: Sendable {
    public var messages: [MailMessage]
    public var nextCursor: String?
    public init(messages: [MailMessage], nextCursor: String? = nil) {
        self.messages = messages; self.nextCursor = nextCursor
    }
}

public struct OutgoingAttachment: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var mimeType: String
    public var data: Data
    public init(name: String, mimeType: String, data: Data) {
        self.name = name; self.mimeType = mimeType; self.data = data
    }
}

public struct MailDraft: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var accountID: String
    public var to = ""
    public var cc = ""
    public var bcc = ""
    public var subject = ""
    public var text = ""
    public var attachments: [OutgoingAttachment] = []
    public var signatureID: String?
    public var signatureText: String?
    public var composedText: String { text + ((signatureText?.isEmpty == false) ? "\n\n-- \n" + signatureText! : "") }
    public var replyToRemoteID: String?
    public var threadID: String?
    public var inReplyTo: String?
    public var deliveryState = "draft"
    public init(accountID: String) { self.accountID = accountID }
    public var isEmpty: Bool { to.isEmpty && subject.isEmpty && text.isEmpty && attachments.isEmpty }
}

public enum AgendaKind: String, Codable, Sendable { case event, task }
public struct PendingResponse: Codable, Sendable {
    public var itemID: String
    public var accountID: String
    public var response: InvitationResponse
    public init(itemID: String, accountID: String, response: InvitationResponse) {
        self.itemID = itemID; self.accountID = accountID; self.response = response
    }
}
public enum InvitationResponse: String, Codable, CaseIterable, Identifiable, Sendable {
    case accepted, tentative, declined
    public var id: String { rawValue }
    public var title: String { switch self { case .accepted: "Aceitar"; case .tentative: "Talvez"; case .declined: "Recusar" } }
    public var statusLabel: String { switch self { case .accepted: "Aceito"; case .tentative: "Talvez"; case .declined: "Recusado" } }
    public var graphAction: String { switch self { case .accepted: "accept"; case .tentative: "tentativelyAccept"; case .declined: "decline" } }
}

public struct AgendaSource: Codable, Identifiable, Hashable, Sendable {
    public var accountID: String
    public var remoteID: String
    public var name: String
    public var kind: AgendaKind
    public var canEdit: Bool
    public var id: String { scopedID(accountID, kind.rawValue, remoteID) }
    public init(accountID: String, remoteID: String, name: String, kind: AgendaKind, canEdit: Bool = true) {
        self.accountID = accountID; self.remoteID = remoteID; self.name = name
        self.kind = kind; self.canEdit = canEdit
    }
}

public struct AgendaItem: Codable, Identifiable, Hashable, Sendable {
    public var accountID: String
    public var sourceID: String
    public var sourceName: String
    public var remoteID: String
    public var kind: AgendaKind
    public var title: String
    public var start: Date?
    public var end: Date?
    public var day: String?
    public var endDay: String?
    public var location: String
    public var meetingURL: String
    public var response: String
    public var canRespond: Bool
    public var canEdit: Bool
    public var isCompleted: Bool
    public var iCalUID: String
    public var id: String { scopedID(accountID, kind.rawValue, sourceID, remoteID) }
    public init(accountID: String, sourceID: String, sourceName: String, remoteID: String,
                kind: AgendaKind, title: String, start: Date? = nil, end: Date? = nil,
                day: String? = nil, endDay: String? = nil, location: String = "", meetingURL: String = "",
                response: String = "", canRespond: Bool = false, canEdit: Bool = true,
                isCompleted: Bool = false, iCalUID: String = "") {
        self.accountID = accountID; self.sourceID = sourceID; self.sourceName = sourceName
        self.remoteID = remoteID; self.kind = kind; self.title = title
        self.start = start; self.end = end; self.day = day; self.endDay = endDay
        self.location = location; self.meetingURL = meetingURL; self.response = response
        self.canRespond = canRespond; self.canEdit = canEdit
        self.isCompleted = isCompleted; self.iCalUID = iCalUID
    }
    public var displayDate: Date? { day.flatMap(Time.dayDate) ?? start }
    public func overlaps(_ interval: DateInterval) -> Bool {
        guard let begin = displayDate else { return false }
        let finish = endDay.flatMap(Time.dayDate) ?? end ?? begin.addingTimeInterval(day == nil ? 1 : 86400)
        return begin < interval.end && finish > interval.start
    }
    public var responseLabel: String {
        switch response {
        case "accepted": "Aceito"
        case "tentative", "tentativelyAccepted": "Talvez"
        case "declined": "Recusado"
        case "organizer": "Organizador"
        case "needsAction", "notResponded", "none": "Sem resposta"
        default: ""
        }
    }
}

public enum Time {
    public static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    public static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    public static func dayDate(_ text: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard text.count == 10 else { return nil }
        return formatter.date(from: text)
    }
    public static func graphDate(_ object: [String: Any]) throws -> Date {
        guard let raw = object["dateTime"] as? String else { throw OrbitaError.invalidData("Data do evento ausente.") }
        if let date = parse(raw) { return date }
        // Graph requests below explicitly ask for UTC. Never reinterpret unspecified time as local.
        guard object["timeZone"] as? String == "UTC", let date = parse(raw + "Z") else {
            throw OrbitaError.invalidData("Fuso do evento não reconhecido.")
        }
        return date
    }
    public static func graphAllDay(_ object: JSONObject, originalZone: String) throws -> String {
        let windows = ["UTC": "UTC", "E. South America Standard Time": "America/Sao_Paulo",
                       "SA Eastern Standard Time": "America/Fortaleza", "SA Pacific Standard Time": "America/Bogota",
                       "Eastern Standard Time": "America/New_York", "Pacific Standard Time": "America/Los_Angeles",
                       "GMT Standard Time": "Europe/London", "W. Europe Standard Time": "Europe/Berlin",
                       "Romance Standard Time": "Europe/Paris", "Tokyo Standard Time": "Asia/Tokyo",
                       "China Standard Time": "Asia/Shanghai", "AUS Eastern Standard Time": "Australia/Sydney"]
        let zoneName = originalZone.isEmpty ? object.string("timeZone") : originalZone
        guard let zone = TimeZone(identifier: windows[zoneName] ?? zoneName) else {
            throw OrbitaError.invalidData("Fuso original de evento de dia inteiro não suportado: \(zoneName). A fonte foi preservada no cache.")
        }
        let date = try graphDate(object)
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

public enum OrbitaError: LocalizedError {
    case invalidData(String), authentication(String), storage(String), network(Int, String), uncertain(String)
    public var errorDescription: String? {
        switch self {
        case let .invalidData(s), let .authentication(s), let .storage(s), let .uncertain(s): s
        case let .network(status, text): status == 0 ? text : "Provedor retornou HTTP \(status). \(text)"
        }
    }
}

public enum MailValidation {
    public static func recipients(_ text: String) throws -> [String] {
        let values = text.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }
        for value in values {
            guard value.rangeOfCharacter(from: .controlCharacters) == nil, !value.contains(" "),
                  value.split(separator: "@").count == 2, value.contains("."),
                  !value.contains("<"), !value.contains(">") else {
                throw OrbitaError.invalidData("Use endereços de email separados por vírgula, sem nomes ou quebras de linha.")
            }
        }
        return values
    }
    public static func validate(_ draft: MailDraft) throws {
        let to = try recipients(draft.to)
        let cc = try recipients(draft.cc); let bcc = try recipients(draft.bcc)
        guard !to.isEmpty || !cc.isEmpty || !bcc.isEmpty else { throw OrbitaError.invalidData("Informe um destinatário.") }
        guard draft.subject.rangeOfCharacter(from: .controlCharacters) == nil else { throw OrbitaError.invalidData("Assunto inválido.") }
        guard draft.attachments.reduce(0, { $0 + $1.data.count }) <= 2_500_000 else {
            throw OrbitaError.invalidData("Nesta versão, os anexos de um email podem somar até 2,5 MB.")
        }
    }
}
