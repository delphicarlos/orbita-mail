import Foundation
import CryptoKit

public struct MailboxFolder: Codable, Identifiable, Hashable, Sendable {
    public var accountID: String
    public var remoteID: String
    public var name: String
    public var parentID: String?
    public var standard: MailFolder?
    public var unreadCount: Int?
    public var totalCount: Int?
    public var updatedAt: Date
    public var id: String { scopedID(accountID, "mailbox", remoteID) }
    public var cacheSource: String { standard?.rawValue ?? "custom:" + remoteID }
    public init(accountID: String, remoteID: String, name: String, parentID: String? = nil, standard: MailFolder? = nil, unreadCount: Int? = nil, totalCount: Int? = nil) {
        self.accountID = accountID; self.remoteID = remoteID; self.name = name; self.parentID = parentID; self.standard = standard
        self.unreadCount = unreadCount; self.totalCount = totalCount; updatedAt = Date()
    }
    public static func validateName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 200, !MailServerConfiguration.hasControls(value), value != ".", value != ".." else {
            throw OrbitaError.invalidData("Informe um nome de pasta com até 200 bytes, sem caracteres de controle.")
        }
        return value
    }
}

public struct RoutingRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var accountID: String
    public var name: String
    public var sender: String
    public var recipient: String
    public var subject: String
    public var body: String
    public var destinationID: String
    public var enabled: Bool
    public var managed: Bool
    public var summary: String
    public init(id: String = UUID().uuidString, accountID: String, name: String = "", sender: String = "", recipient: String = "", subject: String = "", body: String = "", destinationID: String = "", enabled: Bool = true, managed: Bool = true, summary: String = "") {
        self.id = id; self.accountID = accountID; self.name = name; self.sender = sender; self.recipient = recipient; self.subject = subject; self.body = body
        self.destinationID = destinationID; self.enabled = enabled; self.managed = managed; self.summary = summary
    }
    public var conditionsDescription: String {
        [("Remetente", sender), ("Destinatário", recipient), ("Assunto", subject), ("Corpo", body)]
            .filter { !$0.1.isEmpty }.map { "\($0.0): \($0.1)" }.joined(separator: " · ")
    }
    public func validated() throws -> Self {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 120,
              [name, sender, recipient, subject, body].allSatisfy({ $0.count <= 500 && !MailServerConfiguration.hasControls($0) }),
              ![sender, recipient, subject, body].allSatisfy(\.isEmpty), !destinationID.isEmpty else {
            throw OrbitaError.invalidData("Informe nome, ao menos uma condição e a pasta de destino. Cada condição pode ter até 500 caracteres, sem quebras de linha.")
        }
        return self
    }
    public var serverName: String { "Órbita · " + name + " [" + id + "]" }
}

public struct AutoReplySettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var scheduled = false
    public var hasEnd = true
    public var start = Date()
    public var end = Date().addingTimeInterval(86400)
    public var subject = "Resposta automática"
    public var internalMessage = ""
    public var externalMessage = ""
    /// none, contacts or all; Google uses its separate contact/domain restrictions.
    public var externalAudience = "none"
    public var contactsOnly = false
    public var domainOnly = false
    public var revision = ""
    public init() {}
    public func validated(provider: Provider) throws -> Self {
        guard subject.count <= 500, !MailServerConfiguration.hasControls(subject), internalMessage.utf8.count <= 100_000, externalMessage.utf8.count <= 100_000,
              ["none", "contacts", "all"].contains(externalAudience) else { throw OrbitaError.invalidData("Mensagem ou público de resposta automática inválido.") }
        if enabled {
            guard !internalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OrbitaError.invalidData("Escreva a mensagem de resposta automática.") }
            if provider != .google && externalAudience != "none" && externalMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OrbitaError.invalidData("Escreva também a mensagem para remetentes externos.") }
            guard !scheduled || (!hasEnd || end > start) else { throw OrbitaError.invalidData("O fim do período precisa ser posterior ao início.") }
        }
        if scheduled {
            let dates = hasEnd ? [start, end] : [start]
            guard dates.allSatisfy({ $0.timeIntervalSince1970.isFinite && (0...253_402_300_799).contains($0.timeIntervalSince1970) }) else { throw OrbitaError.invalidData("O período de ausência contém uma data inválida.") }
            if provider != .google && !hasEnd { throw OrbitaError.invalidData("Este provedor exige data de término para um período.") }
        }
        return self
    }
    public var fingerprint: String {
        var value = self; value.revision = ""
        if !hasEnd { value.end = Date(timeIntervalSince1970: 0) }
        if !scheduled { value.start = Date(timeIntervalSince1970: 0); value.end = value.start }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return Data(SHA256.hash(data: (try? encoder.encode(value)) ?? Data())).base64URL
    }
    public static func plainText(_ html: String) -> String {
        html.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func html(_ text: String) -> String { MailXML.escape(text).replacingOccurrences(of: "\n", with: "<br>") }
}

public struct SignaturePreference: Codable, Sendable {
    public var accountID: String
    public var newSignatureID: String?
    public var replySignatureID: String?
    public init(accountID: String, newSignatureID: String? = nil, replySignatureID: String? = nil) { self.accountID = accountID; self.newSignatureID = newSignatureID; self.replySignatureID = replySignatureID }
}
