import SwiftUI
import OrbitaCore

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var config = OAuthConfiguration()
    @State private var googleSecret = ""
    @State private var showSetup = false
    @State private var removal: Account?
    @State private var showImport = false
    @State private var serverSetup: ServerSetupRequest?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Suas contas").font(.system(size: 23, weight: .semibold))
                    Text("Email, calendários e tarefas com a conta de origem preservada.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Concluir") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isConnecting)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.isDemo {
                        Label("Demonstração: as contas abaixo são fictícias. Volte ao ambiente real para conectar suas contas.", systemImage: "testtube.2")
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                    ForEach(model.accounts) { account in
                        HStack(spacing: 12) {
                            Circle().fill(OrbitaStyle.color(account.colorIndex)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.email).font(.system(size: 14, weight: .medium))
                                Text(account.provider.title).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.isDemo {
                                if !account.provider.usesOAuth { Button("Servidores…") { serverSetup = ServerSetupRequest(account: account) }.disabled(model.isConnecting) }
                                Button("Desconectar") { removal = account }.disabled(model.busy)
                            }
                        }
                        Divider()
                    }
                    if model.accounts.isEmpty {
                        Text("Nenhuma conta conectada").font(.headline)
                        Text("Conecte Microsoft ou Google pelo navegador, ou escolha Outro provedor para informar os servidores da empresa.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Button { showImport = true } label: { Label("Importar do Outlook…", systemImage: "square.and.arrow.down") }
                        .disabled(model.isDemo || model.isConnecting)
                    if !model.importedAccounts.isEmpty {
                        Text("Contas importadas do Outlook").font(.headline)
                        Text("Os endereços foram importados. Autorize ou configure os servidores de cada conta.").font(.system(size: 12)).foregroundStyle(.secondary)
                        ForEach(model.importedAccounts) { candidate in
                            VStack(alignment: .leading, spacing: 7) {
                                HStack {
                                    Text(candidate.email).font(.system(size: 13, weight: .medium))
                                    Spacer()
                                    if model.accounts.contains(where: { $0.email.caseInsensitiveCompare(candidate.email) == .orderedSame && $0.provider == candidate.provider }) {
                                        Label("Conectada", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                                    } else if let provider = candidate.provider, !provider.usesOAuth {
                                        Button("Configurar servidores…") { serverSetup = ServerSetupRequest(email: candidate.email, name: candidate.displayName, host: candidate.server ?? "", provider: provider) }.disabled(model.isConnecting)
                                    } else if let provider = candidate.provider {
                                        Button("Autorizar \(provider == .microsoft ? "Microsoft" : "Google")") {
                                            Task { await model.connect(provider, expectedEmail: candidate.email) }
                                        }.disabled(model.isConnecting || model.configuration.clientID(for: provider).isEmpty)
                                    }
                                }
                                if !model.accounts.contains(where: { $0.email.caseInsensitiveCompare(candidate.email) == .orderedSame && $0.provider == candidate.provider }) {
                                    Picker("Provedor", selection: Binding(get: { candidate.provider?.rawValue ?? "" }, set: { value in Task { await model.updateImportedProvider(candidate, provider: Provider(rawValue: value)) } })) {
                                        Text("Identificar provedor").tag("")
                                        ForEach(Provider.allCases) { Text($0.title).tag($0.rawValue) }
                                    }.font(.system(size: 11))
                                    Text("Escolha Microsoft 365 para nuvem, Exchange próprio para EWS ou o protocolo disponibilizado pelo provedor. Senhas não são importadas.").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                    HStack(spacing: 12) {
                        Button { Task { await model.connect(.microsoft) } } label: { Label("Conectar Microsoft", systemImage: "square.grid.2x2") }
                            .disabled(model.isDemo || model.isConnecting || model.configuration.microsoftClientID.isEmpty)
                        Button { Task { await model.connect(.google) } } label: { Label("Conectar Google", systemImage: "envelope") }
                            .disabled(model.isDemo || model.isConnecting || model.configuration.googleClientID.isEmpty)
                        Button("Outro provedor…") { serverSetup = ServerSetupRequest() }.disabled(model.isDemo || model.isConnecting)
                    }.controlSize(.large)
                    if model.isConnecting {
                        HStack { ProgressView().controlSize(.small); Text("Conclua a autorização no navegador. A sessão expira em 3 minutos."); Button("Cancelar") { model.cancelConnection() } }.font(.system(size: 12))
                    }
                    Divider()
                    DisclosureGroup(isExpanded: $showSetup) {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Microsoft 365 / Outlook").font(.system(size: 14, weight: .semibold))
                            Text("Registre um aplicativo público para desktop no Microsoft Entra. Cadastre o retorno http://localhost/oauth/callback na plataforma móvel/desktop e autorize as permissões delegadas User.Read, Mail.ReadWrite, Mail.Send, Calendars.ReadWrite e Tasks.ReadWrite. Para contas de organizações diferentes, o registro precisa permitir os tipos de conta apropriados.")
                                .font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                            Link("Documentação de autenticação Microsoft", destination: URL(string: "https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow")!)
                            TextField("ID do aplicativo Microsoft", text: $config.microsoftClientID).textFieldStyle(.roundedBorder)
                            Divider()
                            Text("Google / Gmail").font(.system(size: 14, weight: .semibold))
                            Text("No Google Cloud, habilite Gmail API, Calendar API e Tasks API. Configure consentimento e credenciais do tipo Aplicativo para computador (Desktop). Se o projeto estiver em teste, inclua as contas de teste. Cole o Client ID e o segredo das credenciais Desktop; o segredo será guardado no Keychain.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Link("Documentação OAuth para Desktop", destination: URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app")!)
                            TextField("Client ID Google", text: $config.googleClientID).textFieldStyle(.roundedBorder)
                            SecureField("Client secret Google — deixe vazio para manter o já salvo", text: $googleSecret).textFieldStyle(.roundedBorder)
                            Button("Salvar configuração OAuth") {
                                Task { if await model.saveConfiguration(config, googleSecret: googleSecret) { googleSecret = "" } }
                            }.disabled(model.isDemo || model.isConnecting)
                            Text("O Órbita não reutiliza a sessão nem extrai as credenciais do Outlook instalado. As organizações podem exigir aprovação administrativa. O cache local usa permissões privadas, sem criptografia própria; as credenciais ficam no Keychain.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.top, 15)
                    } label: { Text("Configuração do aplicativo OAuth").font(.system(size: 14, weight: .medium)) }
                    if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(model.noticeIsError ? Color.orange : Color.secondary).textSelection(.enabled) }
                }.padding(24)
            }
        }.frame(width: 740, height: 710)
            .onAppear { config = model.configuration; showSetup = model.accounts.isEmpty }
            .interactiveDismissDisabled(model.isConnecting)
            .sheet(isPresented: $showImport) { ImportSettingsView().environmentObject(model) }
            .sheet(item: $serverSetup) { ServerAccountView(request: $0).environmentObject(model) }
            .confirmationDialog("Desconectar esta conta deste Mac?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
                if let account = removal {
                    Button("Desconectar \(account.email)", role: .destructive) { Task { await model.disconnect(account); removal = nil } }
                }
                Button("Cancelar", role: .cancel) { removal = nil }
            } message: { Text("O cache e as credenciais desta conta serão removidos deste aplicativo. Os emails, compromissos e tarefas no provedor serão preservados.") }
    }
}
