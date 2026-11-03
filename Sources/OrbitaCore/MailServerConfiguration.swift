import Foundation

public enum MailSecurity: String, Codable, CaseIterable, Identifiable, Sendable {
    case tls, startTLS
    public var id: String { rawValue }
    public var title: String { self == .tls ? "SSL/TLS" : "STARTTLS obrigatório" }
}
public enum ServerAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case password, ntlm
    public var id: String { rawValue }
    public var title: String { self == .ntlm ? "NTLM · domínio\\usuário" : "Usuário e senha" }
}

/// Connection metadata only. Passwords are stored separately in the user's Keychain.
public struct MailServerConfiguration: Codable, Hashable, Sendable {
    public var incomingHost = ""
    public var incomingPort = 993
    public var incomingSecurity: MailSecurity = .tls
    public var username = ""
    public var smtpHost = ""
    public var smtpPort = 587
    public var smtpSecurity: MailSecurity = .startTLS
    public var smtpUsername = ""
    public var sameSMTPAuthentication = true
    public var folders: [String: String] = ["inbox": "INBOX", "sent": "Sent", "drafts": "Drafts", "archive": "Archive", "trash": "Trash", "junk": "Junk"]
    public var discoverFolders = true
    public var saveSentCopy = true
    public var ewsURL = ""
    public var ewsAuthentication: ServerAuthentication = .ntlm
    public var caldavURL = ""
    public var caldavUsername = ""
    public var sameCalDAVAuthentication = true
    public var caldavScheduling = false
    public init() {}

    public func validated(provider: Provider) throws -> Self {
        guard !provider.usesOAuth else { throw OrbitaError.invalidData("Utilize OAuth para este provedor.") }
        guard !username.isEmpty, username.count <= 500, !Self.hasControls(username), !username.contains(":") else { throw OrbitaError.invalidData("Informe um usuário válido para o servidor, sem dois-pontos ou caracteres de controle.") }
        if provider == .exchange { _ = try Self.secureWebURL(ewsURL) }
        else {
            try Self.validateHost(incomingHost, port: incomingPort)
            try Self.validateHost(smtpHost, port: smtpPort)
            if !sameSMTPAuthentication && (smtpUsername.isEmpty || smtpUsername.contains(":") || Self.hasControls(smtpUsername)) { throw OrbitaError.invalidData("Informe um usuário SMTP válido.") }
            guard folders.values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 500 && !Self.hasControls($0) }) else { throw OrbitaError.invalidData("Nome de pasta inválido.") }
        }
        if !caldavURL.isEmpty {
            _ = try Self.secureWebURL(caldavURL)
            guard sameCalDAVAuthentication || (!caldavUsername.isEmpty && caldavUsername.count <= 500 && !caldavUsername.contains(":") && !Self.hasControls(caldavUsername)) else { throw OrbitaError.invalidData("Informe o usuário CalDAV.") }
        }
        return self
    }
    public static func validateHost(_ host: String, port: Int) throws {
        guard !host.isEmpty, host.count <= 253, (1...65535).contains(port),
              host.range(of: #"^[A-Za-z0-9:][A-Za-z0-9.:-]*$"#, options: .regularExpression) != nil,
              !host.contains("..") else { throw OrbitaError.invalidData("Informe somente o nome/IP do servidor e uma porta entre 1 e 65535, sem URL, caminho ou usuário.") }
    }
    public static func secureWebURL(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.fragment == nil, url.query == nil,
              !hasControls(string) else { throw OrbitaError.invalidData("Informe uma URL HTTPS do servidor, sem senha, parâmetros ou fragmento.") }
        return url
    }
    static func hasControls(_ value: String) -> Bool { value.rangeOfCharacter(from: .controlCharacters) != nil }
    public func folder(_ folder: MailFolder) throws -> String {
        guard let name = folders[folder.rawValue], !name.isEmpty else { throw OrbitaError.invalidData("Configure a pasta \(folder.title) desta conta.") }
        return name
    }
}

public struct ServerCredentials: Codable, Sendable {
    public var password: String
    public var smtpPassword: String
    public var caldavPassword: String
    public init(password: String, smtpPassword: String = "", caldavPassword: String = "") { self.password = password; self.smtpPassword = smtpPassword; self.caldavPassword = caldavPassword }
    public static func key(_ accountID: String) -> String { "server-credentials:" + accountID }
}

public struct MailWireRequest: Sendable {
    public var url: URL
    public var username: String
    public var password: String
    public var command: String?
    public var upload: Data?
    public var sender: String?
    public var recipients: [String]
    public var ntlm: Bool
    public var headers: [String]
    public var method: String?
    public var includeHeaders: Bool
    public init(url: URL, username: String, password: String, command: String? = nil, upload: Data? = nil,
                sender: String? = nil, recipients: [String] = [], ntlm: Bool = false,
                headers: [String] = [], method: String? = nil, includeHeaders: Bool = false) {
        self.url = url; self.username = username; self.password = password; self.command = command
        self.upload = upload; self.sender = sender; self.recipients = recipients; self.ntlm = ntlm
        self.headers = headers; self.method = method; self.includeHeaders = includeHeaders
    }
}
struct POPHeaderUnsupported: Error {}

public typealias MailWireTransport = @Sendable (MailWireRequest) async throws -> Data

/// Uses the macOS system curl for TLS/SASL/NTLM. No shell, insecure TLS, proxy,
/// redirect, password argument, credential file or downloaded executable is used.
public enum CurlMailTransport {
    private final class RunningProcess: @unchecked Sendable {
        let lock = NSLock()
        var process: Process?
        var cancelled = false
        func start(_ value: Process) throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            process = value; try value.run()
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
        func checkCancellation() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }
    static func quote(_ value: String) throws -> String {
        guard !MailServerConfiguration.hasControls(value) else { throw OrbitaError.invalidData("A configuração contém caracteres de controle não suportados.") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func options(_ request: MailWireRequest, uploadPath: String?) throws -> String {
        guard let scheme = request.url.scheme, ["imap", "imaps", "pop3", "pop3s", "smtp", "smtps", "https"].contains(scheme),
              request.url.host != nil, request.url.user == nil, request.url.password == nil else { throw OrbitaError.invalidData("Protocolo de conexão inválido.") }
        var lines = ["silent", "show-error", "ssl-reqd", "connect-timeout = 15", "max-time = 45", "max-redirs = 0",
                     "proto = \"=imap,imaps,pop3,pop3s,smtp,smtps,https\"", "proxy = \"\"", "noproxy = \"*\"",
                     "url = " + (try quote(request.url.absoluteString)), "user = " + (try quote(request.username + ":" + request.password))]
        if scheme != "https" || !request.includeHeaders { lines.append("fail") }
        if let command = request.command { lines.append("request = " + (try quote(command))) }
        if let method = request.method { lines.append("request = " + (try quote(method))) }
        if let sender = request.sender { lines.append("mail-from = " + (try quote(sender))) }
        for recipient in request.recipients { lines.append("mail-rcpt = " + (try quote(recipient))) }
        if request.ntlm { lines.append("ntlm") }
        if request.includeHeaders { lines.append("include") }
        for header in request.headers { lines.append("header = " + (try quote(header))) }
        if let uploadPath {
            lines.append((scheme == "https" ? "data-binary = " : "upload-file = ") + (try quote((scheme == "https" ? "@" : "") + uploadPath)))
        }
        return lines.joined(separator: "\n") + "\n"
    }
    public static func perform(_ request: MailWireRequest) async throws -> Data {
        if ["imap", "imaps"].contains(request.url.scheme ?? ""), request.command?.hasPrefix("UID FETCH ") == true {
            return try await NativeIMAPTransport.perform(request)
        }
        let running = RunningProcess()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Orbita-transfer-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: temporary) }
                var uploadPath: String?
                if let upload = request.upload {
                    let file = temporary.appendingPathComponent("message")
                    guard FileManager.default.createFile(atPath: file.path, contents: upload, attributes: [.posixPermissions: 0o600]) else { throw OrbitaError.storage("Não foi possível preparar a transmissão.") }
                    uploadPath = file.path
                }
                let configuration = try options(request, uploadPath: uploadPath)
                let process = Process(), input = Pipe(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                process.arguments = ["--disable", "--config", "-"]
                process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try running.start(process)
                do { try input.fileHandleForWriting.write(contentsOf: Data(configuration.utf8)); try input.fileHandleForWriting.close() }
                catch { running.cancel(); throw OrbitaError.network(0, "Falha ao iniciar a conexão com o servidor.") }
                var result = Data()
                while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    guard result.count + chunk.count <= 32_000_000 else { running.cancel(); throw OrbitaError.invalidData("A resposta excedeu o limite de 32 MB desta versão.") }
                    result.append(chunk)
                }
                process.waitUntilExit()
                try running.checkCancellation()
                try Task.checkCancellation()
                guard process.terminationStatus == 0 else {
                    switch process.terminationStatus {
                    case 8 where request.url.scheme?.hasPrefix("pop3") == true && request.command?.hasPrefix("TOP ") == true,
                         9 where request.url.scheme?.hasPrefix("pop3") == true && request.command?.hasPrefix("TOP ") == true: throw POPHeaderUnsupported()
                    case 60, 51: throw OrbitaError.network(0, "Certificado TLS não confiável ou nome do servidor divergente. Peça à TI a configuração correta do certificado.")
                    case 67, 94: throw OrbitaError.authentication("O servidor recusou o acesso. Confira usuário, senha de aplicativo, protocolos habilitados e políticas da organização.")
                    case 28: throw OrbitaError.network(0, "Tempo de conexão esgotado. Confira o servidor, a porta e o acesso à rede/VPN.")
                    default: throw OrbitaError.network(0, "O servidor recusou ou interrompeu a operação (código \(process.terminationStatus)). Confira a configuração e o estado remoto antes de repetir uma escrita.")
                    }
                }
                return result
            }.value
        } onCancel: { running.cancel() }
    }
}
