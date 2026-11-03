import SwiftUI
import AppKit
import OrbitaCore
import Darwin

enum Workspace: String, CaseIterable, Identifiable {
    case mail, calendar, tasks
    var id: String { rawValue }
    var title: String { switch self { case .mail: "Email"; case .calendar: "Agenda"; case .tasks: "Tarefas" } }
    var symbol: String { switch self { case .mail: "envelope"; case .calendar: "calendar"; case .tasks: "checklist" } }
}

struct SourceHealth: Identifiable {
    var id: String
    var title: String
    var accountID: String
    var state: String
    var detail: String
    var date: Date?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var mailboxes: [MailboxFolder] = []
    @Published var selectedMailbox: MailboxFolder?
    @Published var signaturePreferences: [SignaturePreference] = []
    @Published var localUnreadCounts: [String: Int] = [:]
    @Published var showMailOrganization = false
    @Published var organizationAccountID = ""
    @Published var isRefreshingMailboxes = false
    @Published var messages: [MailMessage] = []
    @Published var agenda: [AgendaItem] = []
    @Published var sources: [AgendaSource] = []
    @Published var drafts: [MailDraft] = []
    @Published var importedAccounts: [ImportedAccount] = []
    @Published var writingPresets: [WritingPreset] = []
    @Published var health: [String: SourceHealth] = [:]
    @Published var workspace: Workspace = .mail
    @Published var accountFilter: String?
    @Published var folder: MailFolder = .inbox
    @Published var selectedMessageID: String?
    @Published var selectedAgendaID: String?
    @Published var body: MailBody?
    @Published var isReading = false
    @Published var isRefreshingMail = false
    @Published var isRefreshingAgenda = false
    @Published var isConnecting = false
    @Published var isSending = false
    @Published var operations = Set<String>()
    @Published var unresolvedResponses = Set<String>()
    @Published var configuration = OAuthConfiguration()
    @Published var isDemo = false
    @Published var notice: String?
    @Published var noticeIsError = false
    @Published var showAccounts = false
    @Published var composeDraft: MailDraft?
    @Published var anchor = Date()
    @Published var hiddenSources = Set<String>()
    @Published var cursors: [String: String] = [:]
    @Published var ready = false
    var store: LocalStore?
    private let vault = TokenVault()
    private var clients: [String: ProviderClient] = [:]
    private var oauth: OAuthSession?
    private var syncTask: Task<Void, Never>?
    private var mailGeneration = 0
    private var agendaGeneration = 0
    private var bodyGeneration = 0
    private var pendingResponses: [String: PendingResponse] = [:]

    var selectedMessage: MailMessage? { messages.first { $0.id == selectedMessageID } }
    var selectedAgenda: AgendaItem? { agenda.first { $0.id == selectedAgendaID } }
    var visibleAccounts: [Account] { accounts.filter { accountFilter == nil || $0.id == accountFilter } }
    var visibleAgenda: [AgendaItem] {
        agenda.filter { item in
            (accountFilter == nil || item.accountID == accountFilter) &&
            !hiddenSources.contains(scopedID(item.accountID, item.kind.rawValue, item.sourceID))
        }
    }
    var pendingInvitations: [AgendaItem] {
        visibleAgenda.filter { $0.canRespond && ["needsAction", "notResponded", "none"].contains($0.response) }
    }
    var busy: Bool { isRefreshingMail || isRefreshingAgenda || isRefreshingMailboxes || isConnecting || isSending || !operations.isEmpty }
    var syncInterval: DateInterval {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: anchor)!
        let start = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 42, to: start)!)
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    func tell(_ message: String, error: Bool = false) { notice = message; noticeIsError = error }
    func client(_ account: Account) throws -> ProviderClient {
        guard !isDemo else { throw OrbitaError.invalidData("Conectores reais estão desativados na demonstração.") }
        if let cached = clients[account.id] { return cached }
        let value = ProviderClient(account: account, vault: vault); clients[account.id] = value; return value
    }

    func bootstrap(demo: Bool = false) async {
        guard !busy else { return }
        ready = false; syncTask?.cancel(); clients = [:]; accountFilter = nil; folder = .inbox; workspace = .mail; selectedMailbox = nil; mailboxes = []; signaturePreferences = []
        notice = nil; noticeIsError = false
        bodyGeneration += 1; body = nil; selectedMessageID = nil; selectedAgendaID = nil
        health = [:]; unresolvedResponses = []; cursors = [:]; hiddenSources = []
        isDemo = demo
        do {
            let root: URL
            if let index = CommandLine.arguments.firstIndex(of: "--data-dir"), CommandLine.arguments.count > index + 1 {
                root = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            } else {
                root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OrbitaMail", isDirectory: true)
            }
            let storage = try LocalStore(url: root.appendingPathComponent(demo ? "demonstracao/cache.sqlite" : "contas/cache.sqlite"))
            store = storage
            if demo { try await seedDemo(storage) }
            configuration = try await storage.values(OAuthConfiguration.self, bucket: "configuration").first ?? OAuthConfiguration()
            hiddenSources = Set(try await storage.values([String].self, bucket: "hidden-sources").first ?? [])
            try await reloadCache()
            for source in sources {
                health[source.id] = SourceHealth(id: source.id, title: source.name, accountID: source.accountID,
                                                state: demo ? "demo" : "cached", detail: demo ? "Dados fictícios" : "Cache local; aguardando atualização", date: nil)
            }
            ready = true
            if demo { await refreshMailboxes() }
            else if !accounts.isEmpty { refreshAll() }
        } catch { ready = true; tell(error.localizedDescription, error: true) }
    }

    private func seedDemo(_ storage: LocalStore) async throws {
        for account in DemoData.accounts { try await storage.put(account, id: account.id, bucket: "account") }
        let previous = try await storage.values(String.self, bucket: "seed-day").first
        guard previous != Time.dayKey(Date()) else { return }
        for account in DemoData.accounts {
            try await storage.saveMail(DemoData.messages().filter { $0.accountID == account.id }, account: account.id, folder: "inbox", replace: true)
            for kind in [AgendaKind.event, .task] {
                try await storage.replaceSources(DemoData.sources().filter { $0.accountID == account.id && $0.kind == kind }, account: account.id, kind: kind)
            }
        }
        for source in DemoData.sources() {
            try await storage.replaceAgenda(DemoData.agenda().filter { $0.accountID == source.accountID && $0.sourceID == source.remoteID }, source: source, interval: nil)
        }
        try await storage.put(Time.dayKey(Date()), id: "seed-day", bucket: "seed-day")
    }

    func reloadCache() async throws {
        guard let store else { return }
        accounts = try await store.values(Account.self, bucket: "account").sorted { $0.colorIndex < $1.colorIndex }
        messages = try await store.values(MailMessage.self, bucket: "mail", source: activeMailSource).sorted { $0.date > $1.date }
        mailboxes = try await store.values(MailboxFolder.self, bucket: "mailbox").sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        signaturePreferences = try await store.values(SignaturePreference.self, bucket: "signature-preference")
        for account in accounts where account.provider == .pop3 {
            localUnreadCounts[account.id] = try await store.values(MailMessage.self, bucket: "mail", account: account.id, source: "inbox").filter { !$0.isRead }.count
        }
        sources = try await store.values(AgendaSource.self, bucket: "source").sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        agenda = try await store.values(AgendaItem.self, bucket: "event") + store.values(AgendaItem.self, bucket: "task")
        drafts = try await store.values(MailDraft.self, bucket: "draft")
        importedAccounts = try await store.values(ImportedAccount.self, bucket: "imported-account").sorted { $0.email < $1.email }
        writingPresets = try await store.values(WritingPreset.self, bucket: "writing-preset").sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        let pending = try await store.values(PendingResponse.self, bucket: "pending-response")
        pendingResponses = Dictionary(uniqueKeysWithValues: pending.map { ($0.itemID, $0) })
        unresolvedResponses = Set(pending.map(\.itemID))
    }

    func setFolder(_ value: MailFolder) async {
        selectedMailbox = nil; folder = value; selectedMessageID = nil; body = nil; cursors = [:]
        do { try await reloadCache() } catch { tell(error.localizedDescription, error: true) }
        await refreshMail()
    }

    func refreshAll() {
        guard ready, !isDemo else { return }
        syncTask?.cancel()
        syncTask = Task {
            async let folderRefresh: Void = refreshMailboxes()
            await refreshMail()
            if !Task.isCancelled { await refreshAgenda() }
            await folderRefresh
        }
    }

    func refreshMail(loadMore: Bool = false) async {
        guard let store, !isDemo else { return }
        mailGeneration += 1; let generation = mailGeneration, currentFolder = folder, currentMailbox = selectedMailbox
        let source = currentMailbox?.cacheSource ?? currentFolder.rawValue
        isRefreshingMail = true
        defer { if generation == mailGeneration { isRefreshingMail = false } }
        let targets = accounts.filter { currentMailbox == nil || $0.id == currentMailbox?.accountID }
        for account in targets {
            if Task.isCancelled || generation != mailGeneration { return }
            if loadMore && cursors[account.id] == nil { continue }
            let healthID = "mail:" + account.id
            if account.provider == .pop3 && currentFolder != .inbox {
                health[healthID] = SourceHealth(id: healthID, title: currentFolder.title, accountID: account.id, state: "local", detail: "POP3: somente Entrada é remota; Enviados, rascunhos e marcações ficam neste Mac. Pastas e exclusão remota não são oferecidas.", date: nil)
                continue
            }
            health[healthID] = SourceHealth(id: healthID, title: currentFolder.title, accountID: account.id, state: "loading", detail: "Buscando mensagens", date: nil)
            do {
                let page = try await client(account).mailPage(folder: currentFolder, cursor: loadMore ? cursors[account.id] : nil, remoteFolderID: currentMailbox?.remoteID)
                try Task.checkCancellation()
                guard generation == mailGeneration, currentFolder == folder, currentMailbox?.id == selectedMailbox?.id else { return }
                var fetched = page.messages
                if account.provider == .pop3 {
                    let previous = try await store.values(MailMessage.self, bucket: "mail", account: account.id, source: source)
                    let markings = Dictionary(uniqueKeysWithValues: previous.map { ($0.remoteID, $0) })
                    fetched = fetched.map { value in var changed = value; if let old = markings[value.remoteID] { changed.isRead = old.isRead; changed.isFlagged = old.isFlagged }; return changed }
                }
                try await store.saveMail(fetched, account: account.id, folder: source, replace: !loadMore)
                cursors[account.id] = page.nextCursor
                health[healthID] = SourceHealth(id: healthID, title: currentFolder.title, accountID: account.id, state: "ok", detail: "Mensagens recentes carregadas" + (page.nextCursor == nil ? "" : "; há mais páginas"), date: Date())
            } catch is CancellationError { return }
            catch { health[healthID] = SourceHealth(id: healthID, title: currentFolder.title, accountID: account.id, state: "error", detail: error.localizedDescription, date: nil) }
        }
        do { try await reloadCache() } catch { tell(error.localizedDescription, error: true) }
    }

    func refreshAgenda() async {
        guard let store, !isDemo else { return }
        agendaGeneration += 1; let generation = agendaGeneration, interval = syncInterval
        isRefreshingAgenda = true
        defer { if generation == agendaGeneration { isRefreshingAgenda = false } }
        for account in accounts {
            if !account.provider.usesOAuth && account.provider != .exchange && (account.serverConfiguration?.caldavURL.isEmpty ?? true) {
                let id = "agenda-unavailable:" + account.id
                health[id] = SourceHealth(id: id, title: "Agenda e tarefas", accountID: account.id, state: "unavailable", detail: "Conta somente de email. Para agenda/tarefas, configure CalDAV se o provedor oferecer o serviço.", date: nil)
                continue
            }
            for kind in [AgendaKind.event, .task] {
                guard !Task.isCancelled, generation == agendaGeneration else { return }
                let collectionID = scopedID(account.id, kind.rawValue)
                let title = kind == .event ? "Calendários" : "Listas de tarefas"
                health[collectionID] = SourceHealth(id: collectionID, title: title, accountID: account.id, state: "loading", detail: "Identificando fontes", date: nil)
                do {
                    let service = try client(account)
                    let found = try await service.sources(kind: kind)
                    try Task.checkCancellation()
                    guard generation == agendaGeneration else { return }
                    try await store.replaceSources(found, account: account.id, kind: kind)
                    let retained = Set(found.map(\.id))
                    for old in sources where old.accountID == account.id && old.kind == kind && !retained.contains(old.id) { health.removeValue(forKey: old.id) }
                    health[collectionID] = SourceHealth(id: collectionID, title: title, accountID: account.id, state: "ok", detail: "\(found.count) fonte(s) identificada(s)", date: Date())
                    for source in found {
                        guard !Task.isCancelled, generation == agendaGeneration else { return }
                        health[source.id] = SourceHealth(id: source.id, title: source.name, accountID: account.id, state: "loading", detail: "Sincronizando \(source.kind == .event ? "compromissos" : "tarefas")", date: nil)
                        do {
                            let values = try await service.agenda(source: source, interval: interval)
                            try Task.checkCancellation()
                            guard generation == agendaGeneration else { return }
                            try await store.replaceAgenda(values, source: source, interval: kind == .event ? interval : nil)
                            for item in values {
                                if let pending = pendingResponses[item.id] {
                                    let expected = account.provider == .microsoft && pending.response == .tentative ? "tentativelyAccepted" : pending.response.rawValue
                                    if item.response == expected { try await store.remove(id: item.id, bucket: "pending-response", account: item.accountID) }
                                }
                            }
                            health[source.id] = SourceHealth(id: source.id, title: source.name, accountID: account.id, state: "ok", detail: "\(values.count) item(ns) atualizado(s)", date: Date())
                        } catch is CancellationError { return }
                        catch { health[source.id] = SourceHealth(id: source.id, title: source.name, accountID: account.id, state: "error", detail: error.localizedDescription, date: nil) }
                    }
                } catch is CancellationError { return }
                catch { health[collectionID] = SourceHealth(id: collectionID, title: title, accountID: account.id, state: "error", detail: error.localizedDescription, date: nil) }
            }
        }
        do { try await reloadCache() } catch { tell(error.localizedDescription, error: true) }
    }

    func read(_ message: MailMessage?) async {
        bodyGeneration += 1; let generation = bodyGeneration
        body = nil; guard let message else { return }
        isReading = true; defer { if generation == bodyGeneration { isReading = false } }
        if isDemo { body = DemoData.body(message); return }
        guard let account = account(message.accountID), let store else { return }
        do {
            let cached = try await store.values(MailBody.self, bucket: "body", account: account.id, source: message.remoteID).first
            guard generation == bodyGeneration else { return }
            body = cached
            if message.remoteID.hasPrefix("local-sent:"), !account.provider.usesOAuth { return }
            let loaded = try await client(account).mailBody(message)
            try await store.put(loaded, id: message.remoteID, bucket: "body", account: account.id, source: message.remoteID)
            guard generation == bodyGeneration else { return }
            body = loaded
            // Reading the body does not mutate remote read status; the explicit action below does.
        } catch { if generation == bodyGeneration { tell("Leitura: " + error.localizedDescription + (body == nil ? "" : " Exibindo cópia local."), error: true) } }
    }

    func mailAction(_ message: MailMessage, action: String) async {
        guard let store, let account = account(message.accountID), !operations.contains(message.id) else { return }
        let source = activeMailSource, originalMailbox = selectedMailbox
        operations.insert(message.id); defer { operations.remove(message.id) }
        do {
            var changed = message
            if action == "read" {
                if !isDemo { try await client(account).setRead(message, read: !message.isRead) }; changed.isRead.toggle()
            } else if action == "flag" {
                if !isDemo { try await client(account).setFlag(message, flagged: !message.isFlagged) }; changed.isFlagged.toggle()
            } else if let destination = MailFolder(rawValue: action) {
                if !isDemo { try await client(account).move(message, to: destination, fromMailbox: originalMailbox) }
                try await store.remove(id: message.remoteID, bucket: "mail", account: account.id, source: source)
                if account.provider.usesOAuth { try await store.saveMail([message], account: account.id, folder: destination.rawValue, replace: false) }
                selectedMessageID = nil; body = nil
                try await reloadCache(); await refreshMailboxes(accountID: account.id)
                tell(isDemo ? "Demonstração: item movido apenas nos dados fictícios." : "Item movido no provedor."); return
            }
            try await store.saveMail([changed], account: account.id, folder: source, replace: false)
            try await reloadCache()
            if account.provider == .pop3 { tell("POP3: marcação alterada somente neste Mac.") }
            else if action == "read" { await refreshMailboxes(accountID: account.id) }
        } catch { tell(error.localizedDescription + " Atualize para conferir o estado remoto antes de repetir.", error: true) }
    }

    func respond(_ item: AgendaItem, response: InvitationResponse) async {
        guard let store, let account = account(item.accountID), !operations.contains(item.id), !unresolvedResponses.contains(item.id) else { return }
        operations.insert(item.id); defer { operations.remove(item.id) }
        do {
            let pending = PendingResponse(itemID: item.id, accountID: item.accountID, response: response)
            try await store.put(pending, id: item.id, bucket: "pending-response", account: item.accountID)
            pendingResponses[item.id] = pending
            var changed: AgendaItem
            if isDemo { changed = item; changed.response = response.rawValue }
            else { changed = try await client(account).respond(item, response: response) }
            try await store.put(changed, id: item.remoteID, bucket: item.kind.rawValue, account: item.accountID, source: item.sourceID)
            try await store.remove(id: item.id, bucket: "pending-response", account: item.accountID)
            try await reloadCache()
            tell(isDemo ? "Demonstração: resposta alterada apenas nos dados fictícios. Nenhum convite foi respondido." : "\(response.statusLabel) por \(account.email). Estado confirmado no provedor.")
        } catch {
            if case OrbitaError.uncertain = error { unresolvedResponses.insert(item.id) }
            else {
                try? await store.remove(id: item.id, bucket: "pending-response", account: item.accountID)
                pendingResponses.removeValue(forKey: item.id)
            }
            tell(error.localizedDescription, error: true)
        }
    }

    func complete(_ item: AgendaItem) async {
        guard let store, let account = account(item.accountID), !operations.contains(item.id) else { return }
        operations.insert(item.id); defer { operations.remove(item.id) }
        do {
            var changed: AgendaItem
            if isDemo { changed = item; changed.isCompleted.toggle() }
            else { changed = try await client(account).complete(item, completed: !item.isCompleted) }
            try await store.put(changed, id: item.remoteID, bucket: "task", account: item.accountID, source: item.sourceID)
            try await reloadCache()
            tell(isDemo ? "Demonstração: tarefa alterada apenas nos dados fictícios." : "Estado da tarefa confirmado em \(account.email).")
        } catch { tell(error.localizedDescription + " Atualize para conferir a tarefa antes de repetir.", error: true) }
    }

    func saveDraft(_ draft: MailDraft) async {
        guard let store, !draft.isEmpty else { return }
        do {
            let existing = try await store.values(MailDraft.self, bucket: "draft")
            for old in existing where old.id == draft.id && old.accountID != draft.accountID {
                try await store.remove(id: old.id, bucket: "draft", account: old.accountID)
            }
            try await store.put(draft, id: draft.id, bucket: "draft", account: draft.accountID)
            drafts = try await store.values(MailDraft.self, bucket: "draft")
        }
        catch { tell("Não foi possível salvar o rascunho: " + error.localizedDescription, error: true) }
    }

    func newDraft(reply: MailMessage? = nil, replyAll: Bool = false, forward: Bool = false) {
        guard let from = reply.flatMap({ account($0.accountID) }) ?? visibleAccounts.first else { showAccounts = true; return }
        var draft = MailDraft(accountID: from.id)
        if let reply {
            draft.subject = (forward ? "Enc: " : "Re: ") + reply.subject
            draft.to = forward ? "" : reply.sender
            if replyAll { draft.cc = Array(Set(reply.to + reply.cc).subtracting([from.email, reply.sender])).sorted().joined(separator: ", ") }
            if !forward { draft.replyToRemoteID = reply.remoteID; draft.threadID = reply.threadID; draft.inReplyTo = reply.internetMessageID }
            draft.text = "\n\n— \(reply.sender), \(reply.date.formatted(date: .abbreviated, time: .shortened)) —\n" + (body?.plainText.nilIfEmpty ?? reply.preview)
            if forward && (reply.hasAttachments || body?.attachments.isEmpty == false) {
                draft.text += "\n\n[Os anexos originais não foram incluídos. Anexe os arquivos desejados antes de enviar.]"
            }
        }
        applyDefaultSignature(to: &draft)
        composeDraft = draft
    }

    func send(_ draft: MailDraft) async -> Bool {
        guard let store, let account = account(draft.accountID), !isSending else { return false }
        do { try MailValidation.validate(draft) } catch { tell(error.localizedDescription, error: true); return false }
        guard draft.deliveryState == "draft" else { tell("Confira a pasta Enviados antes de permitir um novo envio deste rascunho.", error: true); return false }
        isSending = true; defer { isSending = false }
        var pending = draft; pending.deliveryState = "submitting"
        do {
            try await store.put(pending, id: draft.id, bucket: "draft", account: account.id)
            if !isDemo { try await client(account).send(draft) }
            if account.provider == .pop3 {
                let id = "local-sent:" + draft.id
                let sent = MailMessage(remoteID: id, accountID: account.id, subject: draft.subject, sender: account.email, senderName: account.name,
                    to: try MailValidation.recipients(draft.to), cc: try MailValidation.recipients(draft.cc), date: Date(), preview: String(draft.composedText.prefix(250)), isRead: true, hasAttachments: !draft.attachments.isEmpty)
                try await store.saveMail([sent], account: account.id, folder: "sent", replace: false)
                let attachments = draft.attachments.map { MailAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, size: $0.data.count) }
                try await store.put(MailBody(text: draft.composedText, attachments: attachments), id: id, bucket: "body", account: account.id, source: id)
                for attachment in draft.attachments { try await store.put(attachment, id: attachment.id, bucket: "local-attachment", account: account.id, source: id) }
            }
            try await store.remove(id: draft.id, bucket: "draft", account: account.id)
            try await reloadCache()
            tell(isDemo ? "Demonstração: nenhum email foi enviado." : "Envio aceito pelo provedor de \(account.email). Isso não confirma a entrega ao destinatário.")
            return true
        } catch {
            pending.deliveryState = "uncertain"
            try? await store.put(pending, id: draft.id, bucket: "draft", account: account.id)
            composeDraft = pending
            tell("Envio não confirmado. Confira a pasta Enviados antes de reenviar. " + error.localizedDescription, error: true)
            return false
        }
    }

    func saveConfiguration(_ value: OAuthConfiguration, googleSecret: String) async -> Bool {
        guard let store, !isDemo else { tell("Saia da demonstração para configurar conexões reais."); return false }
        do {
            try await store.put(value, id: "oauth", bucket: "configuration")
            if !googleSecret.isEmpty { try await vault.save(googleSecret, key: "google-secret:" + value.googleClientID) }
            configuration = value; tell("Configuração OAuth salva neste Mac."); return true
        } catch { tell(error.localizedDescription, error: true); return false }
    }

    func connect(_ provider: Provider, expectedEmail: String? = nil, mailSettings: Bool = false) async {
        guard provider.usesOAuth else { tell("Use a opção Outro provedor para configurar servidores."); return }
        guard let store, !isDemo, !isConnecting else { return }
        isConnecting = true; defer { isConnecting = false; oauth = nil }
        let clientID = configuration.clientID(for: provider).trimmingCharacters(in: .whitespacesAndNewlines)
        let session = OAuthSession(); oauth = session
        var temporaryID: String?
        do {
            let secret = provider == .google ? try await vault.load(String.self, key: "google-secret:" + clientID) ?? "" : ""
            let token = try await session.connect(provider: provider, clientID: clientID, googleSecret: secret, loginHint: expectedEmail, mailSettings: mailSettings)
            // Discover identity with the new token before committing an account to the cache.
            let temporary = Account(provider: provider, email: UUID().uuidString + "@oauth.local", name: "", clientID: clientID)
            temporaryID = temporary.id; try await vault.save(token, key: temporary.id)
            let provisional = ProviderClient(account: temporary, vault: vault)
            let (email, name) = try await provisional.profile()
            try OAuth.validateIdentity(expectedEmail: expectedEmail, actualEmail: email)
            let found = Account(provider: provider, email: email, name: name, clientID: clientID,
                                colorIndex: accounts.first { $0.provider == provider && $0.email.lowercased() == email.lowercased() }?.colorIndex ?? accounts.count)
            try await vault.save(token, key: found.id)
            try await store.put(found, id: found.id, bucket: "account")
            try await vault.remove(key: temporary.id); temporaryID = nil
            clients.removeValue(forKey: found.id)
            try await reloadCache(); showAccounts = false
            tell("Conta conectada. Sincronizando email, calendários e tarefas.")
            refreshAll()
        } catch is CancellationError { tell("Conexão cancelada.") }
        catch { tell(error.localizedDescription, error: true) }
        if let temporaryID { try? await vault.remove(key: temporaryID) }
    }

    func cancelConnection() { oauth?.cancel() }

    func connectServer(provider: Provider, email: String, name: String, configuration: MailServerConfiguration, credentials: ServerCredentials) async -> Bool {
        guard let store, !isDemo, !isConnecting, !provider.usesOAuth else { return false }
        isConnecting = true; defer { isConnecting = false }
        var temporaryID: String?
        do {
            let addresses = try MailValidation.recipients(email.trimmingCharacters(in: .whitespacesAndNewlines))
            guard addresses.count == 1 else { throw OrbitaError.invalidData("Informe um endereço de email.") }
            let config = try configuration.validated(provider: provider)
            var account = Account(provider: provider, email: addresses[0].lowercased(), name: name.isEmpty ? addresses[0] : name, clientID: "",
                colorIndex: accounts.first { $0.provider == provider && $0.email.caseInsensitiveCompare(addresses[0]) == .orderedSame }?.colorIndex ?? accounts.count, serverConfiguration: config)
            let previous = try await vault.load(ServerCredentials.self, key: ServerCredentials.key(account.id))
            var secret = credentials
            if secret.password.isEmpty { secret.password = previous?.password ?? "" }
            if secret.smtpPassword.isEmpty { secret.smtpPassword = previous?.smtpPassword ?? "" }
            if secret.caldavPassword.isEmpty { secret.caldavPassword = previous?.caldavPassword ?? "" }
            guard !secret.password.isEmpty else { throw OrbitaError.authentication("Informe a senha ou senha de aplicativo.") }
            if provider != .exchange && !config.sameSMTPAuthentication && secret.smtpPassword.isEmpty { throw OrbitaError.authentication("Informe a senha SMTP.") }
            if !config.caldavURL.isEmpty && !config.sameCalDAVAuthentication && secret.caldavPassword.isEmpty { throw OrbitaError.authentication("Informe a senha CalDAV.") }
            var provisional = account; provisional.id = "server-test:" + UUID().uuidString
            temporaryID = provisional.id
            try await vault.save(secret, key: ServerCredentials.key(provisional.id))
            let service = ProviderClient(account: provisional, vault: vault)
            account.serverConfiguration = try await service.verifyServerConfiguration()
            try Task.checkCancellation()
            try await vault.save(secret, key: ServerCredentials.key(account.id))
            do { try await store.put(account, id: account.id, bucket: "account") }
            catch {
                if let previous { try? await vault.save(previous, key: ServerCredentials.key(account.id)) }
                else { try? await vault.remove(key: ServerCredentials.key(account.id)) }
                throw error
            }
            try? await vault.remove(key: ServerCredentials.key(provisional.id)); temporaryID = nil
            clients.removeValue(forKey: account.id)
            health = health.filter { $0.value.accountID != account.id }
            if provider != .exchange && config.caldavURL.isEmpty {
                for kind in [AgendaKind.event, .task] { try await store.replaceSources([], account: account.id, kind: kind) }
            }
            try await reloadCache(); tell("Conta configurada. Servidores autenticados; sincronizando os recursos disponíveis.")
            refreshAll(); return true
        } catch is CancellationError { tell("Configuração cancelada.") }
        catch { tell(error.localizedDescription, error: true) }
        if let temporaryID { try? await vault.remove(key: ServerCredentials.key(temporaryID)) }
        return false
    }

    func importSettings(_ manifest: OutlookImportManifest, selectedEmails: Set<String>, selectedPresetIDs: Set<String>) async -> Bool {
        guard let store, !isDemo else { tell("Saia da demonstração para importar configurações reais."); return false }
        do {
            let valid = try manifest.validated()
            let accounts = valid.accounts.filter { selectedEmails.contains($0.id) }
            let presets = valid.presets.filter { selectedPresetIDs.contains($0.id) }
            guard !accounts.isEmpty || !presets.isEmpty else { throw OrbitaError.invalidData("Selecione ao menos uma conta ou configuração para importar.") }
            try await store.saveImportedSettings(accounts: accounts, presets: presets)
            try await reloadCache()
            tell("\(accounts.count) conta(s) e \(presets.count) configuração(ões) importadas para conferência. Autorize por OAuth ou configure os servidores de cada conta. Assinaturas e modelos ficam disponíveis no editor como texto simples.")
            return true
        } catch { tell(error.localizedDescription, error: true); return false }
    }

    func updateImportedProvider(_ candidate: ImportedAccount, provider: Provider?) async {
        guard let store, !isDemo else { return }
        var changed = candidate; changed.provider = provider
        do { try await store.put(changed, id: changed.id, bucket: "imported-account"); try await reloadCache() }
        catch { tell(error.localizedDescription, error: true) }
    }

    func disconnect(_ account: Account) async {
        guard !busy, let store, !isDemo else { return }
        do {
            try await vault.remove(key: account.id); try await store.removeAccount(account.id)
            try await vault.remove(key: ServerCredentials.key(account.id))
            clients.removeValue(forKey: account.id); health = health.filter { $0.value.accountID != account.id }
            if accountFilter == account.id { accountFilter = nil }
            selectedMessageID = nil; selectedAgendaID = nil; body = nil
            try await reloadCache(); tell("Conta desconectada deste Mac. Os dados no provedor foram preservados.")
        } catch { tell(error.localizedDescription, error: true) }
    }

    func toggleSource(_ source: AgendaSource) async {
        if hiddenSources.contains(source.id) { hiddenSources.remove(source.id) } else { hiddenSources.insert(source.id) }
        do { try await store?.put(Array(hiddenSources), id: "hidden", bucket: "hidden-sources") }
        catch { tell(error.localizedDescription, error: true) }
    }

    func download(_ attachment: MailAttachment, message: MailMessage) async {
        guard !isDemo, let account = account(message.accountID) else { tell("Anexos reais não são baixados na demonstração."); return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = (attachment.name as NSString).lastPathComponent
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let data: Data
            if message.remoteID.hasPrefix("local-sent:"), let store {
                let values = try await store.values(OutgoingAttachment.self, bucket: "local-attachment", account: account.id, source: message.remoteID)
                guard let cached = values.first(where: { $0.id == attachment.id }) else { throw OrbitaError.invalidData("Anexo local não encontrado.") }
                data = cached.data
            } else { data = try await client(account).attachmentData(message: message, attachmentID: attachment.id) }
            try data.write(to: target, options: .atomic)
            // Never open an attachment automatically. Quarantine signals that it came from the network.
            let quarantine = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Orbita;"
            quarantine.withCString { value in _ = setxattr(target.path, "com.apple.quarantine", value, strlen(value), 0, 0) }
            tell("Anexo salvo. Abra-o somente se confiar no remetente.")
        } catch { tell(error.localizedDescription, error: true) }
    }
}
