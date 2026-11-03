import Foundation

enum IMAPReply {
    struct Fetch: Sendable { var uid: UInt32; var flags: String; var date: Date?; var literal: Data }
    static func firstMatch(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: group), in: text) else { return nil }
        return String(text[range])
    }
    static func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    static func validity(_ data: Data) throws -> UInt32 {
        guard let value = firstMatch(#"\bUIDVALIDITY\s+(\d+)"#, String(decoding: data, as: UTF8.self)), let number = UInt32(value), number > 0 else { throw OrbitaError.invalidData("O IMAP não confirmou UIDVALIDITY. A caixa não foi atualizada.") }
        return number
    }
    static func search(_ data: Data) -> [UInt32] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter { $0.uppercased().hasPrefix("* SEARCH") }
            .flatMap { $0.split(whereSeparator: { $0.isWhitespace }).dropFirst(2).compactMap { UInt32($0) } }
    }
    static func fetches(_ data: Data) throws -> [Fetch] {
        var cursor = data.startIndex, metadata = "", literal = Data(), result: [Fetch] = []
        func flush() throws {
            guard !metadata.isEmpty else { return }
            guard let text = firstMatch(#"\bUID\s+(\d+)"#, metadata), let uid = UInt32(text), uid > 0 else { throw OrbitaError.invalidData("Resposta FETCH sem UID válido.") }
            result.append(Fetch(uid: uid, flags: firstMatch(#"FLAGS\s*\(([^)]*)\)"#, metadata) ?? "",
                                date: firstMatch(#"INTERNALDATE\s+"([^"]+)""#, metadata).flatMap(InternetMessage.date), literal: literal))
        }
        while cursor < data.endIndex {
            let newline = data[cursor...].firstIndex(of: 10)
            let end = newline.map { $0 + 1 } ?? data.endIndex
            let line = String(decoding: data[cursor..<end], as: UTF8.self).trimmingCharacters(in: .newlines)
            cursor = end
            if firstMatch(#"^\*\s+\d+\s+(FETCH)\s*\("#, line) != nil {
                if !metadata.isEmpty { try flush() }
                metadata = line; literal = Data()
            } else if !metadata.isEmpty { metadata += " " + line }
            else { continue }
            if let size = firstMatch(#"\{(\d+)\+?\}$"#, line) {
                guard let count = Int(size) else { throw OrbitaError.invalidData("Tamanho de literal IMAP inválido.") }
                guard count <= 32_000_000, count <= data.endIndex - cursor else { throw OrbitaError.invalidData("Literal IMAP truncado ou maior que o limite.") }
                literal.append(data[cursor..<cursor + count]); cursor += count
            } else if line.hasSuffix(")") { try flush(); metadata = ""; literal = Data() }
        }
        if !metadata.isEmpty { try flush() }
        return result
    }
    static func folderNames(_ data: Data) -> [(String, String)] {
        String(decoding: data, as: UTF8.self).components(separatedBy: "\n").compactMap { line in
            guard let flags = firstMatch(#"^\*\s+LIST\s+\(([^)]*)\)"#, line),
                  let name = firstMatch(#"^\*\s+LIST\s+\([^)]*\)\s+(?:"(?:[^"\\]|\\.)*"|NIL)\s+(.+?)\r?$"#, line) else { return nil }
            let raw = name.hasPrefix("\"") && name.hasSuffix("\"") ? String(name.dropFirst().dropLast()).replacingOccurrences(of: #"\(.)"#, with: "$1", options: .regularExpression) : name
            guard !raw.hasPrefix("{"), !flags.lowercased().contains("\\noselect") else { return nil }
            return (decodeMailbox(raw), flags.lowercased())
        }
    }
    static func encodeMailbox(_ value: String) -> String {
        var result = "", run = ""
        func flush() {
            if !run.isEmpty { result += "&" + run.data(using: .utf16BigEndian)!.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "") + "-"; run = "" }
        }
        for scalar in value.unicodeScalars {
            if (0x20...0x7e).contains(scalar.value) { flush(); result += scalar == "&" ? "&-" : String(scalar) }
            else { run += String(scalar) }
        }
        flush(); return result
    }
    static func decodeMailbox(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&([A-Za-z0-9+,]*)-"#) else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            let encoded = (value as NSString).substring(with: match.range(at: 1)).replacingOccurrences(of: ",", with: "/")
            let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
            let decoded = encoded.isEmpty ? "&" : Data(base64Encoded: padded).flatMap { String(data: $0, encoding: .utf16BigEndian) }
            if let decoded, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decoded) }
        }
        return result
    }
}

struct IMAPIdentity: Codable, Sendable {
    var folder: String
    var validity: UInt32
    var uid: UInt32
    var encoded: String { try! JSONEncoder().encode(self).base64URL }
    static func parse(_ string: String) throws -> Self {
        guard let data = Data(base64URL: string), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.validity > 0, value.uid > 0, !value.folder.isEmpty, value.folder.utf8.count <= 500,
              !MailServerConfiguration.hasControls(value.folder) else { throw OrbitaError.invalidData("Identificador IMAP inválido. Atualize a caixa.") }
        return value
    }
}
