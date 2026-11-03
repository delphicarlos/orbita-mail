import Foundation

public typealias JSONObject = [String: Any]
public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum HTTP {
    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
    public static let transport: HTTPTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw OrbitaError.invalidData("Resposta de rede inválida.") }
        return (data, response)
    }
    public static func object(_ data: Data) throws -> JSONObject {
        guard let result = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw OrbitaError.invalidData("Formato de resposta inesperado do provedor.")
        }
        return result
    }
    public static func token(provider: Provider, values: [String: String], oldRefresh: String = "", transport: HTTPTransport = HTTP.transport) async throws -> OAuthToken {
        var request = URLRequest(url: try OAuth.tokenEndpoint(provider))
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = OAuth.form(values)
        let (data, response) = try await transport(request)
        guard (200..<300).contains(response.statusCode) else {
            throw OrbitaError.authentication("O provedor recusou a autenticação (HTTP \(response.statusCode)). Confira a configuração OAuth e conecte novamente.")
        }
        let json = try object(data)
        guard !json.string("access_token").isEmpty else { throw OrbitaError.authentication("O provedor não retornou uma credencial de acesso.") }
        let refresh = json.string("refresh_token").isEmpty ? oldRefresh : json.string("refresh_token")
        guard !refresh.isEmpty else { throw OrbitaError.authentication("Não foi concedido acesso contínuo. Conecte novamente e autorize acesso offline.") }
        return OAuthToken(accessToken: json.string("access_token"), refreshToken: refresh,
                          expiresAt: Date().addingTimeInterval(json.number("expires_in", default: 3600)), scope: json.string("scope"))
    }
}

public extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String { self[key] as? String ?? "" }
    func object(_ key: String) -> JSONObject { self[key] as? JSONObject ?? [:] }
    func objects(_ key: String) -> [JSONObject] { self[key] as? [JSONObject] ?? [] }
    func flag(_ key: String) -> Bool { self[key] as? Bool ?? false }
    func number(_ key: String, default fallback: Double = 0) -> Double { (self[key] as? NSNumber)?.doubleValue ?? fallback }
    func required(_ key: String) throws -> String {
        let value = string(key)
        guard !value.isEmpty else { throw OrbitaError.invalidData("O provedor retornou um item sem \(key). A fonte não foi atualizada.") }
        return value
    }
}

public func pathID(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
}

public actor ProviderClient {
    public let account: Account
    let vault: TokenVault
    private let transport: HTTPTransport
    let mailWire: MailWireTransport
    private var refreshTask: Task<OAuthToken, Error>?
    private var retryAfter: Date?

    public init(account: Account, vault: TokenVault, transport: @escaping HTTPTransport = HTTP.transport, mailWire: @escaping MailWireTransport = { try await CurlMailTransport.perform($0) }) {
        self.account = account; self.vault = vault; self.transport = transport; self.mailWire = mailWire
    }
    func serverClient() throws -> StandardMailClient {
        guard let configuration = account.serverConfiguration else { throw OrbitaError.authentication("Configure novamente os servidores desta conta.") }
        return StandardMailClient(account: account, configuration: configuration, vault: vault, wire: mailWire)
    }
    public func verifyServerConfiguration() async throws -> MailServerConfiguration { try await serverClient().verify() }

    public static func allowed(_ url: URL, provider: Provider) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        switch provider {
        case .microsoft: return url.host == "graph.microsoft.com" && url.path.hasPrefix("/v1.0/")
        case .google:
            return (url.host == "gmail.googleapis.com" && url.path.hasPrefix("/gmail/v1/")) ||
                (url.host == "www.googleapis.com" && url.path.hasPrefix("/calendar/v3/")) ||
                (url.host == "tasks.googleapis.com" && url.path.hasPrefix("/tasks/v1/"))
        default: return false
        }
    }

    public static func makeURL(_ base: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw OrbitaError.invalidData("Endereço do provedor inválido.") }
        if !query.isEmpty { components.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw OrbitaError.invalidData("Endereço do provedor inválido.") }
        return url
    }

    private func accessToken(force: Bool = false) async throws -> String {
        guard let stored = try await vault.load(OAuthToken.self, key: account.id) else {
            throw OrbitaError.authentication("Conecte novamente a conta \(account.email).")
        }
        if !force && stored.expiresAt > Date().addingTimeInterval(90) { return stored.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let account = account, vault = vault, transport = transport
        let task = Task<OAuthToken, Error> {
            var parameters = ["client_id": account.clientID, "grant_type": "refresh_token", "refresh_token": stored.refreshToken]
            if account.provider == .google,
               let secret = try await vault.load(String.self, key: "google-secret:" + account.clientID), !secret.isEmpty { parameters["client_secret"] = secret }
            var token = try await HTTP.token(provider: account.provider, values: parameters, oldRefresh: stored.refreshToken, transport: transport)
            if token.scope.isEmpty { token.scope = stored.scope }
            try await vault.save(token, key: account.id)
            return token
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    public func request(_ url: URL, method: String = "GET", body: JSONObject? = nil,
                        headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard Self.allowed(url, provider: account.provider) else { throw OrbitaError.invalidData("O provedor retornou um endereço fora da lista permitida.") }
        if let retryAfter, retryAfter > Date() {
            throw OrbitaError.network(429, "Aguarde \(Int(ceil(retryAfter.timeIntervalSinceNow))) segundos para sincronizar esta conta.")
        }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 45
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if account.provider == .microsoft {
            request.setValue("outlook.timezone=\"UTC\", IdType=\"ImmutableId\"", forHTTPHeaderField: "Prefer")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        var result = try await transport(request)
        if result.1.statusCode == 401 && method == "GET" {
            request.setValue("Bearer \(try await accessToken(force: true))", forHTTPHeaderField: "Authorization")
            result = try await transport(request)
        }
        guard (200..<300).contains(result.1.statusCode) else {
            let status = result.1.statusCode
            var message = "Tente sincronizar novamente."
            if status == 401 { message = "Conecte novamente esta conta." }
            if status == 403 { message = "A conta não concedeu permissão para esta função. Confira o consentimento e a política da organização." }
            if status == 412 { message = "O item foi alterado no provedor. Atualize antes de tentar novamente." }
            if status == 429 {
                let header = result.1.value(forHTTPHeaderField: "Retry-After") ?? "60"
                let seconds: Double
                if let number = Double(header) { seconds = max(1, number) }
                else {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    seconds = max(1, formatter.date(from: header)?.timeIntervalSinceNow ?? 60)
                }
                retryAfter = Date().addingTimeInterval(seconds)
                message = "Limite temporário. Aguarde \(Int(ceil(seconds))) segundos."
            }
            throw OrbitaError.network(status, message)
        }
        return result
    }

    public func json(_ url: URL, method: String = "GET", body: JSONObject? = nil, headers: [String: String] = [:]) async throws -> JSONObject {
        let (data, _) = try await request(url, method: method, body: body, headers: headers)
        return data.isEmpty ? [:] : try HTTP.object(data)
    }

    func graph(_ path: String, query: [String: String] = [:]) throws -> URL {
        try Self.makeURL("https://graph.microsoft.com/v1.0" + path, query: query)
    }
    func google(_ base: String, query: [String: String] = [:]) throws -> URL { try Self.makeURL(base, query: query) }

    func graphPages(_ initial: URL) async throws -> [JSONObject] {
        var next: URL? = initial, seen = Set<String>(), result: [JSONObject] = []
        while let url = next {
            try Task.checkCancellation()
            guard seen.insert(url.absoluteString).inserted else { throw OrbitaError.invalidData("Paginação repetida pelo provedor. A fonte não foi atualizada.") }
            let page = try await json(url)
            guard let values = page["value"] as? [JSONObject] else { throw OrbitaError.invalidData("Página Microsoft sem coleção de itens.") }
            result += values
            let link = page.string("@odata.nextLink")
            if !link.isEmpty {
                guard let linkURL = URL(string: link), Self.allowed(linkURL, provider: .microsoft) else { throw OrbitaError.invalidData("Link de paginação inválido.") }
                next = linkURL
            } else { next = nil }
        }
        return result
    }

    func googlePages(_ base: String, query: [String: String] = [:]) async throws -> [JSONObject] {
        var parameters = query, seen = Set<String>(), result: [JSONObject] = []
        while true {
            try Task.checkCancellation()
            let page = try await json(google(base, query: parameters))
            result += page.objects("items")
            let next = page.string("nextPageToken")
            if next.isEmpty { break }
            guard seen.insert(next).inserted else { throw OrbitaError.invalidData("Paginação repetida pelo provedor. A fonte não foi atualizada.") }
            parameters["pageToken"] = next
        }
        return result
    }

    public func profile() async throws -> (String, String) {
        if !account.provider.usesOAuth { return (account.email, account.name) }
        if account.provider == .microsoft {
            let data = try await json(graph("/me", query: ["$select": "mail,userPrincipalName,displayName"]))
            let email = data.string("mail").isEmpty ? try data.required("userPrincipalName") : data.string("mail")
            return (email, data.string("displayName"))
        }
        let data = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/profile"))
        let email = try data.required("emailAddress")
        return (email, email.components(separatedBy: "@").first ?? email)
    }
}
