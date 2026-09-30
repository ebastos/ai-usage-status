import Foundation

enum JSONValue {
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func dict(_ any: Any?) -> [String: Any]? {
        any as? [String: Any]
    }

    static func array(_ any: Any?) -> [Any]? {
        any as? [Any]
    }

    static func string(_ any: Any?) -> String? {
        any as? String
    }

    static func double(_ any: Any?) -> Double? {
        if let number = any as? NSNumber {
            return number.doubleValue
        }
        if let text = any as? String {
            return Double(text)
        }
        return nil
    }

    static func bool(_ any: Any?) -> Bool? {
        guard let any else { return nil }
        let value = any as CFTypeRef
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    static func firstDouble(_ object: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = double(object[key]) { return value }
        }
        return nil
    }

    static func firstString(_ object: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = string(object[key]), !value.isEmpty { return value }
        }
        return nil
    }

    static func firstObject(_ object: [String: Any], _ keys: String...) -> [String: Any]? {
        for key in keys {
            if let value = dict(object[key]) { return value }
        }
        return nil
    }

    static func firstArray(_ object: [String: Any], _ keys: String...) -> [Any]? {
        for key in keys {
            if let value = array(object[key]) { return value }
        }
        return nil
    }
}
