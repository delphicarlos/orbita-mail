import Foundation
import CryptoKit

public struct ImportedAccount: Codable, Identifiable, Hashable, Sendable {
    public var email: String
    public var displayName: String
    public var provider: Provider?
    public var sourceKind: String
    public var server: String?
    public var id: String { email.lowercased() }
    public init(email: String, displayName: String, provider: Provider?, sourceKind: String, server: String? = nil) {
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.displayName = displayName; self.provider = provider; self.sourceKind = sourceKind
        self.server = server
    }
    public static func outlook(kind: String, email: String, name: String, server: String) -> ImportedAccount {
        let host = server.lowercased()
        let provider: Provider?
        if kind == "Exchange" { provider = .microsoft }
        else if host == "imap.gmail.com" || host == "imap.googlemail.com" { provider = .google }
        else if host == "outlook.office365.com" || host == "imap-mail.outlook.com" { provider = .microsoft }
        else { provider = kind == "IMAP" ? .imap : kind == "POP" ? .pop3 : nil }
        return ImportedAccount(email: email, displayName: name, provider: provider, sourceKind: kind, server: server.nilIfEmpty)
    }
}

public enum WritingPresetKind: String, Codable, Sendable { case signature, template }

public struct WritingPreset: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var text: String
    public var subject: String
    public var accountEmail: String?
    public var kind: WritingPresetKind
    public var id: String {
        let fields = [kind.rawValue, name, subject, text, accountEmail?.lowercased() ?? ""]
        return Data(SHA256.hash(data: try! JSONEncoder().encode(fields))).base64URL
    }
    public init(name: String, text: String, subject: String = "", accountEmail: String? = nil, kind: WritingPresetKind) {
        self.name = name; self.text = text; self.subject = subject; self.accountEmail = accountEmail; self.kind = kind
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        name = try fields.decode(String.self, forKey: .name)
        text = try fields.decode(String.self, forKey: .text)
        subject = try fields.decodeIfPresent(String.self, forKey: .subject) ?? ""
        accountEmail = try fields.decodeIfPresent(String.self, forKey: .accountEmail)
        kind = try fields.decode(WritingPresetKind.self, forKey: .kind)
    }
}

public struct OutlookImportManifest: Codable, Sendable {
    public var version: Int
    public var accounts: [ImportedAccount]
    public var presets: [WritingPreset]
    public var warnings: [String]
    public init(accounts: [ImportedAccount], presets: [WritingPreset] = [], warnings: [String] = []) {
        version = 1; self.accounts = accounts; self.presets = presets; self.warnings = warnings
    }
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        version = try fields.decodeIfPresent(Int.self, forKey: .version) ?? 1
        accounts = try fields.decodeIfPresent([ImportedAccount].self, forKey: .accounts) ?? []
        presets = try fields.decodeIfPresent([WritingPreset].self, forKey: .presets) ?? []
        warnings = try fields.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
    public static func parse(_ bytes: Data) throws -> OutlookImportManifest {
        guard bytes.count <= 2_000_000 else { throw OrbitaError.invalidData("O arquivo de configuração pode ter até 2 MB.") }
        let manifest: OutlookImportManifest
        do { manifest = try JSONDecoder().decode(Self.self, from: bytes) }
        catch { throw OrbitaError.invalidData("Arquivo de importação inválido. Use o formato JSON de contas e configurações do Órbita.") }
        return try manifest.validated()
    }
    public func validated() throws -> OutlookImportManifest {
        guard version == 1, accounts.count <= 100, presets.count <= 200 else { throw OrbitaError.invalidData("Versão ou quantidade de configurações não suportada.") }
        guard !accounts.isEmpty || !presets.isEmpty else { throw OrbitaError.invalidData("Nenhuma conta, assinatura ou modelo foi encontrado. Esta versão do Outlook pode não expor suas contas pela automação; você pode importar um arquivo de configuração.") }
        var unique: [ImportedAccount] = [], seen = Set<String>()
        for var account in accounts {
            let addresses = try MailValidation.recipients(account.email)
            guard addresses.count == 1 else { throw OrbitaError.invalidData("Há uma conta com endereço inválido no arquivo.") }
            account.email = addresses[0].lowercased()
            guard account.displayName.count <= 300, account.sourceKind.count <= 100, (account.server?.count ?? 0) <= 500,
                  !(account.server.map(MailServerConfiguration.hasControls) ?? false) else { throw OrbitaError.invalidData("Nome de conta ou origem inválido ou muito extenso.") }
            if seen.insert(account.id).inserted { unique.append(account) }
        }
        var presetIDs = Set<String>(), uniquePresets: [WritingPreset] = []
        for preset in presets {
            guard !preset.name.isEmpty, preset.name.count <= 300, preset.text.count <= 200_000,
                  preset.subject.count <= 500, preset.subject.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw OrbitaError.invalidData("Uma assinatura ou modelo excede os limites de texto ou possui assunto inválido.")
            }
            if let email = preset.accountEmail, try MailValidation.recipients(email).count != 1 { throw OrbitaError.invalidData("Associação de conta inválida em uma configuração.") }
            if presetIDs.insert(preset.id).inserted { uniquePresets.append(preset) }
        }
        return OutlookImportManifest(accounts: unique, presets: uniquePresets, warnings: Array(warnings.prefix(20)).map { String($0.prefix(1000)) })
    }
}
