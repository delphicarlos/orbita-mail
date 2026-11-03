import SwiftUI
import AppKit
import OrbitaCore
import Darwin
import Combine

@main
struct OrbitaApplication: App {
    @StateObject private var model = AppModel()
    init() {
        umask(0o077)
        NSApplication.shared.setActivationPolicy(.regular)
    }
    var body: some Scene {
        WindowGroup("Órbita") {
            RootView().environmentObject(model)
                .frame(minWidth: 1080, minHeight: 700)
                .tint(OrbitaStyle.accent)
                .environment(\.locale, Locale(identifier: "pt_BR"))
                .task { if !model.ready { await model.bootstrap(demo: CommandLine.arguments.contains("--demo")) } }
        }
        .defaultSize(width: 1380, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Novo email") { model.newDraft() }.keyboardShortcut("n", modifiers: .command).disabled(model.accounts.isEmpty)
            }
            CommandMenu("Contas") {
                Button("Configurações de email…") { model.openMailOrganization() }
                Button("Gerenciar contas…") { model.showAccounts = true }.keyboardShortcut(",", modifiers: .command)
                Button("Explorar demonstração") { Task { await model.bootstrap(demo: true) } }.disabled(model.busy || model.isDemo || model.composeDraft != nil)
                Button("Sincronizar") { model.refreshAll() }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.busy || model.isDemo)
            }
        }
    }
}

enum OrbitaStyle {
    static let accent = adaptive(light: (0.52, 0.15, 0), dark: (0.78, 0.13, 0))
    static let accountColors: [Color] = [accent, adaptive(light: (0.47, 0.10, 245), dark: (0.78, 0.10, 245)),
                                        adaptive(light: (0.46, 0.10, 150), dark: (0.78, 0.10, 150)), .orange, .purple]
    static func color(_ index: Int) -> Color { accountColors[abs(index) % accountColors.count] }
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let a = value.1 * cos(value.2 * .pi / 180), b = value.1 * sin(value.2 * .pi / 180)
            let l = pow(value.0 + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(value.0 - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(value.0 - 0.0894841775 * a - 1.2914855480 * b, 3)
            func gamma(_ x: Double) -> Double { min(1, max(0, x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055)) }
            return NSColor(srgbRed: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                           green: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                           blue: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s), alpha: 1)
        })
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showHealth = false
    private let refresh = Timer.publish(every: 120, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            if model.isDemo {
                HStack(spacing: 8) {
                    Image(systemName: "testtube.2")
                    Text("Demonstração — dados fictícios").fontWeight(.semibold)
                    Text("Nenhum email ou convite real será enviado.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Usar contas reais") { Task { await model.bootstrap() } }.disabled(model.busy)
                }.font(.system(size: 12)).padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Color.orange.opacity(0.12))
                Divider()
            }
            HSplitView {
                SidebarView().frame(minWidth: 210, idealWidth: 225, maxWidth: 270)
                Group {
                    if !model.ready { ProgressView("Abrindo seus dados locais…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if model.accounts.isEmpty { WelcomeView() }
                    else {
                        switch model.workspace {
                        case .mail: MailWorkspace()
                        case .calendar: CalendarWorkspace()
                        case .tasks: TasksWorkspace()
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice = model.notice {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.noticeIsError ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(model.noticeIsError ? Color.orange : Color.secondary)
                    Text(notice).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Fechar aviso")
                }.font(.system(size: 12)).padding(12).background(.bar)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { Text(model.workspace.title).font(.headline) }
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRefreshingMail || model.isRefreshingAgenda || model.isRefreshingMailboxes { ProgressView().controlSize(.small) }
                Button { showHealth.toggle() } label: {
                    Label("Fontes e sincronização", systemImage: model.health.values.contains(where: { $0.state == "error" }) ? "exclamationmark.icloud" : "icloud")
                }.popover(isPresented: $showHealth) { HealthView().environmentObject(model) }
                Button { model.refreshAll() } label: { Label("Sincronizar", systemImage: "arrow.triangle.2.circlepath") }.disabled(model.busy || model.isDemo)
                Button { model.newDraft() } label: { Label("Novo email", systemImage: "square.and.pencil") }.disabled(model.accounts.isEmpty || model.isSending)
                Button { model.openMailOrganization() } label: { Label("Configurações de email", systemImage: "gearshape") }.disabled(model.accounts.isEmpty)
                Button { model.showAccounts = true } label: { Label("Contas", systemImage: "person.crop.circle.badge.plus") }
            }
        }
        .sheet(isPresented: $model.showAccounts) { AccountsView().environmentObject(model) }
        .sheet(isPresented: $model.showMailOrganization) { MailOrganizationView(initialAccountID: model.organizationAccountID).environmentObject(model) }
        .sheet(item: $model.composeDraft) { draft in ComposerView(initial: draft).environmentObject(model) }
        .onChange(of: model.anchor) { _, _ in
            Task { await model.refreshAgenda() }
        }
        .onReceive(refresh) { _ in if !model.busy && NSApp.isActive { model.refreshAll() } }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCustomFolders = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 27)).foregroundStyle(OrbitaStyle.accent)
                VStack(alignment: .leading, spacing: 1) { Text("Órbita").font(.system(size: 24, weight: .semibold)); Text("Seu dia, em conjunto").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 25)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Workspace.allCases) { item in
                        navRow(item.title, symbol: item.symbol, selected: model.workspace == item) {
                            model.workspace = item; model.selectedAgendaID = nil
                        }
                    }
                    if model.workspace == .mail {
                        Divider().padding(.vertical, 10)
                        ForEach(MailFolder.allCases) { folder in
                            navRow(folder.title, symbol: folder.symbol, selected: model.selectedMailbox == nil && model.folder == folder, badge: model.unreadSummary(folder).text, badgeHelp: model.unreadSummary(folder).help) {
                                Task { await model.setFolder(folder) }
                            }
                        }
                        Button { model.openMailOrganization() } label: { Label("Nova pasta…", systemImage: "folder.badge.plus").font(.system(size: 12)) }
                            .buttonStyle(.plain).foregroundStyle(OrbitaStyle.accent).padding(10)
                        if !model.customMailboxes.isEmpty {
                            DisclosureGroup("Pastas personalizadas (\(model.customMailboxes.count))", isExpanded: $showCustomFolders) {
                                ForEach(model.customMailboxes) { box in
                                    navRow(box.name, symbol: "folder", selected: model.selectedMailbox?.id == box.id, badge: box.unreadCount.map { $0.formatted(.number.locale(Locale(identifier: "pt_BR"))) } ?? "—", badgeHelp: "\(model.account(box.accountID)?.email ?? "") · última consulta: \(box.updatedAt.formatted(date: .abbreviated, time: .shortened))") {
                                        Task { await model.selectMailbox(box) }
                                    }
                                    if model.accountFilter == nil { Text(model.account(box.accountID)?.email ?? "").font(.system(size: 9)).foregroundStyle(.secondary).padding(.leading, 40) }
                                }
                            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
                        }
                        if !model.drafts.isEmpty {
                            Menu {
                                ForEach(model.drafts) { draft in
                                    Button(draft.subject.isEmpty ? "Sem assunto" : draft.subject) { model.composeDraft = draft }
                                }
                            } label: { Label("Rascunhos neste Mac (\(model.drafts.count))", systemImage: "internaldrive").font(.system(size: 12)) }
                            .menuStyle(.borderlessButton).padding(.horizontal, 10).padding(.vertical, 8)
                        }
                    }
                    Divider().padding(.vertical, 12)
                    Text("Contas").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
                    navRow("Todas as contas", symbol: "circle.grid.2x2", selected: model.accountFilter == nil, badge: model.unreadSummary(.inbox, allAccounts: true).text, badgeHelp: "Entrada · " + model.unreadSummary(.inbox, allAccounts: true).help) { selectAccount(nil) }
                    ForEach(model.accounts) { account in
                        Button { selectAccount(account.id) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(OrbitaStyle.color(account.colorIndex)).frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                                    Text(account.email).lineLimit(1).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Text(model.unreadSummary(.inbox, accountID: account.id).text).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .help("Entrada · " + model.unreadSummary(.inbox, accountID: account.id).help)
                            }.padding(.horizontal, 10).padding(.vertical, 9).contentShape(Rectangle())
                                .background(model.accountFilter == account.id ? OrbitaStyle.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain).help(account.email)
                    }
                    Button { model.showAccounts = true } label: { Label("Adicionar conta", systemImage: "plus").font(.system(size: 12)) }
                        .buttonStyle(.plain).foregroundStyle(OrbitaStyle.accent).padding(12)
                    if model.workspace != .mail && !model.sources.isEmpty {
                        Divider().padding(.vertical, 12)
                        Text("Calendários e listas").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
                        ForEach(model.sources.filter { model.accountFilter == nil || $0.accountID == model.accountFilter }) { source in
                            Toggle(isOn: Binding(get: { !model.hiddenSources.contains(source.id) }, set: { _ in Task { await model.toggleSource(source) } })) {
                                HStack(spacing: 6) {
                                    Image(systemName: source.kind == .event ? "calendar" : "checklist")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(source.name).lineLimit(1)
                                        Text(model.account(source.accountID)?.name ?? "").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }.font(.system(size: 11))
                            }.toggleStyle(.checkbox).padding(.horizontal, 12).padding(.vertical, 3)
                        }
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(model.isDemo ? "Ambiente de demonstração" : "Dados neste Mac").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(16)
        }.background(Color(nsColor: .windowBackgroundColor))
    }
    private func selectAccount(_ id: String?) {
        model.accountFilter = id; model.selectedMessageID = nil; model.body = nil; model.selectedAgendaID = nil
        if model.selectedMailbox != nil { Task { await model.setFolder(.inbox) } }
    }
    private func navRow(_ title: String, symbol: String, selected: Bool, badge: String? = nil, badgeHelp: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer()
                if let badge, !badge.isEmpty { Text(badge).font(.system(size: 11, weight: .semibold, design: .monospaced)).help(badgeHelp ?? "Não lidos") }
            }.padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                .foregroundStyle(selected ? OrbitaStyle.accent : Color.primary)
                .background(selected ? OrbitaStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "envelope.open").font(.system(size: 45, weight: .light)).foregroundStyle(OrbitaStyle.accent)
            Text("Suas contas.\nUm lugar para o seu dia.").font(.system(size: 34, weight: .semibold))
            Text("Reúna emails, convites, compromissos e tarefas.\nCada conta mantém sua identidade e suas permissões.")
                .font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
            HStack(spacing: 12) {
                Button("Conectar minhas contas") { model.showAccounts = true }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Explorar demonstração") { Task { await model.bootstrap(demo: true) } }.controlSize(.large)
            }
            Text("Microsoft 365 e Google · Armazenamento local · Credenciais no Keychain")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(55).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

struct HealthView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fontes e sincronização").font(.headline)
            Text(model.isDemo ? "Dados fictícios; nenhum provedor conectado." : "Eventos são consultados pelo período da agenda. Email é carregado em páginas; tarefas incluem todas as listas autorizadas.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if model.health.isEmpty { Text("Conecte uma conta para começar.").foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.health.values.sorted { $0.accountID + $0.title < $1.accountID + $1.title }) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: item.state == "error" ? "exclamationmark.triangle" : item.state == "ok" || item.state == "demo" ? "checkmark.circle" : item.state == "unavailable" || item.state == "local" ? "info.circle" : "clock")
                                .foregroundStyle(item.state == "error" ? Color.orange : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).fontWeight(.medium)
                                Text(model.account(item.accountID)?.email ?? item.accountID).foregroundStyle(.secondary)
                                Text(item.detail).foregroundStyle(item.state == "error" ? Color.orange : Color.secondary)
                                if let date = item.date { Text(date.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary) }
                            }.font(.system(size: 12))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.frame(maxHeight: 430)
        }.padding(20).frame(width: 430)
    }
}

struct AccountBadge: View {
    @EnvironmentObject private var model: AppModel
    let accountID: String
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(OrbitaStyle.color(model.account(accountID)?.colorIndex ?? 0)).frame(width: 6, height: 6)
            Text(compact ? (model.account(accountID)?.name ?? "Conta") : (model.account(accountID)?.email ?? "Conta"))
                .lineLimit(1).font(.system(size: compact ? 10 : 11))
        }.foregroundStyle(.secondary).help(model.account(accountID)?.email ?? "")
    }
}
