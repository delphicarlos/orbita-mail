import Foundation
import OrbitaCore

extension AppModel {
    var activeMailSource: String { selectedMailbox?.cacheSource ?? folder.rawValue }
    var activeUnreadText: String {
        if let selectedMailbox { return mailboxes.first(where: { $0.id == selectedMailbox.id })?.unreadCount.map { $0.formatted(.number.locale(Locale(identifier: "pt_BR"))) } ?? "—" }
        return unreadSummary(folder).text
    }
    var activeMailTitle: String { selectedMailbox?.name ?? folder.title }
    var customMailboxes: [MailboxFolder] { mailboxes.filter { $0.standard == nil && (accountFilter == nil || $0.accountID == accountFilter) } }

    func openMailOrganization(accountID: String? = nil) {
        organizationAccountID = accountID ?? accountFilter ?? accounts.first?.id ?? ""
        showMailOrganization = true
    }
    func unreadSummary(_ folder: MailFolder = .inbox, accountID: String? = nil, allAccounts: Bool = false) -> (text: String, help: String) {
        let targets = accounts.filter { accountID == nil ? (allAccounts || accountFilter == nil || $0.id == accountFilter) : $0.id == accountID }
        var count = 0, complete = true, local = false
        var oldest: Date?
        for account in targets {
            if account.provider == .pop3 {
                if folder == .inbox { count += localUnreadCounts[account.id] ?? 0; local = true }
                complete = false; continue
            }
            if let box = mailboxes.first(where: { $0.accountID == account.id && $0.standard == folder }), let total = box.unreadCount {
                count += total; oldest = min(oldest ?? box.updatedAt, box.updatedAt)
            } else { complete = false }
        }
        let formatted = count.formatted(.number.locale(Locale(identifier: "pt_BR")))
        let text = targets.isEmpty ? "" : complete ? formatted : count > 0 ? formatted + "+" : "—"
        var help = complete ? "\(count) email(s) não lido(s), conforme última consulta ao provedor." : "Total parcial ou indisponível. + indica que faltam contagens; — não significa zero."
        if local { help += " POP3: não lidos apenas entre as mensagens carregadas neste Mac." }
        if let oldest { help += " Consulta: " + oldest.formatted(date: .abbreviated, time: .shortened) + "." }
        if health.values.contains(where: { $0.id.hasPrefix("mailboxes:") && targets.map(\.id).contains($0.accountID) && $0.state == "error" }) { help += " Há falha de atualização; confira Fontes e sincronização." }
        return (text, help)
    }
    func refreshMailboxes(accountID: String? = nil) async {
        guard let store else { return }
        if isDemo {
            for account in accounts {
                var boxes = mailboxes.filter { $0.accountID == account.id }
                if boxes.isEmpty { boxes = MailFolder.allCases.map { MailboxFolder(accountID: account.id, remoteID: $0.rawValue, name: $0.title, standard: $0, unreadCount: 0) } }
                for index in boxes.indices {
                    let messages = try? await store.values(MailMessage.self, bucket: "mail", account: account.id, source: boxes[index].cacheSource)
                    boxes[index].unreadCount = messages?.filter { !$0.isRead }.count ?? 0
                    boxes[index].totalCount = messages?.count ?? 0
                }
                try? await store.replaceMailboxes(boxes, account: account.id)
            }
            try? await reloadCache(); return
        }
        guard !isRefreshingMailboxes else { return }
        isRefreshingMailboxes = true; defer { isRefreshingMailboxes = false }
        for account in accounts where accountID == nil || account.id == accountID {
            guard !Task.isCancelled else { return }
            if account.provider == .pop3 { continue }
            let id = "mailboxes:" + account.id
            health[id] = SourceHealth(id: id, title: "Pastas e não lidos", accountID: account.id, state: "loading", detail: "Consultando totais no provedor", date: nil)
            do {
                let boxes = try await client(account).mailboxes()
                try Task.checkCancellation()
                try await store.replaceMailboxes(boxes, account: account.id)
                health[id] = SourceHealth(id: id, title: "Pastas e não lidos", accountID: account.id, state: "ok", detail: "\(boxes.count) pasta(s)/marcador(es); totais consultados no provedor", date: Date())
            } catch is CancellationError { return }
            catch { health[id] = SourceHealth(id: id, title: "Pastas e não lidos", accountID: account.id, state: "error", detail: error.localizedDescription, date: nil) }
        }
        try? await reloadCache()
    }
    func selectMailbox(_ box: MailboxFolder) async {
        guard account(box.accountID) != nil else { return }
        accountFilter = box.accountID; selectedMailbox = box; workspace = .mail
        selectedMessageID = nil; body = nil; cursors = [:]
        do { try await reloadCache() } catch { tell(error.localizedDescription, error: true) }
        await refreshMail()
    }
    func createMailbox(accountID: String, name: String) async throws -> MailboxFolder {
        guard let account = account(accountID), let store else { throw OrbitaError.invalidData("Selecione a conta.") }
        let valid = try MailboxFolder.validateName(name)
        let box: MailboxFolder
        if isDemo {
            guard !mailboxes.contains(where: { $0.accountID == accountID && $0.name.caseInsensitiveCompare(valid) == .orderedSame }) else { throw OrbitaError.invalidData("Já existe uma pasta com esse nome.") }
            box = MailboxFolder(accountID: accountID, remoteID: "demo:" + UUID().uuidString, name: valid, unreadCount: 0, totalCount: 0)
        } else { box = try await client(account).createMailbox(name: valid) }
        try await store.put(box, id: box.remoteID, bucket: "mailbox", account: accountID)
        try await reloadCache()
        tell(isDemo ? "Pasta criada somente na demonstração." : "Pasta criada no provedor de \(account.email).")
        return box
    }
    func moveMessage(_ message: MailMessage, to box: MailboxFolder) async {
        guard let store, let account = account(message.accountID), message.accountID == box.accountID, !operations.contains(message.id) else { return }
        let source = activeMailSource, original = selectedMailbox
        operations.insert(message.id); defer { operations.remove(message.id) }
        do {
            if !isDemo { try await client(account).move(message, toMailbox: box, from: original) }
            try await store.remove(id: message.remoteID, bucket: "mail", account: account.id, source: source)
            if isDemo { try await store.saveMail([message], account: account.id, folder: box.cacheSource, replace: false) }
            selectedMessageID = nil; body = nil
            try await reloadCache(); await refreshMailboxes(accountID: account.id)
            tell(isDemo ? "Demonstração: mensagem movida localmente." : "Mensagem movida para \(box.name).")
        } catch { tell(error.localizedDescription + " Atualize antes de repetir a movimentação.", error: true) }
    }
    func signature(for accountID: String, reply: Bool) -> WritingPreset? {
        guard let email = account(accountID)?.email, let preference = signaturePreferences.first(where: { $0.accountID == accountID }),
              let id = reply ? preference.replySignatureID : preference.newSignatureID else { return nil }
        return writingPresets.first { $0.id == id && $0.kind == .signature && ($0.accountEmail == nil || $0.accountEmail?.caseInsensitiveCompare(email) == .orderedSame) }
    }
    func applyDefaultSignature(to draft: inout MailDraft) {
        let preset = signature(for: draft.accountID, reply: draft.replyToRemoteID != nil)
        draft.signatureID = preset?.id; draft.signatureText = preset?.text
    }
    func saveSignature(_ preset: WritingPreset, replacing old: WritingPreset?, accountID: String, useForNew: Bool, useForReplies: Bool) async throws {
        guard let store, let account = account(accountID), preset.kind == .signature else { throw OrbitaError.invalidData("Selecione uma conta para a assinatura.") }
        _ = try OutlookImportManifest(accounts: [], presets: [preset]).validated()
        guard preset.accountEmail == nil || preset.accountEmail?.caseInsensitiveCompare(account.email) == .orderedSame else { throw OrbitaError.invalidData("A assinatura pertence a outra conta.") }
        try await store.put(preset, id: preset.id, bucket: "writing-preset")
        if let old, old.id != preset.id, old.accountEmail != nil {
            for var preference in signaturePreferences {
                if preference.newSignatureID == old.id { preference.newSignatureID = preset.id }
                if preference.replySignatureID == old.id { preference.replySignatureID = preset.id }
                try await store.put(preference, id: preference.accountID, bucket: "signature-preference", account: preference.accountID)
            }
            try await store.remove(id: old.id, bucket: "writing-preset")
        }
        var preference = signaturePreferences.first { $0.accountID == accountID } ?? SignaturePreference(accountID: accountID)
        if useForNew { preference.newSignatureID = preset.id } else if preference.newSignatureID == old?.id || preference.newSignatureID == preset.id { preference.newSignatureID = nil }
        if useForReplies { preference.replySignatureID = preset.id } else if preference.replySignatureID == old?.id || preference.replySignatureID == preset.id { preference.replySignatureID = nil }
        try await store.put(preference, id: accountID, bucket: "signature-preference", account: accountID)
        try await reloadCache(); tell("Assinatura salva neste Mac para \(account.email).")
    }
    func removeSignature(_ preset: WritingPreset) async throws {
        guard let store else { return }
        for var preference in signaturePreferences {
            if preference.newSignatureID == preset.id { preference.newSignatureID = nil }
            if preference.replySignatureID == preset.id { preference.replySignatureID = nil }
            try await store.put(preference, id: preference.accountID, bucket: "signature-preference", account: preference.accountID)
        }
        try await store.remove(id: preset.id, bucket: "writing-preset"); try await reloadCache()
    }
    func managedRules(accountID: String) async throws -> [RoutingRule] {
        guard let store else { return [] }
        return try await store.values(RoutingRule.self, bucket: "routing-rule", account: accountID)
    }
    func rules(accountID: String) async throws -> [RoutingRule] {
        guard let account = account(accountID) else { return [] }
        let known = try await managedRules(accountID: accountID)
        if isDemo { return known }
        var remote = try await client(account).routingRules(managedIDs: Set(known.map(\.id)))
        for index in remote.indices {
            if let local = known.first(where: { $0.id == remote[index].id }) { remote[index].name = local.name }
        }
        return remote
    }
    func createRule(_ rule: RoutingRule) async throws {
        guard let store, let account = account(rule.accountID) else { return }
        let saved = isDemo ? try rule.validated() : try await client(account).createRoutingRule(rule)
        try await store.put(saved, id: saved.id, bucket: "routing-rule", account: account.id)
    }
    func removeRule(_ rule: RoutingRule) async throws {
        guard let store, let account = account(rule.accountID) else { return }
        if !isDemo { try await client(account).removeRoutingRule(rule) }
        try await store.remove(id: rule.id, bucket: "routing-rule", account: account.id)
    }
    func replies(accountID: String) async throws -> AutoReplySettings {
        guard let account = account(accountID), let store else { return AutoReplySettings() }
        if isDemo { var value = try await store.values(AutoReplySettings.self, bucket: "auto-reply", account: account.id).first ?? AutoReplySettings(); value.revision = value.fingerprint; return value }
        return try await client(account).autoReplies()
    }
    func saveReplies(_ value: AutoReplySettings, accountID: String) async throws -> AutoReplySettings {
        guard let account = account(accountID), let store else { throw OrbitaError.invalidData("Selecione a conta.") }
        if isDemo { var confirmed = try value.validated(provider: account.provider); confirmed.revision = confirmed.fingerprint; try await store.put(confirmed, id: "current", bucket: "auto-reply", account: accountID); return confirmed }
        return try await client(account).saveAutoReplies(value)
    }
    func settingsAuthorized(accountID: String) async -> Bool {
        guard let account = account(accountID) else { return false }
        if isDemo { return true }
        return (try? await client(account).mailSettingsAuthorized()) ?? false
    }
}
