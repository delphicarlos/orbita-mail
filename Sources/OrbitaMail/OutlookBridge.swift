import AppKit
import OrbitaCore

@MainActor
enum OutlookBridge {
    static func read(includeSignatures: Bool) throws -> OutlookImportManifest {
        // Fixed, read-only script. Never request `properties`, passwords, tokens or mailbox content.
        let signatureRead = includeSignatures ? """
            try
                repeat with s in signatures
                    set end of signatureRows to {(name of s as text), (plain text content of s as text)}
                end repeat
            on error
                set end of warningRows to "O Outlook não disponibilizou as assinaturas pela automação."
            end try
        """ : ""
        let source = """
        with timeout of 15 seconds
            tell application id "com.microsoft.Outlook"
                set accountRows to {}
                set signatureRows to {}
                set warningRows to {}
                try
                    repeat with a in exchange accounts
                        set end of accountRows to {"Exchange", (email address of a as text), (name of a as text), ""}
                    end repeat
                on error
                    set end of warningRows to "Contas Exchange não foram disponibilizadas pela automação."
                end try
                try
                    repeat with a in imap accounts
                        set end of accountRows to {"IMAP", (email address of a as text), (name of a as text), (server of a as text)}
                    end repeat
                on error
                    set end of warningRows to "Contas IMAP não foram disponibilizadas pela automação."
                end try
                try
                    repeat with a in pop accounts
                        set end of accountRows to {"POP", (email address of a as text), (name of a as text), (server of a as text)}
                    end repeat
                on error
                    set end of warningRows to "Contas POP não foram disponibilizadas pela automação."
                end try
                \(signatureRead)
                return {accountRows, signatureRows, warningRows}
            end tell
        end timeout
        """
        guard let script = NSAppleScript(source: source) else { throw OrbitaError.invalidData("Não foi possível preparar a leitura do Outlook.") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -1743 {
                throw OrbitaError.invalidData("O macOS não autorizou o Órbita a ler o Outlook pela automação. Você pode permitir esse acesso em Privacidade e Segurança → Automação ou importar um arquivo JSON.")
            }
            throw OrbitaError.invalidData("O Outlook não respondeu à leitura de configurações (código \(code)). Nenhuma senha foi acessada. Você pode importar um arquivo JSON.")
        }
        var accounts: [ImportedAccount] = [], presets: [WritingPreset] = [], warnings: [String] = []
        if let rows = result.atIndex(1), rows.numberOfItems > 0 {
            for index in 1...rows.numberOfItems {
                guard let row = rows.atIndex(index), let email = row.atIndex(2)?.stringValue else { continue }
                accounts.append(.outlook(kind: row.atIndex(1)?.stringValue ?? "", email: email,
                                         name: row.atIndex(3)?.stringValue ?? email, server: row.atIndex(4)?.stringValue ?? ""))
            }
        }
        if let rows = result.atIndex(2), rows.numberOfItems > 0 {
            for index in 1...rows.numberOfItems {
                guard let row = rows.atIndex(index), let name = row.atIndex(1)?.stringValue, let text = row.atIndex(2)?.stringValue else { continue }
                presets.append(WritingPreset(name: name, text: text, kind: .signature))
            }
        }
        if let rows = result.atIndex(3), rows.numberOfItems > 0 {
            for index in 1...rows.numberOfItems { if let warning = rows.atIndex(index)?.stringValue { warnings.append(warning) } }
        }
        return try OutlookImportManifest(accounts: accounts, presets: presets, warnings: warnings).validated()
    }
}
