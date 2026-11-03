import Foundation
import CoreFoundation

public struct InternetAttachment: Sendable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var data: Data
}
public struct InternetMessage: Sendable {
    public var headers: [String: String]
    public var text = ""
    public var html = ""
    public var attachments: [InternetAttachment] = []
    public var mailBody: MailBody {
        MailBody(text: text, html: html, attachments: attachments.map { MailAttachment(id: $0.id, name: $0.name, mimeType: $0.mimeType, size: $0.data.count) })
    }
    public static func parse(_ data: Data) throws -> Self {
        guard data.count <= 32_000_000 else { throw OrbitaError.invalidData("Mensagem maior que 32 MB.") }
        let (headers, body) = split(data)
        var result = InternetMessage(headers: headers)
        var partCount = 0
        try result.readPart(headers: headers, body: body, path: "1", depth: 0, partCount: &partCount)
        return result
    }
    static func split(_ data: Data) -> ([String: String], Data) {
        let boundary = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8))
        let headerData = boundary.map { data.subdata(in: data.startIndex..<$0.lowerBound) } ?? data
        let text = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .isoLatin1) ?? ""
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
            else { lines.append(line) }
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let previous = headers[name], ["to", "cc"].contains(name) { headers[name] = previous + ", " + value }
            else if headers[name] == nil { headers[name] = value }
        }
        return (headers, boundary.map { data.subdata(in: $0.upperBound..<data.endIndex) } ?? Data())
    }
    public static func decodedHeader(_ text: String) -> String {
        let source = text.replacingOccurrences(of: #"(?<=\?=)\s+(?==\?)"#, with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return text }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let s = source as NSString
            let charset = s.substring(with: match.range(at: 1)), method = s.substring(with: match.range(at: 2)).lowercased()
            let payload = s.substring(with: match.range(at: 3))
            let bytes = method == "b" ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters) : quotedPrintable(Data(payload.replacingOccurrences(of: "_", with: " ").utf8))
            if let bytes, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decode(bytes, charset: charset)) }
        }
        return result
    }
    static func decode(_ data: Data, charset: String) -> String {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cf != kCFStringEncodingInvalidId, let value = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))) { return value }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
    static func quotedPrintable(_ data: Data) -> Data {
        let bytes = Array(data); var result = Data(), index = 0
        func hex(_ byte: UInt8) -> UInt8? {
            switch byte { case 48...57: byte - 48; case 65...70: byte - 55; case 97...102: byte - 87; default: nil }
        }
        while index < bytes.count {
            if bytes[index] == 61 {
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                if index + 1 < bytes.count, bytes[index + 1] == 10 { index += 2; continue }
                if index + 2 < bytes.count, let a = hex(bytes[index + 1]), let b = hex(bytes[index + 2]) { result.append(a * 16 + b); index += 3; continue }
            }
            result.append(bytes[index]); index += 1
        }
        return result
    }
    static func parameter(_ name: String, in value: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(pattern: "(?i)(?:^|;)\\s*" + escaped + #"\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;\s]+))"#),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let group = match.range(at: 1).location != NSNotFound ? 1 : 2
        return (value as NSString).substring(with: match.range(at: group)).replacingOccurrences(of: #"\(.)"#, with: "$1", options: .regularExpression)
    }
    private mutating func readPart(headers: [String: String], body: Data, path: String, depth: Int, partCount: inout Int) throws {
        partCount += 1
        guard depth <= 10, partCount <= 200 else { throw OrbitaError.invalidData("Estrutura MIME da mensagem excede os limites suportados.") }
        let type = headers["content-type"] ?? "text/plain", mime = type.components(separatedBy: ";")[0].lowercased().trimmingCharacters(in: .whitespaces)
        if mime.hasPrefix("multipart/") {
            guard let boundary = Self.parameter("boundary", in: type), !boundary.isEmpty, boundary.utf8.count <= 200 else { throw OrbitaError.invalidData("Mensagem multipart sem delimitador válido.") }
            let marker = Data(("--" + boundary).utf8)
            var cursor = body.startIndex, ranges: [Range<Data.Index>] = []
            while let range = body.range(of: marker, in: cursor..<body.endIndex) {
                let lineStart = range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == 10
                let suffix = body[range.upperBound...]
                if lineStart && (suffix.starts(with: [13, 10]) || suffix.starts(with: [10]) || suffix.starts(with: [45, 45])) { ranges.append(range) }
                cursor = range.upperBound
            }
            if !body.isEmpty {
                guard ranges.count >= 2, let last = ranges.last, body[last.upperBound...].starts(with: [45, 45]) else { throw OrbitaError.invalidData("Mensagem multipart truncada.") }
            }
            for index in 0..<max(0, ranges.count - 1) {
                var start = ranges[index].upperBound, end = ranges[index + 1].lowerBound
                if start + 1 < body.endIndex && body[start] == 45 && body[start + 1] == 45 { break }
                while start < end && [10, 13].contains(body[start]) { start += 1 }
                while end > start && [10, 13].contains(body[end - 1]) { end -= 1 }
                let (partHeaders, partBody) = Self.split(body.subdata(in: start..<end))
                try readPart(headers: partHeaders, body: partBody, path: path + ".\(index + 1)", depth: depth + 1, partCount: &partCount)
            }
            return
        }
        let encoding = headers["content-transfer-encoding"]?.lowercased().trimmingCharacters(in: .whitespaces) ?? ""
        let bytes: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: body, options: .ignoreUnknownCharacters) else { throw OrbitaError.invalidData("Conteúdo MIME base64 inválido.") }
            bytes = decoded
        } else { bytes = encoding == "quoted-printable" ? Self.quotedPrintable(body) : body }
        let disposition = headers["content-disposition"] ?? ""
        var name = Self.parameter("filename*", in: disposition).flatMap { $0.components(separatedBy: "''").last?.removingPercentEncoding }
        if name == nil { name = Self.parameter("filename", in: disposition) ?? Self.parameter("name", in: type) }
        if let name, !name.isEmpty {
            attachments.append(InternetAttachment(id: path, name: Self.decodedHeader(name), mimeType: mime, data: bytes)); return
        }
        if disposition.lowercased().hasPrefix("attachment") || mime == "text/calendar" {
            attachments.append(InternetAttachment(id: path, name: mime == "text/calendar" ? "convite.ics" : "anexo", mimeType: mime, data: bytes)); return
        }
        let content = Self.decode(bytes, charset: Self.parameter("charset", in: type) ?? "UTF-8")
        if mime == "text/plain" { text += content }
        if mime == "text/html" { html += content }
    }
    public static func date(_ string: String) -> Date? {
        let value = string.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z", "dd-MMM-yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return Time.parse(value)
    }
    public func message(accountID: String, remoteID: String, isRead: Bool = false, isFlagged: Bool = false, fallbackDate: Date = Date(timeIntervalSince1970: 0)) -> MailMessage {
        let from = Self.decodedHeader(headers["from"] ?? "")
        let sender = Mailbox.addresses(from).first ?? ""
        let preview = String((text.isEmpty ? mailBody.plainText : text).prefix(250))
        return MailMessage(remoteID: remoteID, accountID: accountID, subject: Self.decodedHeader(headers["subject"] ?? ""),
                           sender: sender, senderName: from.components(separatedBy: "<")[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"")),
                           to: Array(Set(Mailbox.addresses(Self.decodedHeader(headers["to"] ?? "")))).sorted(),
                           cc: Array(Set(Mailbox.addresses(Self.decodedHeader(headers["cc"] ?? "")))).sorted(),
                           date: Self.date(headers["date"] ?? "") ?? fallbackDate, preview: preview,
                           isRead: isRead, isFlagged: isFlagged,
                           hasAttachments: !attachments.isEmpty || (headers["content-type"]?.lowercased().contains("multipart/mixed") ?? false),
                           internetMessageID: headers["message-id"] ?? "")
    }
}
