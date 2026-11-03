import Foundation

public extension Provider {
    var supportsServerMailSettings: Bool { usesOAuth || self == .exchange }
}

enum RuleEncoding {
    static func microsoft(_ rule: RoutingRule, sequence: Int) -> JSONObject {
        var conditions: JSONObject = [:]
        for (key, value) in [("senderContains", rule.sender), ("recipientContains", rule.recipient), ("subjectContains", rule.subject), ("bodyContains", rule.body)] where !value.isEmpty { conditions[key] = [value] }
        return ["displayName": rule.serverName, "sequence": sequence, "isEnabled": true, "conditions": conditions,
                "actions": ["moveToFolder": rule.destinationID, "stopProcessingRules": true]]
    }
    static func google(_ rule: RoutingRule) -> JSONObject {
        var criteria: JSONObject = [:]
        for (key, value) in [("from", rule.sender), ("to", rule.recipient), ("subject", rule.subject)] where !value.isEmpty { criteria[key] = value }
        if !rule.body.isEmpty { criteria["query"] = "\"" + rule.body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return ["criteria": criteria, "action": ["addLabelIds": [rule.destinationID], "removeLabelIds": ["INBOX"]]]
    }
    static func ews(_ rule: RoutingRule, priority: Int) -> String {
        let conditions = [("ContainsBodyStrings", rule.body), ("ContainsRecipientStrings", rule.recipient), ("ContainsSenderStrings", rule.sender), ("ContainsSubjectStrings", rule.subject)]
            .filter { !$0.1.isEmpty }.map { "<t:\($0.0)><t:String>\(MailXML.escape($0.1))</t:String></t:\($0.0)>" }.joined()
        return "<t:Rule><t:DisplayName>\(MailXML.escape(rule.serverName))</t:DisplayName><t:Priority>\(priority)</t:Priority><t:IsEnabled>true</t:IsEnabled><t:Conditions>\(conditions)</t:Conditions><t:Actions><t:MoveToFolder><t:FolderId Id=\"\(MailXML.escape(rule.destinationID))\"/></t:MoveToFolder><t:StopProcessingRules>true</t:StopProcessingRules></t:Actions></t:Rule>"
    }
}

public extension ProviderClient {
    func mailSettingsAuthorized() async throws -> Bool {
        if !account.provider.usesOAuth { return account.provider == .exchange }
        guard let token = try await vault.load(OAuthToken.self, key: account.id) else { return false }
        let needed = account.provider == .microsoft ? "mailboxsettings.readwrite" : "gmail.settings.basic"
        return token.scope.lowercased().split(separator: " ").contains { $0 == needed || $0.hasSuffix("/" + needed) }
    }
    func requireMailSettings() async throws {
        guard account.provider.supportsServerMailSettings else { throw OrbitaError.invalidData("IMAP e POP3 não configuram regras nem respostas automáticas no servidor. Use o painel do provedor; essas funções exigem uma API adicional.") }
        guard try await mailSettingsAuthorized() else { throw OrbitaError.authentication("Autorize as configurações de email desta conta para gerenciar regras e respostas automáticas.") }
    }
    func routingRules(managedIDs: Set<String> = []) async throws -> [RoutingRule] {
        try await requireMailSettings()
        if account.provider == .exchange { return try await serverClient().ews().routingRules() }
        if account.provider == .google {
            let value = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/settings/filters"))
            return try value.objects("filter").map { item in
                let id = try item.required("id"), criteria = item.object("criteria"), action = item.object("action")
                let target = (action["addLabelIds"] as? [String])?.first ?? ""
                return RoutingRule(id: id, accountID: account.id, name: "Filtro Gmail", sender: criteria.string("from"), recipient: criteria.string("to"), subject: criteria.string("subject"), body: criteria.string("query"), destinationID: target, managed: managedIDs.contains(id), summary: "Filtro executado no Gmail")
            }
        }
        let values = try await graphPages(graph("/me/mailFolders/inbox/messageRules"))
        return try values.map { item in
            let conditions = item.object("conditions"), actions = item.object("actions"), name = item.string("displayName")
            let own = name.hasPrefix("Órbita · ") && !item.flag("isReadOnly")
            func first(_ key: String) -> String { (conditions[key] as? [String])?.joined(separator: ", ") ?? "" }
            return RoutingRule(id: try item.required("id"), accountID: account.id, name: name, sender: first("senderContains"), recipient: first("recipientContains"), subject: first("subjectContains"), body: first("bodyContains"), destinationID: actions.string("moveToFolder"), enabled: item.flag("isEnabled"), managed: own, summary: own ? "Executada no servidor Microsoft" : "Regra existente · gerencie no Outlook")
        }
    }
    func createRoutingRule(_ input: RoutingRule) async throws -> RoutingRule {
        try validateAccount(input.accountID); let rule = try input.validated(); try await requireMailSettings()
        let folders = try await mailboxes()
        guard let target = folders.first(where: { $0.remoteID == rule.destinationID }), target.standard == nil else { throw OrbitaError.invalidData("Escolha uma pasta personalizada desta conta para receber as mensagens.") }
        let before = try await routingRules()
        do {
            if account.provider == .exchange { return try await serverClient().ews().createRoutingRule(rule) }
            let created: JSONObject
            if account.provider == .google {
                created = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/settings/filters"), method: "POST", body: RuleEncoding.google(rule))
            } else {
                let existing = try await graphPages(graph("/me/mailFolders/inbox/messageRules", query: ["$select": "sequence"]))
                let maximum = existing.map { Int($0.number("sequence")) }.max() ?? 0
                created = try await json(graph("/me/mailFolders/inbox/messageRules"), method: "POST", body: RuleEncoding.microsoft(rule, sequence: maximum + 1))
            }
            var saved = rule; saved.id = try created.required("id"); return saved
        } catch {
            // No write retry. A new Microsoft/EWS rule carries a unique name.
            if account.provider == .microsoft, let after = try? await routingRules(), let found = after.first(where: { $0.name == rule.serverName && !before.map(\.id).contains($0.id) }) { return found }
            throw OrbitaError.uncertain("A regra não foi confirmada. Atualize e confira as regras do provedor antes de criar novamente. " + error.localizedDescription)
        }
    }
    func removeRoutingRule(_ rule: RoutingRule) async throws {
        try validateAccount(rule.accountID); try await requireMailSettings()
        guard rule.managed else { throw OrbitaError.invalidData("Esta regra foi criada fora do Órbita. Gerencie-a no provedor.") }
        if account.provider == .exchange { try await serverClient().ews().removeRoutingRule(rule); return }
        let url = account.provider == .microsoft ? try graph("/me/mailFolders/inbox/messageRules/\(pathID(rule.id))") : try google("https://gmail.googleapis.com/gmail/v1/users/me/settings/filters/\(pathID(rule.id))")
        _ = try await request(url, method: "DELETE")
    }
    func autoReplies() async throws -> AutoReplySettings {
        try await requireMailSettings()
        if account.provider == .exchange { return try await serverClient().ews().autoReplies() }
        var result = AutoReplySettings()
        if account.provider == .google {
            let value = try await json(google("https://gmail.googleapis.com/gmail/v1/users/me/settings/vacation"))
            result.enabled = value.flag("enableAutoReply"); result.subject = value.string("responseSubject")
            result.internalMessage = value.string("responseBodyPlainText").nilIfEmpty ?? AutoReplySettings.plainText(value.string("responseBodyHtml"))
            result.contactsOnly = value.flag("restrictToContacts"); result.domainOnly = value.flag("restrictToDomain")
            let end = Double(value.string("endTime")) ?? 0, start = Double(value.string("startTime")) ?? 0
            result.scheduled = end > 0 || start > 0; result.hasEnd = end > 0
            if result.scheduled { result.start = Date(timeIntervalSince1970: start / 1000); result.end = Date(timeIntervalSince1970: end / 1000) }
        } else {
            let value = try await json(graph("/me/mailboxSettings/automaticRepliesSetting"))
            guard ["disabled", "alwaysEnabled", "scheduled"].contains(value.string("status")) else { throw OrbitaError.invalidData("O Microsoft não retornou um estado válido de respostas automáticas.") }
            result.enabled = value.string("status") != "disabled"; result.scheduled = value.string("status") == "scheduled"
            result.internalMessage = AutoReplySettings.plainText(value.string("internalReplyMessage"))
            result.externalMessage = AutoReplySettings.plainText(value.string("externalReplyMessage"))
            result.externalAudience = ["none": "none", "contactsOnly": "contacts", "all": "all"][value.string("externalAudience")] ?? "none"
            if result.scheduled { result.start = try Time.graphDate(value.object("scheduledStartDateTime")); result.end = try Time.graphDate(value.object("scheduledEndDateTime")) }
        }
        result.revision = result.fingerprint; return result
    }
    func saveAutoReplies(_ input: AutoReplySettings) async throws -> AutoReplySettings {
        try await requireMailSettings(); let value = try input.validated(provider: account.provider)
        let previous = try await autoReplies()
        guard !value.revision.isEmpty, previous.revision == value.revision else { throw OrbitaError.invalidData("As respostas automáticas foram alteradas no servidor. Atualize antes de salvar.") }
        do {
            if account.provider == .exchange { try await serverClient().ews().saveAutoReplies(value) }
            else if account.provider == .google {
                var payload: JSONObject = ["enableAutoReply": value.enabled, "responseSubject": value.subject, "responseBodyPlainText": value.internalMessage, "restrictToContacts": value.contactsOnly, "restrictToDomain": value.domainOnly]
                if value.scheduled { payload["startTime"] = String(Int64(value.start.timeIntervalSince1970 * 1000)); if value.hasEnd { payload["endTime"] = String(Int64(value.end.timeIntervalSince1970 * 1000)) } }
                _ = try await request(google("https://gmail.googleapis.com/gmail/v1/users/me/settings/vacation"), method: "PUT", body: payload)
            } else {
                var payload: JSONObject = ["status": value.enabled ? (value.scheduled ? "scheduled" : "alwaysEnabled") : "disabled", "internalReplyMessage": AutoReplySettings.html(value.internalMessage), "externalReplyMessage": AutoReplySettings.html(value.externalMessage), "externalAudience": ["none": "none", "contacts": "contactsOnly", "all": "all"][value.externalAudience]!]
                if value.scheduled {
                    payload["scheduledStartDateTime"] = ["dateTime": String(Time.iso(value.start).dropLast()), "timeZone": "UTC"]
                    payload["scheduledEndDateTime"] = ["dateTime": String(Time.iso(value.end).dropLast()), "timeZone": "UTC"]
                }
                _ = try await request(graph("/me/mailboxSettings"), method: "PATCH", body: ["automaticRepliesSetting": payload])
            }
        } catch {
            // A network failure can follow a successful write; only reconcile by reading.
            if let confirmed = try? await autoReplies(), Self.sameReplies(confirmed, value, provider: account.provider) { return confirmed }
            throw OrbitaError.uncertain("Não foi possível confirmar as respostas automáticas. Atualize antes de repetir. " + error.localizedDescription)
        }
        let confirmed = try await autoReplies()
        guard Self.sameReplies(confirmed, value, provider: account.provider) else { throw OrbitaError.uncertain("O provedor ainda não confirmou a configuração. Atualize antes de repetir.") }
        return confirmed
    }
    static func sameReplies(_ a: AutoReplySettings, _ b: AutoReplySettings, provider: Provider) -> Bool {
        guard a.enabled == b.enabled else { return false }
        if !b.enabled { return true }
        guard a.scheduled == b.scheduled, a.internalMessage.trimmingCharacters(in: .whitespacesAndNewlines) == b.internalMessage.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if b.scheduled && (a.hasEnd != b.hasEnd || abs(a.start.timeIntervalSince(b.start)) >= 1 || (b.hasEnd && abs(a.end.timeIntervalSince(b.end)) >= 1)) { return false }
        if provider == .google { return a.subject == b.subject && a.contactsOnly == b.contactsOnly && a.domainOnly == b.domainOnly }
        return a.externalAudience == b.externalAudience && (b.externalAudience == "none" || a.externalMessage == b.externalMessage.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension EWSClient {
    func routingRules() async throws -> [RoutingRule] {
        let root = try await call("<m:GetInboxRules><m:MailboxSmtpAddress>\(MailXML.escape(account.email))</m:MailboxSmtpAddress></m:GetInboxRules>")
        return root.descendants("InboxRules").flatMap(\.children).map { node in
            let name = node.value("DisplayName"), conditions = node.child("Conditions")
            func text(_ field: String) -> String { conditions?.child(field)?.children.map(\.text).joined(separator: ", ") ?? "" }
            return RoutingRule(id: node.value("RuleId"), accountID: account.id, name: name, sender: text("ContainsSenderStrings"), recipient: text("ContainsRecipientStrings"), subject: text("ContainsSubjectStrings"), body: text("ContainsBodyStrings"), destinationID: node.child("Actions")?.child("MoveToFolder")?.child("FolderId")?.attributes["Id"] ?? "", enabled: node.value("IsEnabled") == "true", managed: name.hasPrefix("Órbita · ") && node.value("IsNotSupported") != "true", summary: "Regra Exchange · prioridade \(node.value("Priority"))")
        }
    }
    func createRoutingRule(_ rule: RoutingRule) async throws -> RoutingRule {
        let before = try await call("<m:GetInboxRules><m:MailboxSmtpAddress>\(MailXML.escape(account.email))</m:MailboxSmtpAddress></m:GetInboxRules>")
        let maximum = before.descendants("Priority").compactMap { Int($0.text) }.max() ?? 0
        // false is essential: never delete Outlook's client-rule blob to add a rule.
        _ = try await call("<m:UpdateInboxRules><m:MailboxSmtpAddress>\(MailXML.escape(account.email))</m:MailboxSmtpAddress><m:RemoveOutlookRuleBlob>false</m:RemoveOutlookRuleBlob><m:Operations><t:CreateRuleOperation>\(RuleEncoding.ews(rule, priority: maximum + 1))</t:CreateRuleOperation></m:Operations></m:UpdateInboxRules>")
        guard let created = try await routingRules().first(where: { $0.name == rule.serverName }) else { throw OrbitaError.uncertain("O Exchange não confirmou a regra criada. Confira no Outlook antes de repetir.") }
        return created
    }
    func removeRoutingRule(_ rule: RoutingRule) async throws {
        _ = try await call("<m:UpdateInboxRules><m:MailboxSmtpAddress>\(MailXML.escape(account.email))</m:MailboxSmtpAddress><m:RemoveOutlookRuleBlob>false</m:RemoveOutlookRuleBlob><m:Operations><t:DeleteRuleOperation><t:RuleId>\(MailXML.escape(rule.id))</t:RuleId></t:DeleteRuleOperation></m:Operations></m:UpdateInboxRules>")
    }
    func autoReplies() async throws -> AutoReplySettings {
        let root = try await call("<m:GetUserOofSettingsRequest><t:Mailbox><t:Address>\(MailXML.escape(account.email))</t:Address></t:Mailbox></m:GetUserOofSettingsRequest>")
        guard let settings = root.descendants("OofSettings").first else { throw OrbitaError.invalidData("O Exchange não retornou as respostas automáticas.") }
        var result = AutoReplySettings()
        guard ["Disabled", "Enabled", "Scheduled"].contains(settings.value("OofState")) else { throw OrbitaError.invalidData("O Exchange não retornou um estado válido de ausência.") }
        result.enabled = settings.value("OofState") != "Disabled"; result.scheduled = settings.value("OofState") == "Scheduled"
        result.externalAudience = ["None": "none", "Known": "contacts", "All": "all"][settings.value("ExternalAudience")] ?? "none"
        result.internalMessage = AutoReplySettings.plainText(settings.child("InternalReply")?.value("Message") ?? "")
        result.externalMessage = AutoReplySettings.plainText(settings.child("ExternalReply")?.value("Message") ?? "")
        if result.scheduled {
            guard let start = settings.child("Duration").flatMap({ Time.parse($0.value("StartTime")) }), let end = settings.child("Duration").flatMap({ Time.parse($0.value("EndTime")) }) else { throw OrbitaError.invalidData("Período de ausência Exchange inválido.") }
            result.start = start; result.end = end
        }
        result.revision = result.fingerprint; return result
    }
    func saveAutoReplies(_ value: AutoReplySettings) async throws {
        let state = value.enabled ? (value.scheduled ? "Scheduled" : "Enabled") : "Disabled"
        let audience = ["none": "None", "contacts": "Known", "all": "All"][value.externalAudience]!
        let duration = value.scheduled ? "<t:Duration><t:StartTime>\(Time.iso(value.start))</t:StartTime><t:EndTime>\(Time.iso(value.end))</t:EndTime></t:Duration>" : ""
        _ = try await call("<m:SetUserOofSettingsRequest><t:Mailbox><t:Address>\(MailXML.escape(account.email))</t:Address></t:Mailbox><t:UserOofSettings><t:OofState>\(state)</t:OofState><t:ExternalAudience>\(audience)</t:ExternalAudience>\(duration)<t:InternalReply><t:Message>\(MailXML.escape(AutoReplySettings.html(value.internalMessage)))</t:Message></t:InternalReply><t:ExternalReply><t:Message>\(MailXML.escape(AutoReplySettings.html(value.externalMessage)))</t:Message></t:ExternalReply></t:UserOofSettings></m:SetUserOofSettingsRequest>")
    }
}
