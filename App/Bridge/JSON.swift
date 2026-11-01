import Foundation

/// A bridge message: what JSONSerialization reads from the page and writes back.
typealias Message = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func text(_ name: String) -> String? {
        self[name] as? String
    }

    func number(_ name: String) -> Double? {
        guard let value = self[name] as? NSNumber, !value.isBool else { return nil }
        return value.doubleValue
    }

    /// Only a JSON true or false, not a number.
    func flag(_ name: String) -> Bool? {
        guard let value = self[name] as? NSNumber, value.isBool else { return nil }
        return value.boolValue
    }

    func object(_ name: String) -> Message? {
        self[name] as? Message
    }

    func isNull(_ name: String) -> Bool {
        self[name] is NSNull
    }
}

extension NSNumber {
    var isBool: Bool {
        CFGetTypeID(self) == CFBooleanGetTypeID()
    }
}

enum JSON {
    static func parse(_ text: String) -> Message? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? Message
    }

    static func string(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// A value for a message, with JSON null standing in for nil.
func nullable(_ value: Any?) -> Any {
    value ?? NSNull()
}
