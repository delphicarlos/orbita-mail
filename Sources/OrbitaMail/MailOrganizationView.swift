import SwiftUI
import OrbitaCore

enum MailOrganizationTab: String, CaseIterable, Identifiable {
    case folders, rules, signatures, replies
    var id: String { rawValue }
    var title: String { switch self { case .folders: "Pastas"; case .rules: "Regras"; case .signatures: "Assinaturas"; case .replies: "Respostas automáticas" } }
}

struct MailOrganizationView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: String
    @State private var tab: MailOrganizationTab
    @State private var busy = false
    @State private var loading = false
    @State private var loadGeneration = UUID()
    @State private var authorized = false
    @State private var error: String?
    @State private var status: String?
    @State private var folderName = ""
    @State private var rules: [RoutingRule] = []
    @State private var ruleName = ""
    @State private var sender = ""
    @State private var recipient = ""
    @State private var subject = ""
    @State private var bodyContains = ""
    @State private var destination = ""
    @State private var removingRule: RoutingRule?
    @State private var removingSignature: WritingPreset?
    @State private var signatureID: String?
    @State private var signatureName = ""
    @State private var signatureText = ""
    @State private var defaultNew = true
    @State private var defaultReply = true
    @State private var replies: AutoReplySettings?
    @State private var confirmReplies = false
    init(initialAccountID: String, initialTab: MailOrganizationTab = .folders) {
        _accountID = State(initialValue: initialAccountID); _tab = State(initialValue: initialTab)
    }
    private var account: Account? { model.account(accountID) }
    private var folders: [MailboxFolder] { model.mailboxes.filter { $0.accountID == accountID } }
    private var signatures: [WritingPreset] { model.writingPresets.filter { $0.kind == .signature && ($0.accountEmail == nil || $0.accountEmail?.caseInsensitiveCompare(account?.email ?? "") == .orderedSame) } }
    private var supportsSettings: Bool { model.isDemo || account?.provider.supportsServerMailSettings == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Configurações de email").font(.system(size: 22, weight: .semibold))
                    Text(model.isDemo ? "Demonstração · alterações apenas nos dados fictícios" : "Cada conta mantém suas pastas, regras e respostas.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Concluir") { dismiss() }.disabled(busy || model.isConnecting)
            }
            Picker("Conta", selection: $accountID) { ForEach(model.accounts) { Text($0.email).tag($0.id) } }.disabled(busy || model.isConnecting)
            Picker("Configuração", selection: $tab) { ForEach(MailOrganizationTab.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).disabled(busy || model.isConnecting)
            Divider()
            if loading { HStack { ProgressView().controlSize(.small); Text("Consultando configurações…").font(.system(size: 12)) } }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .folders: folderContent
                    case .signatures: signatureContent
                    case .rules, .replies:
                        if !supportsSettings {
                            ContentUnavailableView("Configuração no provedor", systemImage: "server.rack", description: Text("IMAP e POP3 não oferecem comandos para regras ou respostas de ausência no servidor. Configure no painel do seu provedor. Pastas IMAP e assinaturas continuam disponíveis aqui."))
                        } else if !authorized {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Autorize as configurações de email").font(.headline)
                                Text("Essa conta já pode enviar e receber emails. Gerenciar regras e respostas automáticas exige uma permissão adicional, concedida individualmente no navegador.").foregroundStyle(.secondary)
                                Button(model.isConnecting ? "Aguardando autorização…" : "Autorizar regras e respostas automáticas") {
                                    guard let account else { return }
                                    Task { await model.connect(account.provider, expectedEmail: account.email, mailSettings: true); await load() }
                                }.disabled(model.isConnecting || busy)
                                if model.isConnecting { Button("Cancelar autorização") { model.cancelConnection() } }
                            }.font(.system(size: 13))
                        } else if tab == .rules { rulesContent }
                        else { repliesContent }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.disabled(busy || loading || model.isConnecting)
            Spacer(minLength: 0)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            if let status { Text(status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled) }
            Divider()
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Text(model.isDemo ? "Demonstração: configurações fictícias, sem execução real." : tab == .signatures ? "Assinaturas em texto simples, salvas neste Mac." : tab == .folders ? "Pastas e contagens pertencem à conta selecionada." : "Regras e respostas automáticas são executadas pelo provedor, inclusive com o Órbita fechado.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Atualizar") { Task { await load() } }.disabled(busy || loading || model.isConnecting)
            }
        }.padding(24).frame(width: 860, height: 720)
            .task(id: accountID + ":" + tab.rawValue) { await load() }
            .onChange(of: accountID) { _, _ in resetSignature(); destination = ""; rules = []; replies = nil; error = nil; status = nil }
            .alert("Remover esta regra do servidor?", isPresented: Binding(get: { removingRule != nil }, set: { if !$0 { removingRule = nil } })) {
                Button("Cancelar", role: .cancel) { removingRule = nil }
                Button("Remover regra", role: .destructive) {
                    guard let rule = removingRule else { return }; removingRule = nil
                    perform { try await model.removeRule(rule); rules = try await model.rules(accountID: accountID); status = "Regra removida do provedor." }
                }
            } message: { Text("As mensagens já organizadas permanecem em suas pastas. A regra deixa de tratar os próximos recebimentos.") }
            .alert("Remover esta assinatura?", isPresented: Binding(get: { removingSignature != nil }, set: { if !$0 { removingSignature = nil } })) {
                Button("Cancelar", role: .cancel) { removingSignature = nil }
                Button("Remover assinatura", role: .destructive) {
                    guard let signature = removingSignature else { return }; removingSignature = nil
                    perform { try await model.removeSignature(signature); resetSignature(); status = "Assinatura removida deste Mac." }
                }
            }
            .confirmationDialog(model.isDemo ? "Salvar configuração fictícia?" : "Ativar respostas automáticas nesta conta?", isPresented: $confirmReplies, titleVisibility: .visible) {
                Button(model.isDemo ? "Salvar na demonstração" : "Ativar no provedor") { saveReplies() }
                Button("Cancelar", role: .cancel) {}
            } message: { Text(model.isDemo ? "Esta configuração será salva somente na demonstração. Nenhuma resposta será enviada." : "O provedor poderá enviar a mensagem configurada aos remetentes, mesmo com este Mac desligado. Confira o período e o público antes de ativar.") }
            .interactiveDismissDisabled(busy || model.isConnecting)
    }
    private var folderContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account?.provider == .google ? "Pastas e marcadores do Gmail" : "Pastas da conta").font(.headline)
            Text("Os números indicam emails não lidos consultados no provedor. Marcadores Gmail podem conter a mesma mensagem; seus totais não devem ser somados.").font(.system(size: 12)).foregroundStyle(.secondary)
            if account?.provider == .pop3 && !model.isDemo {
                Text("POP3 fornece somente a Entrada e não oferece criação de pastas. Seus não lidos são locais, entre as mensagens carregadas.").font(.system(size: 13)).foregroundStyle(.orange)
            } else {
                HStack {
                    TextField("Nome da nova pasta", text: $folderName)
                    Button("Criar pasta") {
                        perform { _ = try await model.createMailbox(accountID: accountID, name: folderName); folderName = ""; status = model.isDemo ? "Pasta criada na demonstração." : "Pasta criada no provedor." }
                    }.disabled(folderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            ForEach(folders) { folder in
                HStack {
                    Image(systemName: folder.standard?.symbol ?? "folder")
                    Text(folder.standard?.title ?? folder.name)
                    Spacer()
                    Text(folder.unreadCount.map { "\($0) não lidos" } ?? "Contagem indisponível").foregroundStyle(.secondary).monospacedDigit()
                    Button("Abrir") { Task { if let standard = folder.standard { model.accountFilter = accountID; await model.setFolder(standard) } else { await model.selectMailbox(folder) }; dismiss() } }
                }.font(.system(size: 12)).padding(.vertical, 5)
                Divider()
            }
        }
    }
    private var rulesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Direcionar novos emails para uma pasta").font(.headline)
            Text("Todas as condições preenchidas precisam corresponder. A regra trata novos recebimentos; não move o histórico. Regras anteriores do provedor continuam tendo prioridade. No Gmail, os critérios seguem a sintaxe de busca do serviço.").font(.system(size: 12)).foregroundStyle(.secondary)
            GroupBox {
                VStack(spacing: 10) {
                    TextField("Nome da regra", text: $ruleName)
                    TextField("Remetente contém · opcional", text: $sender)
                    TextField("Destinatário contém · opcional", text: $recipient)
                    TextField("Assunto contém · opcional", text: $subject)
                    TextField("Corpo contém · opcional", text: $bodyContains)
                    Picker("Mover para", selection: $destination) {
                        Text("Selecione uma pasta personalizada").tag("")
                        ForEach(folders.filter { $0.standard == nil }) { Text($0.name).tag($0.remoteID) }
                    }
                    HStack {
                        Text("Crie o destino na aba Pastas, se necessário.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.isDemo ? "Salvar regra fictícia" : "Criar regra e ativar") {
                            let rule = RoutingRule(accountID: accountID, name: ruleName, sender: sender, recipient: recipient, subject: subject, body: bodyContains, destinationID: destination)
                            perform { try await model.createRule(rule); rules = try await model.rules(accountID: accountID); ruleName = ""; sender = ""; recipient = ""; subject = ""; bodyContains = ""; status = model.isDemo ? "Regra salva somente na demonstração; não executa ações reais." : "Regra criada no provedor para novos emails." }
                        }.disabled(destination.isEmpty || ruleName.isEmpty || [sender, recipient, subject, bodyContains].allSatisfy(\.isEmpty))
                    }
                }.padding(8)
            }
            Text("Regras existentes").font(.headline)
            if rules.isEmpty { Text("Nenhuma regra retornada pelo provedor.").foregroundStyle(.secondary) }
            ForEach(rules) { rule in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(displayName(rule)).fontWeight(.medium)
                        Text(rule.conditionsDescription.isEmpty ? rule.summary : rule.conditionsDescription).font(.system(size: 11)).foregroundStyle(.secondary)
                        if let folder = folders.first(where: { $0.remoteID == rule.destinationID }) { Text("Destino: " + folder.name).font(.system(size: 11)) }
                        Text(model.isDemo ? "Regra fictícia · sem execução real" : rule.enabled ? "Ativa no provedor" : "Desativada no provedor").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if rule.managed { Button("Remover…", role: .destructive) { removingRule = rule } }
                }.font(.system(size: 12)).padding(.vertical, 5)
                Divider()
            }
        }
    }
    private var signatureContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Assinaturas desta conta").font(.headline); Spacer(); Button("Nova assinatura") { resetSignature() } }
            ForEach(signatures) { preset in
                HStack {
                    Button(preset.name) { editSignature(preset) }.buttonStyle(.plain)
                    if signatureID == preset.id { Image(systemName: "checkmark") }
                    Spacer()
                    Button("Remover…", role: .destructive) { removingSignature = preset }
                }.font(.system(size: 12))
            }
            Divider()
            TextField("Nome da assinatura", text: $signatureName)
            Text("Texto da assinatura").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $signatureText).font(.system(size: 14)).frame(minHeight: 180).border(Color.secondary.opacity(0.25))
            Toggle("Usar por padrão em novos emails desta conta", isOn: $defaultNew)
            Toggle("Usar por padrão em respostas desta conta", isOn: $defaultReply)
            HStack {
                Text("Você pode trocar ou retirar a assinatura em cada rascunho.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Salvar assinatura") {
                    guard let account else { return }
                    let old = signatures.first { $0.id == signatureID }
                    let preset = WritingPreset(name: signatureName, text: signatureText, accountEmail: account.email, kind: .signature)
                    perform { try await model.saveSignature(preset, replacing: old, accountID: accountID, useForNew: defaultNew, useForReplies: defaultReply); signatureID = preset.id; status = "Assinatura e padrões salvos neste Mac." }
                }.disabled(signatureName.isEmpty || signatureText.isEmpty)
            }
        }
    }
    @ViewBuilder private var repliesContent: some View {
        if replies != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ausência e respostas automáticas").font(.headline)
                Text("O provedor controla o envio e a frequência das respostas. As mensagens são salvas em texto simples; o app não responde por SMTP em segundo plano.").font(.system(size: 12)).foregroundStyle(.secondary)
                Toggle("Ativar respostas automáticas", isOn: replyBinding(\.enabled))
                Toggle("Usar um período", isOn: replyBinding(\.scheduled))
                if replies?.scheduled == true {
                    DatePicker("Início", selection: replyBinding(\.start))
                    if account?.provider == .google { Toggle("Definir término", isOn: replyBinding(\.hasEnd)) }
                    if replies?.hasEnd == true { DatePicker("Fim", selection: replyBinding(\.end)) }
                }
                if account?.provider == .google { TextField("Assunto da resposta", text: replyBinding(\.subject)) }
                Text(account?.provider == .google ? "Mensagem automática" : "Mensagem para remetentes da organização").font(.system(size: 12))
                TextEditor(text: replyBinding(\.internalMessage)).font(.system(size: 13)).frame(minHeight: 100).border(Color.secondary.opacity(0.25))
                if account?.provider == .google {
                    Toggle("Responder somente aos contatos", isOn: replyBinding(\.contactsOnly))
                    Toggle("Responder somente ao próprio domínio · Google Workspace", isOn: replyBinding(\.domainOnly))
                    Text(replies?.contactsOnly == false && replies?.domainOnly == false ? "Público: todos os remetentes elegíveis pelo Gmail." : "Público limitado pelas opções selecionadas.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Picker("Remetentes externos", selection: replyBinding(\.externalAudience)) {
                        Text("Não responder").tag("none"); Text("Somente contatos").tag("contacts"); Text("Todos").tag("all")
                    }
                    if replies?.externalAudience != "none" {
                        Text("Mensagem para remetentes externos").font(.system(size: 12))
                        TextEditor(text: replyBinding(\.externalMessage)).font(.system(size: 13)).frame(minHeight: 80).border(Color.secondary.opacity(0.25))
                    }
                }
                HStack { Spacer(); Button(model.isDemo ? "Salvar na demonstração" : "Salvar no provedor") { if replies?.enabled == true { confirmReplies = true } else { saveReplies() } } }
            }
        }
    }
    private func replyBinding<T>(_ path: WritableKeyPath<AutoReplySettings, T>) -> Binding<T> {
        Binding(get: { (replies ?? AutoReplySettings())[keyPath: path] }, set: { replies?[keyPath: path] = $0 })
    }
    private func resetSignature() { signatureID = nil; signatureName = ""; signatureText = ""; defaultNew = true; defaultReply = true }
    private func editSignature(_ preset: WritingPreset) {
        signatureID = preset.id; signatureName = preset.name; signatureText = preset.text
        let preference = model.signaturePreferences.first { $0.accountID == accountID }
        defaultNew = preference?.newSignatureID == preset.id; defaultReply = preference?.replySignatureID == preset.id
    }
    private func displayName(_ rule: RoutingRule) -> String {
        guard rule.name.hasPrefix("Órbita · ") else { return rule.name }
        return String(rule.name.dropFirst("Órbita · ".count)).components(separatedBy: " [").first ?? rule.name
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; error = nil; status = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
    private func saveReplies() {
        guard let value = replies else { return }
        perform { replies = try await model.saveReplies(value, accountID: accountID); status = model.isDemo ? "Configuração salva apenas na demonstração." : "Configuração confirmada no provedor." }
    }
    @MainActor private func load() async {
        let generation = UUID(); loadGeneration = generation; loading = true; error = nil; status = nil
        defer { if loadGeneration == generation { loading = false } }
        do {
            if tab == .folders { await model.refreshMailboxes(accountID: accountID) }
            if tab == .rules || tab == .replies {
                let allowed = await model.settingsAuthorized(accountID: accountID)
                try Task.checkCancellation(); authorized = allowed
                guard allowed else { return }
                if tab == .rules { let fetched = try await model.rules(accountID: accountID); try Task.checkCancellation(); rules = fetched }
                else { let fetched = try await model.replies(accountID: accountID); try Task.checkCancellation(); replies = fetched }
            }
        } catch is CancellationError {} catch { if loadGeneration == generation { self.error = error.localizedDescription } }
    }
}
