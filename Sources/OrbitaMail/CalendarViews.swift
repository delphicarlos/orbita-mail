import SwiftUI
import AppKit
import OrbitaCore

enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "Dia", week = "Semana", month = "Mês", agenda = "Agenda"
    var id: String { rawValue }
}

struct CalendarWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var mode: CalendarMode = .week
    private var days: [Date] {
        let calendar = Calendar.current
        let start: Date
        let count: Int
        switch mode {
        case .day: start = calendar.startOfDay(for: model.anchor); count = 1
        case .week: start = calendar.dateInterval(of: .weekOfYear, for: model.anchor)!.start; count = 7
        case .month, .agenda: start = model.syncInterval.start; count = 42
        }
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 15) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.anchor.formatted(.dateTime.month(.wide).year())).font(.system(size: 23, weight: .semibold))
                    Text(model.accountFilter.flatMap { model.account($0)?.email } ?? "Agenda unificada · todas as contas")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    Button { move(-1) } label: { Image(systemName: "chevron.left") }.help("Período anterior").accessibilityLabel("Período anterior")
                    Button("Hoje") { model.anchor = Date() }
                    Button { move(1) } label: { Image(systemName: "chevron.right") }.help("Próximo período").accessibilityLabel("Próximo período")
                }.controlSize(.small)
                Picker("Exibição", selection: $mode) { ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(width: 270)
            }.padding(.horizontal, 24).padding(.vertical, 20)
            HStack(spacing: 16) {
                Label("\(model.visibleAccounts.count) contas", systemImage: "person.crop.circle")
                Label("\(model.sources.filter { $0.kind == .event && (model.accountFilter == nil || $0.accountID == model.accountFilter) }.count) calendários", systemImage: "calendar")
                Label("\(model.sources.filter { $0.kind == .task && (model.accountFilter == nil || $0.accountID == model.accountFilter) }.count) listas de tarefas", systemImage: "checklist")
                Spacer()
                if !model.unresolvedResponses.isEmpty { Label("\(model.unresolvedResponses.count) resposta(s) a conferir", systemImage: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                else if model.isRefreshingAgenda { Text("Atualizando fontes…") }
                else if model.health.values.contains(where: { $0.state == "error" }) { Label("Há fontes indisponíveis", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                else { Text(model.isDemo ? "Dados fictícios" : "Consulte o estado de cada fonte na barra superior") }
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 13)
            Divider()
            HSplitView {
                Group {
                    if mode == .month { monthView }
                    else if mode == .agenda { agendaList }
                    else { TimeGrid(days: days) }
                }.frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 0) {
                    if let item = model.selectedAgenda { AgendaDetail(item: item) }
                    else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tarefas do período").font(.system(size: 16, weight: .semibold))
                            Text("Todas as listas selecionadas").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(model.visibleAgenda.filter { $0.kind == .task && !$0.isCompleted && $0.day != nil && $0.overlaps(model.syncInterval) }.sorted { ($0.day ?? "") < ($1.day ?? "") }) { item in
                                    TaskRow(item: item).padding(.horizontal, 16).padding(.vertical, 10)
                                    Divider().padding(.horizontal, 16)
                                }
                                Text("Pendências sem data").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 8)
                                ForEach(model.visibleAgenda.filter { $0.kind == .task && !$0.isCompleted && $0.displayDate == nil }) { item in
                                    TaskRow(item: item).padding(.horizontal, 16).padding(.vertical, 10)
                                }
                            }
                        }
                    }
                }.frame(minWidth: 245, idealWidth: 280, maxWidth: 340).background(Color(nsColor: .controlBackgroundColor))
            }
        }.background(Color(nsColor: .textBackgroundColor))
    }
    private func move(_ value: Int) {
        model.anchor = Calendar.current.date(byAdding: mode == .month || mode == .agenda ? .month : mode == .week ? .weekOfYear : .day,
                                            value: value, to: model.anchor)!
    }
    private func items(_ date: Date) -> [AgendaItem] {
        let interval = Calendar.current.dateInterval(of: .day, for: date)!
        return model.visibleAgenda.filter { !$0.isCompleted && $0.overlaps(interval) }.sorted { ($0.displayDate ?? .distantPast) < ($1.displayDate ?? .distantPast) }
    }
    private var monthView: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { date in
                    VStack(alignment: .leading, spacing: 6) {
                        Button { model.anchor = date; mode = .day } label: {
                            Text(date, format: .dateTime.day()).font(.system(size: 12, weight: Calendar.current.isDateInToday(date) ? .bold : .regular))
                                .foregroundStyle(Calendar.current.isDateInToday(date) ? OrbitaStyle.accent : Color.primary)
                        }.buttonStyle(.plain)
                        ForEach(Array(items(date).prefix(3))) { item in
                            Button { model.selectedAgendaID = item.id } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: item.kind == .task ? "checkmark.circle" : "circle.fill").font(.system(size: 7))
                                    Text(item.title).font(.system(size: 10)).lineLimit(1)
                                }.foregroundStyle(OrbitaStyle.color(model.account(item.accountID)?.colorIndex ?? 0))
                            }.buttonStyle(.plain)
                        }
                        if items(date).count > 3 {
                            Button("+\(items(date).count - 3) itens") { model.anchor = date; mode = .day }.font(.system(size: 10)).buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }.padding(9).frame(maxWidth: .infinity, minHeight: 115, alignment: .topLeading)
                        .background(Calendar.current.component(.month, from: date) == Calendar.current.component(.month, from: model.anchor) ? .clear : Color.secondary.opacity(0.04))
                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.13), lineWidth: 0.5))
                }
            }
        }
    }
    private var agendaList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(days, id: \.self) { date in
                    let dayItems = items(date)
                    if !dayItems.isEmpty {
                        Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 14, weight: .semibold)).padding(.top, 22).padding(.bottom, 12)
                        ForEach(dayItems) { item in AgendaListRow(item: item).padding(.vertical, 10); Divider() }
                    }
                }
                if days.allSatisfy({ items($0).isEmpty }) {
                    ContentUnavailableView("Nenhum item carregado neste período", systemImage: "calendar", description: Text("Confira as fontes e os filtros de calendário."))
                }
            }.padding(.horizontal, 24)
        }
    }
}

struct TimeGrid: View {
    @EnvironmentObject private var model: AppModel
    let days: [Date]
    private let hourHeight: CGFloat = 58
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(TimeZone.current.abbreviation() ?? "Local").font(.system(size: 8)).foregroundStyle(.secondary).frame(width: 40)
                ForEach(days, id: \.self) { date in
                    VStack(spacing: 6) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(date, format: .dateTime.day()).font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Calendar.current.isDateInToday(date) ? .white : Color.primary)
                            .frame(width: 31, height: 31).background(Calendar.current.isDateInToday(date) ? OrbitaStyle.accent : .clear, in: Circle())
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                Text("Dia").font(.system(size: 9)).foregroundStyle(.secondary).frame(width: 40).padding(.top, 10)
                ForEach(days, id: \.self) { date in
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(datedItems(date)) { item in
                            Button { model.selectedAgendaID = item.id } label: {
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: item.kind == .task ? "circle" : "calendar").font(.system(size: 8))
                                    Text(item.title).font(.system(size: 10)).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(5)
                                    .foregroundStyle(OrbitaStyle.color(model.account(item.accountID)?.colorIndex ?? 0))
                                    .background(OrbitaStyle.color(model.account(item.accountID)?.colorIndex ?? 0).opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain).help(item.title + " · " + (model.account(item.accountID)?.email ?? ""))
                        }
                    }.padding(4).frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
                }
            }
            Divider()
            ScrollViewReader { scroll in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Text(String(format: "%02d", hour)).font(.system(size: 9)).foregroundStyle(.secondary)
                                    .frame(width: 40, height: hourHeight, alignment: .top).id("hour-\(hour)")
                            }
                        }
                        ForEach(days, id: \.self) { date in
                            CalendarDayColumn(day: date, hourHeight: hourHeight, showAccount: days.count == 1)
                                .frame(height: hourHeight * 24).frame(maxWidth: .infinity)
                                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.13)).frame(width: 0.5) }
                        }
                    }.padding(.top, 6)
                }.task(id: days.first) {
                    // Wait for the first layout pass before applying a reader position.
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    scroll.scrollTo("hour-7", anchor: .top)
                }
            }
        }
    }
    private func datedItems(_ date: Date) -> [AgendaItem] {
        let interval = Calendar.current.dateInterval(of: .day, for: date)!
        return model.visibleAgenda.filter { $0.day != nil && !$0.isCompleted && $0.overlaps(interval) }
    }
}

struct CalendarDayColumn: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let hourHeight: CGFloat
    let showAccount: Bool
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle().fill(Color.secondary.opacity(0.13)).frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                }.frame(height: hourHeight * 24)
                ForEach(AgendaLayout.placements(model.visibleAgenda, day: day)) { placement in
                    TimedEventButton(placement: placement, columnWidth: geometry.size.width / CGFloat(max(1, placement.columns)), hourHeight: hourHeight, showAccount: showAccount)
                }
            }
        }
    }
}

struct TimedEventButton: View {
    @EnvironmentObject private var model: AppModel
    let placement: TimedPlacement
    let columnWidth: CGFloat
    let hourHeight: CGFloat
    let showAccount: Bool
    private var color: Color { OrbitaStyle.color(model.account(placement.item.accountID)?.colorIndex ?? 0) }
    private var label: String { placement.item.title + " · " + (model.account(placement.item.accountID)?.email ?? "") }
    var body: some View {
        Button { model.selectedAgendaID = placement.item.id } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(placement.item.title).font(.system(size: 11, weight: .medium)).lineLimit(3)
                if let start = placement.item.start { Text(start, format: .dateTime.hour().minute()).font(.system(size: 9)) }
                if showAccount { AccountBadge(accountID: placement.item.accountID) }
            }.padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .foregroundStyle(color)
                .background(color.opacity(placement.item.id == model.selectedAgendaID ? 0.24 : 0.12), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(color.opacity(0.4), lineWidth: 0.5))
        }.buttonStyle(.plain)
            .frame(width: max(22, columnWidth - 4), height: max(28, CGFloat(placement.endMinute - placement.startMinute) / 60 * hourHeight - 2))
            .offset(x: CGFloat(placement.column) * columnWidth + 2, y: CGFloat(placement.startMinute) / 60 * hourHeight)
            .help(label).accessibilityLabel(label)
    }
}

struct AgendaDetail: View {
    @EnvironmentObject private var model: AppModel
    let item: AgendaItem
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Label(item.kind == .event ? "Compromisso" : "Tarefa", systemImage: item.kind == .event ? "calendar" : "checklist").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.selectedAgendaID = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Fechar detalhes")
                }
                Text(item.title).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
                AccountBadge(accountID: item.accountID)
                Text(item.sourceName).font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                if let day = item.day, let date = Time.dayDate(day) {
                    Label(date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                    Text(item.kind == .task ? "Data da tarefa · sem horário sincronizado" : "Evento de dia inteiro").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let date = item.start {
                    Label(date.formatted(date: .long, time: .omitted), systemImage: "calendar")
                    Label(date.formatted(date: .omitted, time: .shortened) + (item.end.map { " – " + $0.formatted(date: .omitted, time: .shortened) } ?? ""), systemImage: "clock")
                } else { Label("Sem data", systemImage: "calendar.badge.questionmark") }
                if !item.location.isEmpty { Label(item.location, systemImage: "mappin.and.ellipse") }
                if !item.responseLabel.isEmpty { Label(item.responseLabel, systemImage: "person.crop.circle.badge.checkmark") }
                if AgendaLayout.conflicts(item, among: model.visibleAgenda) {
                    Label("Há outro compromisso neste horário", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let url = URL(string: item.meetingURL), ["https", "http"].contains(url.scheme) {
                    Button { NSWorkspace.shared.open(url) } label: { Label("Entrar na reunião", systemImage: "video") }.buttonStyle(.borderedProminent)
                }
                if item.kind == .task {
                    Button(item.isCompleted ? "Reabrir tarefa" : "Concluir tarefa") { Task { await model.complete(item) } }
                        .buttonStyle(.borderedProminent).disabled(!item.canEdit || model.operations.contains(item.id))
                }
                if item.canRespond {
                    Divider()
                    Text(model.operations.contains(item.id) ? "Confirmando resposta…" : "Responder ao convite").font(.system(size: 13, weight: .semibold))
                    ForEach(InvitationResponse.allCases) { response in
                        Button(response.title) { Task { await model.respond(item, response: response) } }
                            .frame(maxWidth: .infinity).buttonStyle(.bordered)
                            .disabled(model.operations.contains(item.id) || model.unresolvedResponses.contains(item.id))
                    }
                    Text(model.isDemo ? "A resposta será simulada apenas nestes dados fictícios." : "Sua resposta será enviada ao organizador por \(model.account(item.accountID)?.email ?? "esta conta").")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if model.unresolvedResponses.contains(item.id) {
                        Text("Resposta ainda não confirmada. Atualize a agenda para conferir o estado remoto.").font(.system(size: 11)).foregroundStyle(.orange)
                        Button("Atualizar agenda") { Task { await model.refreshAgenda() } }.disabled(model.isRefreshingAgenda)
                    }
                }
                if !item.canEdit { Label("Somente leitura", systemImage: "lock").foregroundStyle(.secondary) }
                Spacer()
            }.font(.system(size: 12)).padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    let item: AgendaItem
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button { Task { await model.complete(item) } } label: {
                Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle").font(.system(size: 17))
            }.buttonStyle(.plain).foregroundStyle(item.isCompleted ? OrbitaStyle.accent : Color.secondary)
                .disabled(!item.canEdit || model.operations.contains(item.id)).accessibilityLabel((item.isCompleted ? "Reabrir " : "Concluir ") + item.title)
            Button { model.selectedAgendaID = item.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.system(size: 12)).strikethrough(item.isCompleted).multilineTextAlignment(.leading)
                    AccountBadge(accountID: item.accountID, compact: true)
                    if let date = item.displayDate { Text(date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 10)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
        }
    }
}

struct AgendaListRow: View {
    @EnvironmentObject private var model: AppModel
    let item: AgendaItem
    var body: some View {
        if item.kind == .task { TaskRow(item: item) }
        else {
            Button { model.selectedAgendaID = item.id } label: {
                HStack(alignment: .top, spacing: 15) {
                    Text(item.start.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Dia todo").font(.system(size: 12)).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(.system(size: 13, weight: .medium))
                        AccountBadge(accountID: item.accountID)
                    }
                    Spacer()
                    Text(item.responseLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
}

struct TasksWorkspace: View {
    @EnvironmentObject private var model: AppModel
    @State private var completed = false
    @State private var search = ""
    private var items: [AgendaItem] {
        model.visibleAgenda.filter { $0.kind == .task && (completed || !$0.isCompleted) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
            .sorted { ($0.day ?? "9999", $0.title) < ($1.day ?? "9999", $1.title) }
    }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Suas tarefas, juntas").font(.system(size: 24, weight: .semibold))
                        Text("\(items.count) tarefas · todas as listas selecionadas").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Mostrar concluídas", isOn: $completed).font(.system(size: 12))
                }.padding(24)
                TextField("Buscar tarefas carregadas", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 24).padding(.bottom, 16)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { item in TaskRow(item: item).padding(.vertical, 16); Divider() }
                        if items.isEmpty { ContentUnavailableView("Nenhuma tarefa carregada", systemImage: "checklist", description: Text("Confira as listas habilitadas e as permissões das contas.")) }
                    }.padding(.horizontal, 24)
                }
            }.frame(minWidth: 450, maxWidth: .infinity)
            if let item = model.selectedAgenda { AgendaDetail(item: item).frame(minWidth: 260, idealWidth: 300, maxWidth: 340) }
        }.background(Color(nsColor: .textBackgroundColor))
    }
}
