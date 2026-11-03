import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OrbitaCore

struct ImportSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var manifest: OutlookImportManifest?
    @State private var selectedEmails = Set<String>()
    @State private var selectedPresetIDs = Set<String>()
    @State private var signatures = false
    @State private var reading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Importar do Outlook").font(.system(size: 22, weight: .semibold))
                    Text("Contas, assinaturas e modelos para conferir antes de usar.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fechar") { dismiss() }.disabled(reading)
            }
            Text("A importação traz os endereços e nomes das contas. Cada conta precisa ser autorizada pelo OAuth do Órbita. Senhas, tokens e mensagens do Outlook não são copiados.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(reading ? "Lendo Outlook…" : "Ler contas do Outlook") {
                    reading = true; error = nil
                    Task { @MainActor in
                        await Task.yield()
                        do { load(try OutlookBridge.read(includeSignatures: signatures)) }
                        catch { self.error = error.localizedDescription }
                        reading = false
                    }
                }.disabled(reading)
                Button("Importar arquivo JSON…") { chooseFile() }.disabled(reading)
            }
            Toggle("Incluir assinaturas disponíveis no Outlook, em texto simples", isOn: $signatures).font(.system(size: 12)).disabled(reading)
            Text("O macOS pode pedir autorização para o Órbita ler o Outlook. A disponibilidade depende da versão do Outlook. Modelos podem ser trazidos pelo arquivo JSON; não há detecção automática de modelos em nuvem.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let manifest {
                        if !manifest.accounts.isEmpty { Text("Contas encontradas").font(.headline) }
                        ForEach(manifest.accounts) { account in
                            Toggle(isOn: Binding(get: { selectedEmails.contains(account.id) }, set: { if $0 { selectedEmails.insert(account.id) } else { selectedEmails.remove(account.id) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.email).font(.system(size: 13, weight: .medium))
                                    Text((account.provider?.title ?? "Provedor a identificar") + " · " + account.sourceKind).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                        if !manifest.presets.isEmpty { Text("Assinaturas e modelos").font(.headline).padding(.top, 8) }
                        ForEach(manifest.presets) { preset in
                            Toggle(isOn: Binding(get: { selectedPresetIDs.contains(preset.id) }, set: { if $0 { selectedPresetIDs.insert(preset.id) } else { selectedPresetIDs.remove(preset.id) } })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(preset.name + " · " + (preset.kind == .signature ? "Assinatura" : "Modelo")).font(.system(size: 12, weight: .medium))
                                    Text(preset.text).lineLimit(4).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                        ForEach(manifest.warnings, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange) }
                    } else {
                        ContentUnavailableView("Escolha a origem da importação", systemImage: "square.and.arrow.down", description: Text("As configurações encontradas aparecerão aqui para seleção."))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            Divider()
            HStack {
                Text("A importação não concede acesso às contas.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Importar selecionados") {
                    guard let manifest else { return }
                    Task { if await model.importSettings(manifest, selectedEmails: selectedEmails, selectedPresetIDs: selectedPresetIDs) { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(manifest == nil || (selectedEmails.isEmpty && selectedPresetIDs.isEmpty) || reading)
            }
        }.padding(24).frame(width: 720, height: 650)
    }

    private func load(_ value: OutlookImportManifest) {
        manifest = value; selectedEmails = Set(value.accounts.map(\.id)); selectedPresetIDs = []
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw OrbitaError.invalidData("O arquivo pode ter até 2 MB.") }
            load(try OutlookImportManifest.parse(Data(contentsOf: url))); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
