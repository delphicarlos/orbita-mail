import SwiftUI
import OrbitaCore

struct ServerSetupRequest: Identifiable {
    let id = UUID()
    var account: Account?
    var email = ""
    var name = ""
    var host = ""
    var provider: Provider = .imap
}

struct ServerAccountView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var provider: Provider
    @State private var email: String
    @State private var name: String
    @State private var config: MailServerConfiguration
    @State private var password = ""
    @State private var smtpPassword = ""
    @State private var caldavPassword = ""
    @State private var advanced = false
    @State private var error: String?
    @State private var connectionTask: Task<Void, Never>?
    private let editing: Bool
    init(request: ServerSetupRequest) {
        editing = request.account != nil
        _provider = State(initialValue: request.account?.provider ?? request.provider)
        _email = State(initialValue: request.account?.email ?? request.email)
        _name = State(initialValue: request.account?.name ?? request.name)
        var config = request.account?.serverConfiguration ?? MailServerConfiguration()
        if request.account == nil { config.incomingHost = request.host; config.username = request.email; if request.provider == .pop3 { config.incomingPort = 995 } }
        _config = State(initialValue: config)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editing ? "Configurar servidores" : "Outro provedor").font(.system(size: 22, weight: .semibold))
                    Text("Conecte aos serviços disponibilizados pela empresa ou pelo provedor.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar") { dismiss() }.disabled(model.isConnecting)
            }
            ScrollView {
                Form {
                    Section("Conta") {
                        TextField("Email", text: $email).disabled(editing)
                        TextField("Nome de exibição", text: $name)
                        Picker("Serviço de email", selection: $provider) {
                            Text("IMAP + SMTP").tag(Provider.imap)
                            Text("POP3 + SMTP").tag(Provider.pop3)
                            Text("Exchange próprio (EWS)").tag(Provider.exchange)
                        }.disabled(editing)
                        TextField(provider == .exchange ? "Usuário · domínio\\usuário ou email" : "Usuário de entrada", text: $config.username)
                        SecureField(editing ? "Senha · deixe vazio para manter a salva" : "Senha ou senha de aplicativo", text: $password)
                    }
                    if provider == .exchange {
                        Section("Exchange próprio") {
                            TextField("URL EWS · https://servidor/EWS/Exchange.asmx", text: $config.ewsURL)
                            Picker("Autenticação", selection: $config.ewsAuthentication) { ForEach(ServerAuthentication.allCases) { Text($0.title).tag($0) } }
                            hint("Requer Exchange 2013 SP1 ou posterior com EWS e autenticação habilitados pela TI. Para Microsoft 365, use a conexão OAuth Microsoft. Esta opção não altera políticas corporativas.")
                        }
                    } else {
                        Section(provider == .pop3 ? "Recebimento · POP3" : "Recebimento · IMAP") {
                            TextField("Servidor de entrada", text: $config.incomingHost)
                            HStack {
                                TextField("Porta", value: $config.incomingPort, format: .number.grouping(.never)).frame(width: 130)
                                Picker("Segurança", selection: $config.incomingSecurity) { ForEach(MailSecurity.allCases) { Text($0.title).tag($0) } }
                            }
                            if provider == .pop3 { hint("POP3 mantém mensagens no servidor. Só a Entrada é remota; lido e sinalizador são locais. Não oferece pastas nem exclusão remota. Enviados e rascunhos ficam neste Mac. Prefira IMAP quando disponível.") }
                        }
                        Section("Envio · SMTP") {
                            TextField("Servidor SMTP", text: $config.smtpHost)
                            HStack {
                                TextField("Porta", value: $config.smtpPort, format: .number.grouping(.never)).frame(width: 130)
                                Picker("Segurança", selection: $config.smtpSecurity) { ForEach(MailSecurity.allCases) { Text($0.title).tag($0) } }
                            }
                            Toggle("Mesmo usuário e senha do recebimento", isOn: $config.sameSMTPAuthentication)
                            if !config.sameSMTPAuthentication {
                                TextField("Usuário SMTP", text: $config.smtpUsername)
                                SecureField(editing ? "Senha SMTP · deixe vazio para manter" : "Senha SMTP", text: $smtpPassword)
                            }
                        }
                        Section("Agenda e tarefas · CalDAV opcional") {
                            TextField("URL HTTPS CalDAV · opcional", text: $config.caldavURL)
                            hint("Email não inclui agenda automaticamente. CalDAV depende do provedor; respostas a convites exigem agendamento no servidor. Convites recorrentes CalDAV são somente leitura nesta versão.")
                            if !config.caldavURL.isEmpty {
                                Toggle("Mesmo usuário e senha no CalDAV", isOn: $config.sameCalDAVAuthentication)
                                if !config.sameCalDAVAuthentication {
                                    TextField("Usuário CalDAV", text: $config.caldavUsername)
                                    SecureField(editing ? "Senha CalDAV · deixe vazio para manter" : "Senha CalDAV", text: $caldavPassword)
                                }
                            }
                        }
                        if provider == .imap {
                            DisclosureGroup("Pastas IMAP", isExpanded: $advanced) {
                                Toggle("Identificar pastas padrão pelo servidor", isOn: $config.discoverFolders)
                                ForEach(MailFolder.allCases) { folder in
                                    TextField(folder.title, text: Binding(get: { config.folders[folder.rawValue] ?? "" }, set: { config.folders[folder.rawValue] = $0 }))
                                }
                                Toggle("Salvar cópia em Enviados por IMAP", isOn: $config.saveSentCopy)
                                hint("Desative a cópia se o SMTP já salvar em Enviados, para evitar duplicação. Movimentação exige IMAP MOVE. O aplicativo não executa limpeza global da lixeira.")
                            }
                        }
                    }
                }.formStyle(.grouped).disabled(model.isConnecting)
            }
            hint("Senhas no Keychain deste usuário do Mac. TLS válido é obrigatório; certificados não são ignorados. O provedor pode exigir senha de aplicativo, VPN ou liberação da TI.")
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                if model.isConnecting {
                    ProgressView().controlSize(.small)
                    Text("Testando autenticação dos servidores…").font(.system(size: 12))
                    Button("Cancelar teste") { connectionTask?.cancel() }
                }
                Spacer()
                Button(editing ? "Testar e salvar" : "Testar e conectar") { connect() }.buttonStyle(.borderedProminent).disabled(model.isConnecting)
            }
        }.padding(22).frame(width: 760, height: 760)
        .onChange(of: provider) { _, value in error = nil; if !editing { config.incomingPort = value == .pop3 ? 995 : 993; config.incomingSecurity = .tls } }
        .onChange(of: config.incomingSecurity) { _, value in
            if [993, 143, 995, 110].contains(config.incomingPort) { config.incomingPort = provider == .pop3 ? (value == .tls ? 995 : 110) : (value == .tls ? 993 : 143) }
        }
        .onChange(of: config.smtpSecurity) { _, value in if [465, 587].contains(config.smtpPort) { config.smtpPort = value == .tls ? 465 : 587 } }
        .onDisappear { connectionTask?.cancel() }
    }
    private func hint(_ value: String) -> some View { Text(value).font(.system(size: 11)).foregroundStyle(.secondary) }
    private func connect() {
        error = nil
        var normalized = config
        normalized.incomingHost = config.incomingHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.smtpHost = config.smtpHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        normalized.username = config.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.username.isEmpty { normalized.username = email.trimmingCharacters(in: .whitespacesAndNewlines) }
        normalized.ewsURL = config.ewsURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.caldavURL = provider == .exchange ? "" : config.caldavURL.trimmingCharacters(in: .whitespacesAndNewlines)
        connectionTask = Task {
            if await model.connectServer(provider: provider, email: email, name: name, configuration: normalized,
                credentials: ServerCredentials(password: password, smtpPassword: smtpPassword, caldavPassword: caldavPassword)) {
                password = ""; smtpPassword = ""; caldavPassword = ""; dismiss()
            } else { error = model.notice }
        }
    }
}
