import Foundation
import CryptoKit
import Security

public enum OAuth {
    public static func randomString() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OrbitaError.authentication("Não foi possível iniciar uma sessão segura.")
        }
        return Data(bytes).base64URL
    }
    public static func challenge(_ verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
    public static func scopes(_ provider: Provider, mailSettings: Bool = false) -> String {
        let base: String = switch provider {
        case .microsoft:
            "offline_access https://graph.microsoft.com/User.Read https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/Tasks.ReadWrite"
        case .google:
            "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.calendarlist.readonly https://www.googleapis.com/auth/tasks"
        default: ""
        }
        let extra = provider == .microsoft ? "https://graph.microsoft.com/MailboxSettings.ReadWrite" : "https://www.googleapis.com/auth/gmail.settings.basic"
        return base + (mailSettings && provider.usesOAuth ? " " + extra : "")
    }
    public static func tokenEndpoint(_ provider: Provider) throws -> URL {
        guard provider.usesOAuth else { throw OrbitaError.authentication("Configure os servidores desta conta em Outro provedor.") }
        return URL(string: provider == .microsoft ? "https://login.microsoftonline.com/common/oauth2/v2.0/token" : "https://oauth2.googleapis.com/token")!
    }
    public static func authorizationURL(provider: Provider, clientID: String, redirect: String, state: String, verifier: String, loginHint: String? = nil, mailSettings: Bool = false) throws -> URL {
        guard provider.usesOAuth else { throw OrbitaError.authentication("Este provedor utiliza a configuração de servidores, não este fluxo OAuth.") }
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrbitaError.authentication("Configure primeiro o ID do aplicativo OAuth deste provedor.")
        }
        var url = URLComponents(string: provider == .microsoft ? "https://login.microsoftonline.com/common/oauth2/v2.0/authorize" : "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = ["client_id": clientID, "response_type": "code", "redirect_uri": redirect,
                     "scope": scopes(provider, mailSettings: mailSettings), "state": state, "code_challenge": challenge(verifier), "code_challenge_method": "S256"]
        items["prompt"] = provider == .microsoft ? "select_account" : "consent select_account"
        if provider == .google { items["access_type"] = "offline" }
        if let loginHint, !loginHint.isEmpty { items["login_hint"] = loginHint }
        url.queryItems = items.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }
    public static func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        // '+' must be escaped: form parsers otherwise decode it as a space.
        return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    public static func validateIdentity(expectedEmail: String?, actualEmail: String) throws {
        if let expectedEmail, actualEmail.caseInsensitiveCompare(expectedEmail) != .orderedSame {
            throw OrbitaError.authentication("A conta autorizada foi \(actualEmail), mas a importação selecionada era \(expectedEmail). Essa conexão não foi adicionada. Escolha a conta correta ou conecte-a separadamente.")
        }
    }
    public static func callbackCode(_ target: String, expectedState: String, path: String = "/oauth/callback") throws -> String {
        guard let url = URLComponents(string: "http://127.0.0.1" + target), url.path == path,
              let query = url.queryItems, query.filter({ $0.name == "state" }).count == 1,
              query.first(where: { $0.name == "state" })?.value == expectedState else {
            throw OrbitaError.authentication("Resposta de autenticação inválida. Tente conectar novamente.")
        }
        if query.contains(where: { $0.name == "error" }) { throw OrbitaError.authentication("A conexão foi recusada ou cancelada no provedor.") }
        guard query.filter({ $0.name == "code" }).count == 1,
              let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OrbitaError.authentication("O provedor não retornou o código de autorização.")
        }
        return code
    }
}

public extension Data {
    var base64URL: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(base64URL: String) {
        let base = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}

public actor TokenVault {
    private let service: String
    public init(service: String = "br.com.intellitouch.orbita-mail") { self.service = service }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false]
    }
    public func save<T: Encodable>(_ value: T, key: String) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(key); item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw OrbitaError.storage("Não foi possível guardar a credencial no Keychain.")
            }
        } else if status != errSecSuccess { throw OrbitaError.storage("Não foi possível atualizar a credencial no Keychain.") }
    }
    public func load<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        var request = query(key); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw OrbitaError.authentication("Desbloqueie o Keychain para acessar as contas.")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    public func remove(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OrbitaError.storage("Não foi possível remover a credencial do Keychain.") }
    }
}
