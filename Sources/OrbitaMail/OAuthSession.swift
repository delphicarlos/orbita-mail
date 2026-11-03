import AppKit
import Network
import OrbitaCore

@MainActor
final class OAuthSession {
    private var listener: NWListener?
    private var completion: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var expectedState = ""
    private var expectedHost = ""
    private var requestPath = "/oauth/callback"
    private var waitingConnections: [NWConnection] = []
    private var cancelled = false

    func connect(provider: Provider, clientID: String, googleSecret: String, loginHint: String? = nil, mailSettings: Bool = false) async throws -> OAuthToken {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrbitaError.authentication("Informe o ID do aplicativo OAuth nas configurações.")
        }
        let verifier = try OAuth.randomString()
        expectedState = try OAuth.randomString()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        // Network.framework requires an accept handler before starting the listener.
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection) }
        }
        defer { cleanup() }
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            var completed = false
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !completed else { return }
                    switch state {
                    case .ready:
                        completed = true
                        if let port = listener.port { ready.resume(returning: port.rawValue) }
                        else { ready.resume(throwing: OrbitaError.authentication("Porta local de autenticação indisponível.")) }
                    case .failed:
                        completed = true; ready.resume(throwing: OrbitaError.authentication("Não foi possível abrir o retorno local de autenticação."))
                    case .cancelled:
                        completed = true; ready.resume(throwing: CancellationError())
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        let host = provider == .microsoft ? "localhost" : "127.0.0.1"
        expectedHost = "\(host):\(port)"
        let redirect = "http://\(expectedHost)\(requestPath)"
        let url = try OAuth.authorizationURL(provider: provider, clientID: clientID, redirect: redirect, state: expectedState, verifier: verifier, loginHint: loginHint, mailSettings: mailSettings)
        let code: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) }
                    catch { return }
                    self?.finish(.failure(OrbitaError.authentication("O tempo para conectar expirou. Tente novamente.")))
                }
                guard NSWorkspace.shared.open(url) else {
                    finish(.failure(OrbitaError.authentication("Não foi possível abrir o navegador de autenticação."))); return
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel() } }
        var values = ["client_id": clientID, "code": code, "redirect_uri": redirect,
                      "grant_type": "authorization_code", "code_verifier": verifier]
        if provider == .google && !googleSecret.isEmpty { values["client_secret"] = googleSecret }
        return try await HTTP.token(provider: provider, values: values)
    }

    func cancel() { cancelled = true; listener?.cancel(); finish(.failure(CancellationError())) }

    private func receive(_ connection: NWConnection, accumulated: Data = Data()) {
        if accumulated.isEmpty {
            guard waitingConnections.count < 8 else { connection.cancel(); return }
            waitingConnections.append(connection); connection.start(queue: .main)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .cancelled = state {
                    Task { @MainActor in self?.waitingConnections.removeAll { $0 === connection } }
                }
            }
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, done, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var bytes = accumulated; bytes.append(chunk ?? Data())
                guard bytes.count <= 8192 else { connection.cancel(); return }
                guard let text = String(data: bytes, encoding: .utf8) else { connection.cancel(); return }
                if !text.contains("\r\n\r\n") {
                    if !done { self.receive(connection, accumulated: bytes) } else { connection.cancel() }
                    return
                }
                let lines = text.components(separatedBy: "\r\n")
                let request = (lines.first ?? "").split(separator: " ")
                let host = lines.first { $0.lowercased().hasPrefix("host:") }?.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard request.count == 3, request[0] == "GET", host == self.expectedHost else {
                    self.reply(connection, status: "400 Bad Request", message: "Requisição inválida."); return
                }
                do {
                    let code = try OAuth.callbackCode(String(request[1]), expectedState: self.expectedState)
                    self.reply(connection, status: "200 OK", message: "Conexão recebida. Você pode fechar esta aba e voltar ao Órbita.")
                    self.finish(.success(code))
                } catch {
                    self.reply(connection, status: "400 Bad Request", message: "Conexão não autorizada. Volte ao Órbita para tentar novamente.")
                    // Ignore unrelated/invalid requests. An explicit provider denial ends this session.
                    if String(request[1]).contains("error=") && String(request[1]).contains(self.expectedState) { self.finish(.failure(error)) }
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, status: String, message: String) {
        let body = "<!doctype html><html lang=\"pt-BR\"><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width\"><title>Órbita</title><h1>Órbita</h1><p>\(message)</p></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Security-Policy: default-src 'none'; frame-ancestors 'none'\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<String, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion.resume(with: result)
        listener?.cancel(); timeoutTask?.cancel()
    }
    private func cleanup() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil; timeoutTask?.cancel(); timeoutTask = nil
        for connection in waitingConnections { connection.cancel() }
        waitingConnections.removeAll()
    }
}
