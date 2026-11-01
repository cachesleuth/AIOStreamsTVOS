import Foundation
import Libmpv

/// libmpv's values as JSON-ready Swift values: String, Bool, Int64, Double, arrays and dictionaries.
enum MPVNode {
    static func value(_ node: mpv_node) -> Any? {
        switch node.format {
        case MPV_FORMAT_STRING:
            return node.u.string.map { String(cString: $0) }
        case MPV_FORMAT_FLAG:
            return node.u.flag != 0
        case MPV_FORMAT_INT64:
            return node.u.int64
        case MPV_FORMAT_DOUBLE:
            return node.u.double_
        case MPV_FORMAT_NODE_ARRAY:
            guard let list = node.u.list?.pointee else { return [Any]() }
            return (0..<Int(list.num)).compactMap { value(list.values[$0]) }
        case MPV_FORMAT_NODE_MAP:
            guard let list = node.u.list?.pointee else { return [String: Any]() }
            var map: [String: Any] = [:]
            for i in 0..<Int(list.num) {
                guard let key = list.keys[i] else { continue }
                map[String(cString: key)] = value(list.values[i])
            }
            return map
        default:
            return nil
        }
    }

    /// An observed property's new value, by the format it was observed with.
    static func value(of property: mpv_event_property) -> Any? {
        guard let data = property.data else { return nil }
        switch property.format {
        case MPV_FORMAT_FLAG:
            return data.assumingMemoryBound(to: Int32.self).pointee != 0
        case MPV_FORMAT_DOUBLE:
            return data.assumingMemoryBound(to: Double.self).pointee
        case MPV_FORMAT_INT64:
            return data.assumingMemoryBound(to: Int64.self).pointee
        case MPV_FORMAT_STRING:
            return data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.map { String(cString: $0) }
        case MPV_FORMAT_NODE:
            return value(data.assumingMemoryBound(to: mpv_node.self).pointee)
        default:
            return nil
        }
    }
}
