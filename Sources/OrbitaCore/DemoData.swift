import Foundation

public enum DemoData {
    public static var accounts: [Account] {
        [Account(provider: .microsoft, email: "ana@atlas.example", name: "Ana · Atlas", clientID: "demo", colorIndex: 0),
         Account(provider: .google, email: "ana@lume.example", name: "Ana · Lume", clientID: "demo", colorIndex: 1),
         Account(provider: .microsoft, email: "ana@pessoal.example", name: "Ana · Pessoal", clientID: "demo", colorIndex: 2)]
    }
    public static func sources() -> [AgendaSource] {
        accounts.flatMap { account in [AgendaSource(accountID: account.id, remoteID: "calendar", name: "Calendário", kind: .event),
                                      AgendaSource(accountID: account.id, remoteID: "tasks", name: "Minhas tarefas", kind: .task)] }
    }
    public static func agenda(now: Date = Date()) -> [AgendaItem] {
        let base = Calendar.current.startOfDay(for: now)
        func at(_ hour: Int, _ minute: Int = 0) -> Date { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base)! }
        let a = accounts
        return [
            AgendaItem(accountID: a[0].id, sourceID: "calendar", sourceName: "Calendário", remoteID: "weekly", kind: .event,
                       title: "Alinhamento da semana", start: at(9, 30), end: at(10), location: "Reunião online", response: "accepted", canRespond: true, iCalUID: "weekly@demo.example"),
            AgendaItem(accountID: a[1].id, sourceID: "calendar", sourceName: "Calendário", remoteID: "weekly", kind: .event,
                       title: "Alinhamento da semana", start: at(9, 30), end: at(10), response: "needsAction", canRespond: true, iCalUID: "weekly@demo.example"),
            AgendaItem(accountID: a[1].id, sourceID: "calendar", sourceName: "Calendário", remoteID: "review", kind: .event,
                       title: "Revisão da proposta", start: at(14), end: at(15), location: "Sala de projetos", response: "needsAction", canRespond: true),
            AgendaItem(accountID: a[2].id, sourceID: "calendar", sourceName: "Calendário", remoteID: "appointment", kind: .event,
                       title: "Compromisso pessoal", start: at(14, 30), end: at(15, 30), response: "organizer"),
            AgendaItem(accountID: a[0].id, sourceID: "tasks", sourceName: "Minhas tarefas", remoteID: "proposal", kind: .task,
                       title: "Finalizar proposta comercial", day: Time.dayKey(base)),
            AgendaItem(accountID: a[1].id, sourceID: "tasks", sourceName: "Minhas tarefas", remoteID: "review", kind: .task,
                       title: "Revisar materiais da reunião", day: Time.dayKey(base)),
            AgendaItem(accountID: a[2].id, sourceID: "tasks", sourceName: "Minhas tarefas", remoteID: "reading", kind: .task,
                       title: "Organizar leituras da semana"),
            AgendaItem(accountID: a[0].id, sourceID: "calendar", sourceName: "Calendário", remoteID: "tomorrow", kind: .event,
                       title: "Planejamento do próximo ciclo", start: at(11).addingTimeInterval(86400), end: at(12).addingTimeInterval(86400), response: "accepted", canRespond: true)
        ]
    }
    public static func messages(now: Date = Date()) -> [MailMessage] {
        let subjects = ["Próximos passos da proposta", "Convite: revisão da proposta", "Materiais para nosso alinhamento",
                        "Resumo da semana", "Documentos revisados", "Bem-vinda à sua agenda unificada"]
        return subjects.enumerated().map { index, subject in
            let account = accounts[index % accounts.count]
            return MailMessage(remoteID: "message-\(index)", accountID: account.id, threadID: "thread-\(index)", subject: subject,
                               sender: index == 1 ? "bruno@lume.example" : "equipe@atlas.example", senderName: index == 1 ? "Bruno Almeida" : "Equipe Atlas",
                               to: [account.email], date: now.addingTimeInterval(Double(-index * 2100)),
                               preview: "Olá, Ana. Reunimos as informações para o nosso próximo encontro. Confira os detalhes e os próximos passos.",
                               isRead: index > 1, isFlagged: index == 0)
        }
    }
    public static func body(_ message: MailMessage) -> MailBody {
        MailBody(text: "Olá, Ana.\n\nReunimos as informações para o nosso próximo encontro. A proposta está pronta para sua revisão.\n\nVocê pode acompanhar os compromissos e as tarefas de todas as suas contas na agenda unificada.\n\nEste email é fictício e existe apenas para demonstrar o aplicativo.\n\nAté breve,\nEquipe Atlas")
    }
}
