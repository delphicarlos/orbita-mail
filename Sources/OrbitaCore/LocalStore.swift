import Foundation
import CSQLite

public actor LocalStore {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw OrbitaError.storage("Não foi possível abrir o armazenamento local.")
        }
        sqlite3_busy_timeout(database, 5_000)
        let schema = """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS objects (
                key TEXT PRIMARY KEY, bucket TEXT NOT NULL, account TEXT NOT NULL,
                source TEXT NOT NULL, payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS object_scope ON objects(bucket, account, source);
            """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(database); throw OrbitaError.storage("Não foi possível preparar o armazenamento local.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    deinit { sqlite3_close(database) }

    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &result, nil) == SQLITE_OK, let result else {
            throw OrbitaError.storage("Falha ao consultar o armazenamento local.")
        }
        for (offset, value) in values.enumerated() {
            guard sqlite3_bind_text(result, Int32(offset + 1), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(result); throw OrbitaError.storage("Falha ao preparar os dados locais.")
            }
        }
        return result
    }

    private func execute(_ sql: String, _ values: [String] = []) throws {
        let query = try statement(sql, values); defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_DONE else { throw OrbitaError.storage("Falha ao salvar os dados locais.") }
    }

    public func put<T: Encodable>(_ value: T, id: String, bucket: String, account: String = "", source: String = "") throws {
        let data = try encoder.encode(value)
        let query = try statement("INSERT OR REPLACE INTO objects(key,bucket,account,source,payload) VALUES(?,?,?,?,?)",
                                  [scopedID(bucket, account, source, id), bucket, account, source])
        defer { sqlite3_finalize(query) }
        let result = data.withUnsafeBytes { sqlite3_bind_blob(query, 5, $0.baseAddress, Int32(data.count), transient) }
        guard result == SQLITE_OK, sqlite3_step(query) == SQLITE_DONE else {
            throw OrbitaError.storage("Não foi possível salvar o item localmente.")
        }
    }

    public func values<T: Decodable>(_ type: T.Type, bucket: String, account: String? = nil, source: String? = nil) throws -> [T] {
        var sql = "SELECT payload FROM objects WHERE bucket=?"
        var bindings = [bucket]
        if let account { sql += " AND account=?"; bindings.append(account) }
        if let source { sql += " AND source=?"; bindings.append(source) }
        let query = try statement(sql, bindings); defer { sqlite3_finalize(query) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(query)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else {
                throw OrbitaError.storage("Não foi possível ler um item do cache.")
            }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
            result.append(try decoder.decode(type, from: data))
        }
        return result
    }

    public func remove(id: String, bucket: String, account: String = "", source: String = "") throws {
        try execute("DELETE FROM objects WHERE key=?", [scopedID(bucket, account, source, id)])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    public func saveMail(_ messages: [MailMessage], account: String, folder: String, replace: Bool) throws {
        try transaction {
            if replace { try execute("DELETE FROM objects WHERE bucket='mail' AND account=? AND source=?", [account, folder]) }
            for message in messages {
                guard message.accountID == account else { throw OrbitaError.invalidData("Conta da mensagem inconsistente.") }
                try put(message, id: message.remoteID, bucket: "mail", account: account, source: folder)
            }
        }
    }

    public func replaceMailboxes(_ folders: [MailboxFolder], account: String) throws {
        guard folders.allSatisfy({ $0.accountID == account }) else { throw OrbitaError.invalidData("Conta da pasta inconsistente.") }
        try transaction {
            try execute("DELETE FROM objects WHERE bucket='mailbox' AND account=?", [account])
            for folder in folders { try put(folder, id: folder.remoteID, bucket: "mailbox", account: account) }
        }
    }

    public func replaceSources(_ sources: [AgendaSource], account: String, kind: AgendaKind) throws {
        guard sources.allSatisfy({ $0.accountID == account && $0.kind == kind }) else {
            throw OrbitaError.invalidData("Conta ou tipo de fonte inconsistente.")
        }
        let previous = try values(AgendaSource.self, bucket: "source", account: account).filter { $0.kind == kind }
        let retained = Set(sources.map(\.id))
        try transaction {
            for source in previous where !retained.contains(source.id) {
                try remove(id: source.id, bucket: "source", account: account)
                try execute("DELETE FROM objects WHERE bucket=? AND account=? AND source=?", [kind.rawValue, account, source.remoteID])
            }
            for source in sources { try put(source, id: source.id, bucket: "source", account: account) }
        }
    }

    public func replaceAgenda(_ items: [AgendaItem], source: AgendaSource, interval: DateInterval?) throws {
        guard items.allSatisfy({ $0.accountID == source.accountID && $0.sourceID == source.remoteID && $0.kind == source.kind }) else {
            throw OrbitaError.invalidData("Origem dos itens da agenda inconsistente.")
        }
        let previous = try values(AgendaItem.self, bucket: source.kind.rawValue, account: source.accountID, source: source.remoteID)
        try transaction {
            for old in previous where interval == nil || old.overlaps(interval!) {
                try remove(id: old.remoteID, bucket: source.kind.rawValue, account: source.accountID, source: source.remoteID)
            }
            for item in items { try put(item, id: item.remoteID, bucket: source.kind.rawValue, account: source.accountID, source: source.remoteID) }
        }
    }

    public func removeAccount(_ accountID: String) throws {
        try execute("DELETE FROM objects WHERE account=?", [accountID])
        try remove(id: accountID, bucket: "account")
    }
    public func saveImportedSettings(accounts: [ImportedAccount], presets: [WritingPreset]) throws {
        let manifest = try OutlookImportManifest(accounts: accounts, presets: presets).validated()
        try transaction {
            for account in manifest.accounts { try put(account, id: account.id, bucket: "imported-account") }
            for preset in manifest.presets { try put(preset, id: preset.id, bucket: "writing-preset") }
        }
    }
}
