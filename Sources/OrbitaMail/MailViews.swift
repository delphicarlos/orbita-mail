import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers
import OrbitaCore

struct MailWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var search = ""
    @State private var unreadOnly = false
    private var messages: [MailMessage] {
        model.messages.filter { message in
            (model.accountFilter == nil || message.accountID == model.accountFilter) && (!unreadOnly || !message.isRead) &&
            (search.isEmpty || [message.subject, message.sender, message.senderName, message.preview].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }
    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.activeMailTitle).font(.system(size: 21, weight: .semibold))
                            Text("\(messages.count) carregadas · \(model.activeUnreadText) não lidos na pasta").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle(isOn: $unreadOnly) { Image(systemName: "line.3.horizontal.decrease.circle") }
                            .toggleStyle(.button).help("Somente não lidas").accessibilityLabel("Filtrar não lidas")
                    }
                    TextField("Buscar nas mensagens carregadas", text: $search).textFieldStyle(.roundedBorder)
                    if !model.pendingInvitations.isEmpty {
                        Button {
                            model.workspace = .calendar; model.selectedAgendaID = model.pendingInvitations.first?.id
                        } label: {
                            HStack { Image(systemName: "calendar.badge.clock"); Text("\(model.pendingInvitations.count) convite(s) sem resposta"); Spacer(); Image(systemName: "chevron.right") }
                                .font(.system(size: 11))
                        }.buttonStyle(.plain).foregroundStyle(OrbitaStyle.accent)
                    }
                }.padding(18)
                Divider()
                List(selection: $model.selectedMessageID) {
                    ForEach(messages) { message in MailRow(message: message).tag(message.id) }
                }.listStyle(.plain).overlay {
                    if messages.isEmpty {
                        ContentUnavailableView(model.isRefreshingMail ? "Carregando mensagens" : "Nenhuma mensagem carregada", systemImage: "tray",
                                               description: Text(search.isEmpty ? "Confira as fontes de sincronização ou escolha outra pasta." : "A busca consulta apenas as mensagens já carregadas."))
                    }
                }
                if !model.cursors.isEmpty {
                    Divider()
                    Button("Carregar mais mensagens") { Task { await model.refreshMail(loadMore: true) } }
                        .disabled(model.isRefreshingMail).padding(12)
                }
            }.frame(minWidth: 300, idealWidth: 355, maxWidth: 420)
                .background(Color(nsColor: .textBackgroundColor))
            Group {
                if let message = model.selectedMessage { MessageReader(message: message) }
                else {
                    VStack(spacing: 16) {
                        Image(systemName: "envelope.open").font(.system(size: 42, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text("Uma conversa de cada vez").font(.system(size: 20, weight: .medium))
                        Text("Selecione uma mensagem para ler.\nA conta de origem acompanha todas as ações.").multilineTextAlignment(.center).foregroundStyle(.secondary).font(.system(size: 13))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor))
        }
        .task(id: model.selectedMessageID) { await model.read(model.selectedMessage) }
    }
}

struct MailRow: View {
    let message: MailMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !message.isRead { Circle().fill(OrbitaStyle.accent).frame(width: 6, height: 6) }
                Text(message.senderName.nilIfEmpty ?? message.sender).font(.system(size: 13, weight: message.isRead ? .medium : .semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Text(message.date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 5) {
                Text(message.subject.nilIfEmpty ?? "Sem assunto").font(.system(size: 12, weight: message.isRead ? .regular : .semibold)).lineLimit(2)
                if message.isFlagged { Image(systemName: "flag.fill").font(.system(size: 10)).foregroundStyle(OrbitaStyle.accent) }
                if message.hasAttachments { Image(systemName: "paperclip").font(.system(size: 10)) }
            }
            Text(message.preview).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            AccountBadge(accountID: message.accountID)
        }.padding(.vertical, 10).padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MessageReader: View {
    @EnvironmentObject private var model: AppModel
    let message: MailMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                action("Responder", symbol: "arrowshape.turn.up.left") { model.newDraft(reply: message) }.disabled(model.body == nil)
                action("Responder a todos", symbol: "arrowshape.turn.up.left.2") { model.newDraft(reply: message, replyAll: true) }.disabled(model.body == nil)
                action("Encaminhar", symbol: "arrowshape.turn.up.right") { model.newDraft(reply: message, forward: true) }.disabled(model.body == nil)
                Spacer(minLength: 0)
                action("Arquivar", symbol: "archivebox") { Task { await model.mailAction(message, action: "archive") } }
                action("Mover para lixeira", symbol: "trash") { Task { await model.mailAction(message, action: "trash") } }
                Menu {
                    Button(message.isRead ? "Marcar como não lida" : "Marcar como lida") { Task { await model.mailAction(message, action: "read") } }
                    Button(message.isFlagged ? "Remover sinalizador" : "Sinalizar") { Task { await model.mailAction(message, action: "flag") } }
                    Menu("Mover para pasta") {
                        ForEach(model.mailboxes.filter { $0.accountID == message.accountID && $0.standard == nil }) { box in
                            Button(box.name) { Task { await model.moveMessage(message, to: box) } }
                        }
                        Button("Criar pasta…") { model.openMailOrganization(accountID: message.accountID) }
                    }.disabled(model.account(message.accountID)?.provider == .pop3)
                    Button("Mover para caixa de entrada") { Task { await model.mailAction(message, action: "inbox") } }
                    Button("Marcar como spam") { Task { await model.mailAction(message, action: "junk") } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
            }.buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 16).disabled(model.operations.contains(message.id))
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(message.subject.nilIfEmpty ?? "Sem assunto").font(.system(size: 23, weight: .semibold)).textSelection(.enabled)
                HStack(alignment: .top, spacing: 10) {
                    Text(String((message.senderName.nilIfEmpty ?? message.sender).prefix(1)).uppercased())
                        .font(.system(size: 16, weight: .medium)).frame(width: 38, height: 38)
                        .background(OrbitaStyle.accent.opacity(0.12), in: Circle()).foregroundStyle(OrbitaStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.senderName.nilIfEmpty ?? message.sender).font(.system(size: 13, weight: .semibold))
                        Text(message.sender).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Para: " + message.to.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Text(message.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                AccountBadge(accountID: message.accountID)
            }.padding(24)
            HStack(spacing: 7) {
                Image(systemName: "hand.raised")
                Text("Conteúdo externo e scripts bloqueados para proteger sua privacidade.")
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3))
            if let body = model.body {
                if !body.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(body.attachments) { attachment in
                                Button { Task { await model.download(attachment, message: message) } } label: {
                                    Label("\(attachment.name) · \(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))", systemImage: "arrow.down.doc")
                                }.font(.system(size: 11))
                            }
                        }.padding(.horizontal, 24).padding(.vertical, 10)
                    }
                }
                SecureMessageView(content: body).id(message.id)
            } else if model.isReading { ProgressView("Carregando mensagem…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { ContentUnavailableView("Mensagem indisponível", systemImage: "wifi.exclamationmark", description: Text("Confira a conexão da conta e tente selecionar a mensagem novamente.")) }
        }
    }
    private func action(_ title: String, symbol: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 22, height: 22) }.help(title).accessibilityLabel(title)
    }
}

struct SecureMessageView: NSViewRepresentable {
    let content: MailBody
    @Environment(\.colorScheme) private var colorScheme
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        // CSP already denies remote resources; the rule list provides defense in depth.
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "OrbitaBlockRemote", encodedContentRuleList: SafeHTML.contentRules) { list, _ in
            if let list { DispatchQueue.main.async { view.configuration.userContentController.add(list) } }
        }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let html = SafeHTML.document(text: content.text, html: content.html, dark: colorScheme == .dark)
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        view.loadHTMLString(html, baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url, SafeHTML.externalLinkAllowed(url) { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel); return
            }
            let allowedInitial = navigationAction.request.url?.absoluteString == "about:blank" && navigationAction.targetFrame?.isMainFrame == true
            decisionHandler(allowedInitial ? .allow : .cancel)
        }
    }
}

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MailDraft
    @State private var showSignatures = false
    @State private var saveTask: Task<Void, Never>?
    init(initial: MailDraft) { _draft = State(initialValue: initial) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.replyToRemoteID == nil ? "Novo email" : "Responder email").font(.headline)
                Spacer()
                Text(model.isDemo ? "Demonstração" : "Rascunho salvo neste Mac").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Fechar") { Task { await model.saveDraft(draft); dismiss() } }.disabled(model.isSending)
                Button(model.isSending ? "Enviando…" : model.isDemo ? "Simular envio" : "Enviar") {
                    saveTask?.cancel()
                    Task { if await model.send(draft) { dismiss() } else if let current = model.composeDraft { draft = current } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isSending || draft.deliveryState != "draft")
            }.padding(18)
            Divider()
            Form {
                Picker("De", selection: $draft.accountID) { ForEach(model.accounts) { Text($0.email).tag($0.id) } }.disabled(draft.replyToRemoteID != nil || model.isSending)
                TextField("Para", text: $draft.to)
                TextField("Cc", text: $draft.cc)
                TextField("Cco", text: $draft.bcc)
                TextField("Assunto", text: $draft.subject)
            }.formStyle(.columns).textFieldStyle(.plain).padding(18).disabled(model.isSending)
            Divider()
            if draft.deliveryState != "draft" {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Envio sem confirmação. Confira a pasta Enviados desta conta antes de reenviar.").font(.system(size: 12, weight: .medium))
                    Button("Conferi os enviados; permitir novo envio") { draft.deliveryState = "draft"; Task { await model.saveDraft(draft) } }
                }.padding(15).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1))
            }
            TextEditor(text: $draft.text).font(.system(size: 14)).padding(15).disabled(model.isSending)
            if let signature = draft.signatureText, !signature.isEmpty {
                Divider()
                HStack(alignment: .top) {
                    ScrollView { Text("-- \n" + signature).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 80)
                    Button("Sem assinatura") { draft.signatureID = nil; draft.signatureText = nil }.font(.system(size: 11))
                }.padding(.horizontal, 18).padding(.vertical, 8)
            }
            if !draft.attachments.isEmpty {
                HStack {
                    ForEach(draft.attachments) { attachment in
                        Button { draft.attachments.removeAll { $0.id == attachment.id } } label: { Label(attachment.name, systemImage: "paperclip").font(.system(size: 11)) }.help("Remover anexo")
                    }
                }.padding(12)
            }
            Divider()
            HStack {
                Button { attach() } label: { Label("Anexar arquivo", systemImage: "paperclip") }.disabled(model.isSending)
                if !availablePresets.isEmpty {
                    Menu("Assinaturas e modelos") {
                        ForEach(availablePresets) { preset in
                            Button(preset.name + (preset.kind == .signature ? " · Assinatura" : " · Modelo")) {
                                if preset.kind == .signature { draft.signatureID = preset.id; draft.signatureText = preset.text }
                                else {
                                    if draft.subject.isEmpty { draft.subject = preset.subject }
                                    draft.text = preset.text + (draft.text.isEmpty ? "" : "\n\n" + draft.text)
                                }
                            }
                        }
                    }.disabled(model.isSending)
                }
                Button("Gerenciar…") { showSignatures = true }.disabled(model.isSending)
                Text("Texto simples · Anexos até 2,5 MB no total").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()

            }.padding(15)
        }.frame(width: 760, height: 660)
            .onChange(of: draft.accountID) { _, _ in model.applyDefaultSignature(to: &draft) }
            .onChange(of: encodedDraft) { _, _ in
                saveTask?.cancel()
                let value = draft
                saveTask = Task {
                    do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                    await model.saveDraft(value)
                }
            }
            .onDisappear { saveTask?.cancel() }
            .sheet(isPresented: $showSignatures) { MailOrganizationView(initialAccountID: draft.accountID, initialTab: .signatures).environmentObject(model) }
            .interactiveDismissDisabled(model.isSending)
    }
    private var encodedDraft: Data { (try? JSONEncoder().encode(draft)) ?? Data() }
    private var availablePresets: [WritingPreset] {
        let email = model.account(draft.accountID)?.email ?? ""
        return model.writingPresets.filter { $0.accountEmail == nil || $0.accountEmail?.caseInsensitiveCompare(email) == .orderedSame }
    }
    private func attach() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        do {
            var additions: [OutgoingAttachment] = []
            var total = draft.attachments.reduce(0) { $0 + $1.data.count }
            for url in panel.urls {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let count = values.fileSize, total + count <= 2_500_000 else {
                    throw OrbitaError.invalidData("Selecione arquivos regulares que somem até 2,5 MB.")
                }
                let bytes = try Data(contentsOf: url); total += bytes.count
                guard total <= 2_500_000 else { throw OrbitaError.invalidData("Os anexos ultrapassam 2,5 MB.") }
                additions.append(OutgoingAttachment(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: bytes))
            }
            draft.attachments += additions
        } catch { model.tell(error.localizedDescription, error: true) }
    }
}
