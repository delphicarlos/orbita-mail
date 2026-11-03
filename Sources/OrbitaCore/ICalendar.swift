import Foundation

struct ICalendarProperty {
    var name: String
    var parameters: [String: String]
    var value: String
    init(_ name: String, value: String, parameters: [String: String] = [:]) { self.name = name; self.value = value; self.parameters = parameters }
    var serialized: String { name + parameters.sorted { $0.key < $1.key }.map { ";\($0.key)=\($0.value)" }.joined() + ":" + value }
}
final class ICalendarComponent {
    let name: String
    var properties: [ICalendarProperty] = []
    var children: [ICalendarComponent] = []
    init(_ name: String) { self.name = name }
    func property(_ name: String) -> ICalendarProperty? { properties.first { $0.name == name } }
    func value(_ name: String) -> String { property(name)?.value ?? "" }
    func set(_ name: String, _ value: String?) {
        properties.removeAll { $0.name == name }
        if let value { properties.append(ICalendarProperty(name, value: value)) }
    }
    var lines: [String] { ["BEGIN:" + name] + properties.map(\.serialized) + children.flatMap(\.lines) + ["END:" + name] }
    var serialized: Data {
        let lines = lines.map { line -> String in
            var result = "", count = 0
            for scalar in line.unicodeScalars {
                let text = String(scalar)
                if count + text.utf8.count > 75 { result += "\r\n "; count = 1 }
                result += text; count += text.utf8.count
            }
            return result
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
enum ICalendar {
    static func property(_ line: String) throws -> ICalendarProperty {
        var quoted = false, escaped = false, colon: String.Index?
        for index in line.indices {
            let character = line[index]
            if character == ":" && !quoted { colon = index; break }
            if character == "\"" && !escaped { quoted.toggle() }
            escaped = character == "\\" && !escaped
        }
        guard let colon else { throw OrbitaError.invalidData("Propriedade iCalendar inválida.") }
        let head = String(line[..<colon]), value = String(line[line.index(after: colon)...])
        var fields: [String] = [], start = head.startIndex; quoted = false
        for index in head.indices {
            if head[index] == "\"" { quoted.toggle() }
            if head[index] == ";" && !quoted { fields.append(String(head[start..<index])); start = head.index(after: index) }
        }
        fields.append(String(head[start...]))
        guard let name = fields.first, !name.isEmpty else { throw OrbitaError.invalidData("Propriedade iCalendar sem nome.") }
        var parameters: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let equals = field.firstIndex(of: "=") else { continue }
            parameters[String(field[..<equals]).uppercased()] = String(field[field.index(after: equals)...])
        }
        return ICalendarProperty(name.uppercased(), value: value, parameters: parameters)
    }
    static func parse(_ bytes: Data) throws -> ICalendarComponent {
        guard bytes.count <= 32_000_000, let text = String(data: bytes, encoding: .utf8) else { throw OrbitaError.invalidData("Calendário não está em UTF-8 ou excede 32 MB.") }
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else if !line.isEmpty { lines.append(line) }
        }
        guard lines.count <= 100_000 else { throw OrbitaError.invalidData("Calendário com propriedades demais.") }
        var root: ICalendarComponent?, stack: [ICalendarComponent] = []
        for line in lines {
            let value = try property(line)
            if value.name == "BEGIN" {
                guard stack.count < 20 else { throw OrbitaError.invalidData("Calendário excessivamente aninhado.") }
                let component = ICalendarComponent(value.value.uppercased())
                if let parent = stack.last { parent.children.append(component) }
                else { guard root == nil else { throw OrbitaError.invalidData("Múltiplos calendários no mesmo objeto.") }; root = component }
                stack.append(component)
            } else if value.name == "END" {
                guard stack.last?.name == value.value.uppercased() else { throw OrbitaError.invalidData("Calendário com delimitadores inconsistentes.") }
                stack.removeLast()
            } else {
                guard let component = stack.last else { throw OrbitaError.invalidData("Propriedade fora de um calendário.") }
                component.properties.append(value)
            }
        }
        guard let root, root.name == "VCALENDAR", stack.isEmpty else { throw OrbitaError.invalidData("Objeto CalDAV incompleto.") }
        return root
    }
    static func text(_ value: String) -> String {
        var result = "", escaped = false
        for character in value {
            if escaped { result += character == "n" || character == "N" ? "\n" : String(character); escaped = false }
            else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result += "\\" }
        return result
    }
    static func date(_ property: ICalendarProperty) throws -> (Date?, String?) {
        let raw = property.value
        if property.parameters["VALUE"]?.uppercased() == "DATE" || raw.count == 8 {
            guard raw.count == 8 else { throw OrbitaError.invalidData("Data iCalendar inválida.") }
            let day = String(raw.prefix(4)) + "-" + String(raw.dropFirst(4).prefix(2)) + "-" + String(raw.suffix(2))
            guard Time.dayDate(day) != nil else { throw OrbitaError.invalidData("Dia iCalendar inválido.") }
            return (nil, day)
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian); formatter.isLenient = false
        if raw.hasSuffix("Z") { formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'" }
        else {
            let name = property.parameters["TZID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let name { guard let zone = TimeZone(identifier: name) else { throw OrbitaError.invalidData("Fuso CalDAV não suportado: \(name). A fonte anterior foi preservada.") }; formatter.timeZone = zone }
            else { formatter.timeZone = .current } // Floating local time as defined by iCalendar.
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        }
        guard let date = formatter.date(from: raw) else { throw OrbitaError.invalidData("Horário iCalendar inválido.") }
        return (date, nil)
    }
    static func utc(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
