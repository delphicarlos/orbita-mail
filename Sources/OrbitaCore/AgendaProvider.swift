import Foundation

public extension ProviderClient {
    func sources(kind: AgendaKind) async throws -> [AgendaSource] {
        if account.provider == .exchange { return try await serverClient().ews().sources(kind: kind) }
        if !account.provider.usesOAuth { return try await serverClient().dav().sources(kind: kind) }
        if account.provider == .microsoft {
            let objects = try await graphPages(graph(kind == .event ? "/me/calendars" : "/me/todo/lists"))
            return try objects.map {
                AgendaSource(accountID: account.id, remoteID: try $0.required("id"),
                             name: $0.string(kind == .event ? "name" : "displayName"), kind: kind,
                             canEdit: kind == .task || $0.flag("canEdit"))
            }
        }
        let values = kind == .event
            ? try await googlePages("https://www.googleapis.com/calendar/v3/users/me/calendarList", query: ["maxResults": "250", "showHidden": "true"])
            : try await googlePages("https://tasks.googleapis.com/tasks/v1/users/@me/lists", query: ["maxResults": "100"])
        return try values.map {
            AgendaSource(accountID: account.id, remoteID: try $0.required("id"),
                         name: $0.string(kind == .event ? "summary" : "title"), kind: kind,
                         canEdit: kind == .task || ["owner", "writer"].contains($0.string("accessRole")))
        }
    }

    func agenda(source: AgendaSource, interval: DateInterval) async throws -> [AgendaItem] {
        try validateAccount(source.accountID)
        if account.provider == .exchange { return try await serverClient().ews().agenda(source: source, interval: interval) }
        if !account.provider.usesOAuth { return try await serverClient().dav().agenda(source: source, interval: interval) }
        if account.provider == .microsoft {
            let path = source.kind == .event ? "/me/calendars/\(pathID(source.remoteID))/calendarView" : "/me/todo/lists/\(pathID(source.remoteID))/tasks"
            let query = source.kind == .event ? ["startDateTime": Time.iso(interval.start), "endDateTime": Time.iso(interval.end), "$top": "200"] : ["$top": "100"]
            let values = try await graphPages(graph(path, query: query))
            return try values.filter { !$0.flag("isCancelled") }.map { try Self.graphAgenda($0, source: source) }
        }
        if source.kind == .event {
            let values = try await googlePages("https://www.googleapis.com/calendar/v3/calendars/\(pathID(source.remoteID))/events", query: [
                "timeMin": Time.iso(interval.start), "timeMax": Time.iso(interval.end), "singleEvents": "true", "maxResults": "250", "showDeleted": "false"
            ])
            return try values.filter { $0.string("status") != "cancelled" }.map { try Self.googleAgenda($0, source: source) }
        }
        let values = try await googlePages("https://tasks.googleapis.com/tasks/v1/lists/\(pathID(source.remoteID))/tasks", query: [
            "maxResults": "100", "showCompleted": "true", "showHidden": "true", "showAssigned": "true", "showDeleted": "false"
        ])
        return try values.filter { !$0.flag("deleted") }.map { try Self.googleAgenda($0, source: source) }
    }

    static func graphAgenda(_ value: JSONObject, source: AgendaSource) throws -> AgendaItem {
        var item = AgendaItem(accountID: source.accountID, sourceID: source.remoteID, sourceName: source.name,
                              remoteID: try value.required("id"), kind: source.kind,
                              title: value.string(source.kind == .event ? "subject" : "title"), canEdit: source.canEdit)
        if source.kind == .task {
            item.isCompleted = value.string("status") == "completed"
            if !value.object("dueDateTime").isEmpty {
                item.start = try Time.graphDate(value.object("dueDateTime"))
                // To Do due dates are displayed as a dated task, not a meeting reservation.
                item.day = String(value.object("dueDateTime").string("dateTime").prefix(10))
                item.start = nil
            }
            return item
        }
        if value.flag("isAllDay") {
            item.day = try Time.graphAllDay(value.object("start"), originalZone: value.string("originalStartTimeZone"))
            item.endDay = try Time.graphAllDay(value.object("end"), originalZone: value.string("originalEndTimeZone").nilIfEmpty ?? value.string("originalStartTimeZone"))
            guard item.day.flatMap(Time.dayDate) != nil, item.endDay.flatMap(Time.dayDate) != nil else { throw OrbitaError.invalidData("Evento de dia inteiro sem data válida.") }
        } else {
            item.start = try Time.graphDate(value.object("start")); item.end = try Time.graphDate(value.object("end"))
        }
        item.location = value.object("location").string("displayName")
        item.meetingURL = value.object("onlineMeeting").string("joinUrl")
        item.response = value.flag("isOrganizer") ? "organizer" : value.object("responseStatus").string("response")
        item.canRespond = !value.flag("isOrganizer") && value.flag("isMeeting") && source.canEdit
        // Graph event has no isMeeting property in some responses; attendees still identify invitations.
        if !value.flag("isOrganizer") && !value.objects("attendees").isEmpty && source.canEdit { item.canRespond = true }
        item.iCalUID = value.string("iCalUId")
        return item
    }

    static func googleAgenda(_ value: JSONObject, source: AgendaSource) throws -> AgendaItem {
        var item = AgendaItem(accountID: source.accountID, sourceID: source.remoteID, sourceName: source.name,
                              remoteID: try value.required("id"), kind: source.kind,
                              title: value.string(source.kind == .event ? "summary" : "title"), canEdit: source.canEdit)
        if source.kind == .task {
            item.isCompleted = value.string("status") == "completed"
            if !value.string("due").isEmpty {
                let day = String(value.string("due").prefix(10))
                guard Time.dayDate(day) != nil else { throw OrbitaError.invalidData("Tarefa sem data válida.") }
                item.day = day
            }
            return item
        }
        if !value.object("start").string("date").isEmpty {
            item.day = value.object("start").string("date"); item.endDay = value.object("end").string("date")
            guard item.day.flatMap(Time.dayDate) != nil, item.endDay.flatMap(Time.dayDate) != nil else { throw OrbitaError.invalidData("Evento de dia inteiro sem data válida.") }
        } else {
            guard let start = Time.parse(value.object("start").string("dateTime")), let end = Time.parse(value.object("end").string("dateTime")) else {
                throw OrbitaError.invalidData("Evento Google sem horário/fuso válido.")
            }
            item.start = start; item.end = end
        }
        let attendee = value.objects("attendees").first { $0.flag("self") }
        item.response = value.object("organizer").flag("self") ? "organizer" : attendee?.string("responseStatus") ?? ""
        item.canRespond = attendee != nil && !value.object("organizer").flag("self") && source.canEdit
        item.location = value.string("location"); item.meetingURL = value.string("hangoutLink")
        if item.meetingURL.isEmpty {
            item.meetingURL = value.object("conferenceData").objects("entryPoints").first { $0.string("entryPointType") == "video" }?.string("uri") ?? ""
        }
        item.iCalUID = value.string("iCalUID")
        return item
    }

    private func eventURL(_ item: AgendaItem) throws -> URL {
        if account.provider == .microsoft { return try graph("/me/calendars/\(pathID(item.sourceID))/events/\(pathID(item.remoteID))") }
        return try google("https://www.googleapis.com/calendar/v3/calendars/\(pathID(item.sourceID))/events/\(pathID(item.remoteID))")
    }

    private func matches(_ raw: JSONObject, response: InvitationResponse) -> Bool {
        if account.provider == .google { return raw.objects("attendees").first { $0.flag("self") }?.string("responseStatus") == response.rawValue }
        let status = raw.object("responseStatus").string("response")
        return status == (response == .tentative ? "tentativelyAccepted" : response.rawValue)
    }

    func respond(_ item: AgendaItem, response: InvitationResponse) async throws -> AgendaItem {
        try validateAccount(item.accountID)
        if account.provider == .exchange { return try await serverClient().ews().respond(item, response: response) }
        if !account.provider.usesOAuth { return try await serverClient().dav().respond(item, response: response) }
        try validateAccount(item.accountID)
        guard item.kind == .event, item.canRespond else { throw OrbitaError.invalidData("Esta conta não pode responder a este convite.") }
        let url = try eventURL(item)
        let current = try await json(url)
        if !matches(current, response: response) {
            do {
                if account.provider == .microsoft {
                    _ = try await request(URL(string: url.absoluteString + "/" + response.graphAction)!, method: "POST", body: ["sendResponse": true])
                } else {
                    var attendees = current.objects("attendees")
                    guard let index = attendees.firstIndex(where: { $0.flag("self") }) else { throw OrbitaError.invalidData("A conta não está entre os convidados deste evento.") }
                    attendees[index]["responseStatus"] = response.rawValue
                    let etag = try current.required("etag")
                    let target = try Self.makeURL(url.absoluteString, query: ["sendUpdates": "all"])
                    // Arrays are replaced by Google PATCH. Preserve every other participant and use the read version.
                    _ = try await request(target, method: "PATCH", body: ["attendees": attendees], headers: ["If-Match": etag])
                }
            } catch let error as OrbitaError {
                switch error {
                case .network(let status, _) where [400, 401, 403, 404, 409, 412, 429].contains(status): throw error
                default: break // A timeout/5xx can happen after the write. Reconcile, never send again blindly.
                }
            } catch { /* Reconcile an ambiguous transport failure below. */ }
        }
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000) }
            do {
                let updated = try await json(url)
                if matches(updated, response: response) {
                    let source = AgendaSource(accountID: item.accountID, remoteID: item.sourceID, name: item.sourceName, kind: .event, canEdit: item.canEdit)
                    return try account.provider == .microsoft ? Self.graphAgenda(updated, source: source) : Self.googleAgenda(updated, source: source)
                }
            } catch { if attempt < 2 { continue } }
        }
        throw OrbitaError.uncertain("A resposta ainda não foi confirmada pelo provedor. Atualize a agenda e confira o estado antes de responder novamente.")
    }

    func complete(_ item: AgendaItem, completed: Bool) async throws -> AgendaItem {
        try validateAccount(item.accountID)
        if account.provider == .exchange { return try await serverClient().ews().complete(item, completed: completed) }
        if !account.provider.usesOAuth { return try await serverClient().dav().complete(item, completed: completed) }
        guard item.kind == .task, item.canEdit else { throw OrbitaError.invalidData("Esta tarefa está disponível somente para leitura.") }
        let url = account.provider == .microsoft
            ? try graph("/me/todo/lists/\(pathID(item.sourceID))/tasks/\(pathID(item.remoteID))")
            : try google("https://tasks.googleapis.com/tasks/v1/lists/\(pathID(item.sourceID))/tasks/\(pathID(item.remoteID))")
        let current = try await json(url)
        let expected = completed ? "completed" : account.provider == .microsoft ? "notStarted" : "needsAction"
        if current.string("status") != expected {
            let headers: [String: String] = account.provider == .google ? ["If-Match": try current.required("etag")] : [:]
            _ = try await request(url, method: "PATCH", body: ["status": expected], headers: headers)
        }
        let updated = try await json(url)
        guard updated.string("status") == expected else { throw OrbitaError.uncertain("O provedor ainda não confirmou o estado desta tarefa. Atualize antes de tentar novamente.") }
        let source = AgendaSource(accountID: item.accountID, remoteID: item.sourceID, name: item.sourceName, kind: .task, canEdit: item.canEdit)
        return try account.provider == .microsoft ? Self.graphAgenda(updated, source: source) : Self.googleAgenda(updated, source: source)
    }
}
