import Foundation
import CMailTransport

/// Only FETCH needs this path: macOS curl's command-line custom FETCH truncates
/// literals. System libcurl still handles TLS, STARTTLS and authentication; we
/// frame the authenticated response by literal byte count rather than by lines.
enum NativeIMAPTransport {
    private final class Operation: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: OpaquePointer?
        private var cancelled = false
        func attach(_ pointer: OpaquePointer) throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }; connection = pointer
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true; if let connection { orbita_imap_cancel(connection) }
        }
        func detach() { lock.lock(); connection = nil; lock.unlock() }
    }
    /// Returns the end of a complete tagged response, ignoring tag-shaped bytes
    /// inside literals. nil means more bytes are required.
    static func responseEnd(_ data: Data, tag: String) throws -> Int? {
        var cursor = 0
        while cursor < data.count {
            guard let newline = data[cursor...].firstIndex(of: 10) else { return nil }
            let end = newline + 1
            let line = String(decoding: data[cursor..<end], as: UTF8.self).trimmingCharacters(in: .newlines)
            cursor = end
            if line.hasPrefix(tag + " ") {
                guard line.uppercased().hasPrefix(tag.uppercased() + " OK") else {
                    throw OrbitaError.invalidData("O servidor IMAP recusou a operação. Atualize a caixa e confira as permissões.")
                }
                return cursor
            }
            if line.uppercased().hasPrefix("* BYE") { throw OrbitaError.network(0, "O IMAP encerrou a sessão.") }
            if let raw = IMAPReply.firstMatch(#"\{(\d+)\+?\}$"#, line) {
                guard let length = Int(raw) else { throw OrbitaError.invalidData("Tamanho de literal IMAP inválido.") }
                guard length <= 32_000_000 else { throw OrbitaError.invalidData("Literal IMAP maior que 32 MB.") }
                guard data.count - cursor >= length else { return nil }
                cursor += length
            }
        }
        return nil
    }
    static func check(_ code: Int32) throws {
        switch code {
        case 0: return
        case 42: throw CancellationError()
        case 60, 51: throw OrbitaError.authentication("Certificado TLS não confiável ou nome do servidor divergente. Confira o certificado com a TI.")
        case 67, 94: throw OrbitaError.authentication("O IMAP recusou o acesso. Confira as credenciais e políticas do servidor.")
        case 28: throw OrbitaError.network(0, "Tempo de conexão IMAP esgotado. Confira servidor, rede e VPN.")
        default: throw OrbitaError.network(0, "A conexão IMAP foi interrompida (código \(code)). A cópia anterior foi preservada.")
        }
    }
    static func perform(_ request: MailWireRequest) async throws -> Data {
        guard ["imap", "imaps"].contains(request.url.scheme ?? ""), request.url.user == nil,
              request.url.password == nil, let command = request.command, command.hasPrefix("UID FETCH "),
              !MailServerConfiguration.hasControls(command) else { throw OrbitaError.invalidData("Requisição IMAP inválida.") }
        let path = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let pieces = String(path.dropFirst()).components(separatedBy: ";UIDVALIDITY=")
        guard pieces.count == 2, let mailbox = pieces[0].removingPercentEncoding,
              let validity = UInt32(pieces[1]), validity > 0, !MailServerConfiguration.hasControls(mailbox), mailbox.utf8.count <= 500 else { throw OrbitaError.invalidData("FETCH exige pasta e UIDVALIDITY.") }
        var root = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
        root.path = "/"; root.query = nil; root.fragment = nil
        let rootURL = root.url!.absoluteString
        let operation = Operation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                guard let connection = orbita_imap_create() else { throw OrbitaError.network(0, "Não foi possível iniciar o IMAP.") }
                defer { operation.detach(); orbita_imap_close(connection) }
                try operation.attach(connection)
                let code = rootURL.withCString { url in request.username.withCString { user in request.password.withCString { password in
                    orbita_imap_connect(connection, url, user, password)
                } } }
                try check(code)
                func exchange(_ text: String, tag: String) throws -> Data {
                    let bytes = Data((tag + " " + text + "\r\n").utf8)
                    var sent = 0
                    while sent < bytes.count {
                        var count = 0
                        let code = bytes.withUnsafeBytes { buffer in orbita_imap_send(connection, buffer.bindMemory(to: UInt8.self).baseAddress! + sent, bytes.count - sent, &count) }
                        if code == 81 { continue }; try check(code); sent += count
                    }
                    var response = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
                    while true {
                        var count = 0
                        let code = orbita_imap_receive(connection, &buffer, buffer.count, &count)
                        if code == 81 { continue }; try check(code)
                        guard count > 0 else { throw OrbitaError.network(0, "Resposta IMAP interrompida.") }
                        guard response.count + count <= 32_000_000 else { throw OrbitaError.invalidData("Resposta IMAP maior que 32 MB.") }
                        response.append(contentsOf: buffer.prefix(count))
                        if let end = try responseEnd(response, tag: tag) { return Data(response.prefix(end)) }
                    }
                }
                let selected = try exchange("SELECT " + IMAPReply.quoted(mailbox), tag: "ORBSELECT")
                guard try IMAPReply.validity(selected) == validity else { throw OrbitaError.invalidData("UIDVALIDITY mudou. Atualize a caixa antes de ler ou alterar mensagens.") }
                return try exchange(command, tag: "ORBFETCH")
            }.value
        } onCancel: { operation.cancel() }
    }
}
