import Foundation

indirect enum HAValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: HAValue]), array([HAValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([HAValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: HAValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var number: Double? { if case .number(let v) = self { v } else { nil } }
    var object: [String: HAValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [HAValue]? { if case .array(let v) = self { v } else { nil } }
}


typealias HAData = [String: HAValue]

struct HAEndpoint: Equatable {
    let base: URL
    let websocket: URL
    init(_ text: String) throws {
        var input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !input.contains("://") { input = "http://" + input }
        guard var parts = URLComponents(string: input), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["http", "https", "ws", "wss"].contains(parts.scheme?.lowercased() ?? ""),
              parts.port == nil || (1...65535).contains(parts.port!) else { throw HAFailure.message("请输入有效的 HA 地址，例如 http://homeassistant.local:8123") }
        let secure = ["https", "wss"].contains(parts.scheme?.lowercased() ?? "")
        parts.scheme = secure ? "https" : "http"
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !parts.path.isEmpty { parts.path = "/" + parts.path }
        guard let base = parts.url else { throw HAFailure.message("HA 地址无效") }
        self.base = base
        parts.scheme = secure ? "wss" : "ws"
        parts.path += "/api/websocket"
        guard let socket = parts.url else { throw HAFailure.message("HA 地址无效") }
        websocket = socket
    }
}

enum HAFailure: Error, LocalizedError {
    case disconnected, timeout, message(String)
    var errorDescription: String? {
        switch self {
        case .disconnected: "HA 已断开，操作未重试"
        case .timeout: "HA 响应超时，请确认设备状态后再操作"
        case .message(let text): text
        }
    }
}

public enum HAAction: String, Codable, CaseIterable, Identifiable {
    case none, toggle, safePower, turnOn, turnOff, brighter, dimmer, warmer, cooler, temperatureDown, temperatureUp, climateMode, fanSpeedDown, fanSpeedUp, fanOscillate, fanPreset, scene, script, openCover, closeCover, stopCover, status
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "留空"
        case .toggle: "开关切换"
        case .safePower: "电源开关（长按 1 秒断电）"
        case .turnOn: "打开"
        case .turnOff: "关闭"
        case .brighter: "亮度增加 10%"
        case .dimmer: "亮度降低 10%"
        case .warmer: "灯光暖一点"
        case .cooler: "灯光冷一点"
        case .temperatureDown: "空调降温一档"
        case .temperatureUp: "空调升温一档"
        case .climateMode: "切换空调模式"
        case .fanSpeedDown: "风扇减速一档"
        case .fanSpeedUp: "风扇加速一档"
        case .fanOscillate: "风扇摇头开关"
        case .fanPreset: "切换风扇风型"
        case .scene: "执行场景"
        case .script: "执行脚本"
        case .openCover: "打开窗帘"
        case .closeCover: "关闭窗帘"
        case .stopCover: "停止窗帘"
        case .status: "只显示状态"
        }
    }
    func accepts(_ domain: String) -> Bool {
        switch self {
        case .none: false
        case .safePower: domain == "switch"
        case .toggle, .turnOn, .turnOff: ["light", "switch", "fan", "input_boolean", "climate"].contains(domain)
        case .brighter, .dimmer, .warmer, .cooler: domain == "light"
        case .temperatureDown, .temperatureUp, .climateMode: domain == "climate"
        case .fanSpeedDown, .fanSpeedUp, .fanOscillate, .fanPreset: domain == "fan"
        case .scene: domain == "scene"
        case .script: domain == "script"
        case .openCover, .closeCover, .stopCover: domain == "cover"
        case .status: true
        }
    }
}

public struct HABinding: Codable, Equatable {
    public var action: HAAction
    public var entityID: String
    public var label: String
    public init(action: HAAction = .none, entityID: String = "", label: String = "") {
        self.action = action; self.entityID = entityID; self.label = label
    }
}

public struct HAEntity: Identifiable, Equatable, Sendable {
    public let id: String
    public let state: String
    let attributes: HAData
    public var name: String { attributes["friendly_name"]?.string ?? id }
    public var domain: String { String(id.split(separator: ".").first ?? "") }
    public var available: Bool { state != "unavailable" && (state != "unknown" || ["scene", "script"].contains(domain)) }
    public var active: Bool { ["on", "open", "opening", "playing", "home", "heat", "cool", "auto", "dry", "fan_only", "heat_cool"].contains(state) }
    var modeTitle: String {
        ["off": "关", "auto": "自动", "cool": "制冷", "heat": "制热", "dry": "除湿", "fan_only": "送风", "heat_cool": "冷暖"][state] ?? state
    }
    var targetTemperature: String? {
        attributes["temperature"]?.number.map { String(format: "%g°", $0) }
    }
    /// The HVAC mode in a word, for keys.
    var keyMode: String {
        ["off": "Off", "auto": "Auto", "cool": "Cool", "heat": "Heat", "dry": "Dry", "fan_only": "Fan", "heat_cool": "H/C"][state] ?? state
    }
    /// The state as a key shows it: a number when there is one, else a short English word.
    /// (The settings window keeps `displayState`.)
    var keyState: String {
        if state == "unavailable" { return "Offline" }
        if state == "unknown" { return domain == "scene" ? "Ready" : "Unknown" }
        if domain == "climate" { return state == "off" ? "Off" : targetTemperature ?? keyMode }
        if domain == "fan", state == "on", let p = attributes["percentage"]?.number { return "\(Int(p))%" }
        if domain == "light", state == "on", let b = attributes["brightness"]?.number { return "\(Int((b / 255 * 100).rounded()))%" }
        if domain == "cover", let p = attributes["current_position"]?.number { return "\(Int(p))%" }
        let words = ["on": "On", "off": "Off", "open": "Open", "closed": "Closed", "opening": "Opening", "closing": "Closing",
                     "home": "Home", "not_home": "Away"]
        if let word = words[state] { return word }
        let unit = attributes["unit_of_measurement"]?.string ?? ""
        return state + unit
    }
    public var displayState: String {
        if state == "unavailable" { return "离线" }
        if state == "unknown" { return domain == "scene" ? "待执行" : "未知" }
        if domain == "climate" { return state == "off" ? "关" : targetTemperature ?? modeTitle }
        if domain == "fan", state == "on", let p = attributes["percentage"]?.number { return "\(Int(p))%" }
        if domain == "light", state == "on", let b = attributes["brightness"]?.number { return "\(Int((b / 255 * 100).rounded()))%" }
        if domain == "cover", let p = attributes["current_position"]?.number { return "\(Int(p))%" }
        let words = ["on": "开", "off": "关", "open": "已打开", "closed": "已关闭", "opening": "打开中", "closing": "关闭中", "home": "在家", "not_home": "离家"]
        if let word = words[state] { return word }
        let unit = attributes["unit_of_measurement"]?.string ?? ""
        return state + unit
    }
    init?(_ value: HAValue) {
        guard let data = value.object, let id = data["entity_id"]?.string, let state = data["state"]?.string else { return nil }
        self.id = id; self.state = state; attributes = data["attributes"]?.object ?? [:]
    }
}

struct HACommand {
    let domain: String
    let service: String
    let entityID: String
    var data: HAData = [:]
    var message: HAData {
        ["type": .string("call_service"), "domain": .string(domain), "service": .string(service),
         "target": .object(["entity_id": .string(entityID)]), "service_data": .object(data)]
    }
}

extension HACommand {
    static func make(action: HAAction, entity: HAEntity, services: HAData) -> HACommand? {
        guard entity.available, action.accepts(entity.domain) else { return nil }
        let attributes = entity.attributes
        let flags = Int(attributes["supported_features"]?.number ?? 0)
        func options(_ key: String) -> [String] { attributes[key]?.array?.compactMap(\.string) ?? [] }
        func next(_ values: [String], current: String) -> String? {
            guard !values.isEmpty else { return nil }
            return values[(values.firstIndex(of: current).map { $0 + 1 } ?? 0) % values.count]
        }
        var service: String
        var data: HAData = [:]
        switch action {
        case .none, .status: return nil
        case .toggle: service = entity.domain == "climate" ? (entity.state == "off" ? "turn_on" : "turn_off") : "toggle"
        case .safePower:
            guard ["on", "off"].contains(entity.state) else { return nil }
            service = entity.state == "on" ? "turn_off" : "turn_on"
        case .turnOn, .scene, .script: service = "turn_on"
        case .turnOff: service = "turn_off"
        case .temperatureDown, .temperatureUp:
            guard entity.state != "off", flags & 1 != 0,
                  let current = attributes["temperature"]?.number,
                  let low = attributes["min_temp"]?.number, let high = attributes["max_temp"]?.number, low <= high else { return nil }
            let step = attributes["target_temp_step"]?.number ?? 1
            guard step > 0 else { return nil }
            let target = min(high, max(low, current + (action == .temperatureUp ? step : -step)))
            guard target != current else { return nil }
            service = "set_temperature"; data["temperature"] = .number(target)
        case .climateMode:
            guard entity.state != "off", let value = next(options("hvac_modes").filter { $0 != "off" }, current: entity.state), value != entity.state else { return nil }
            service = "set_hvac_mode"; data["hvac_mode"] = .string(value)
        case .fanSpeedDown, .fanSpeedUp:
            guard entity.state == "on", flags & 1 != 0, let current = attributes["percentage"]?.number else { return nil }
            let step = attributes["percentage_step"]?.number ?? 10
            guard step > 0, step <= 100 else { return nil }
            let target = min(100, max(step, current + (action == .fanSpeedUp ? step : -step)))
            guard target != current else { return nil }
            service = "set_percentage"; data["percentage"] = .number(target.rounded())
        case .fanOscillate:
            guard entity.state == "on", flags & 2 != 0, let oscillating = attributes["oscillating"]?.bool else { return nil }
            service = "oscillate"; data["oscillating"] = .bool(!oscillating)
        case .fanPreset:
            guard entity.state == "on", flags & 8 != 0,
                  let value = next(options("preset_modes"), current: attributes["preset_mode"]?.string ?? ""),
                  value != attributes["preset_mode"]?.string else { return nil }
            service = "set_preset_mode"; data["preset_mode"] = .string(value)
        case .brighter, .dimmer:
            guard options("supported_color_modes").contains(where: { $0 != "onoff" }), entity.state == "on" else { return nil }
            service = "turn_on"; data["brightness_step_pct"] = .number(action == .brighter ? 10 : -10)
        case .warmer, .cooler:
            func kelvin(_ direct: String, _ mired: String) -> Double? {
                if let value = attributes[direct]?.number, value > 0 { return value }
                if let value = attributes[mired]?.number, value > 0 { return 1_000_000 / value }
                return nil
            }
            guard entity.state == "on", options("supported_color_modes").contains("color_temp"),
                  let current = kelvin("color_temp_kelvin", "color_temp"),
                  let low = kelvin("min_color_temp_kelvin", "max_mireds"),
                  let high = kelvin("max_color_temp_kelvin", "min_mireds"), low <= high else { return nil }
            let target = min(high, max(low, current + (action == .cooler ? 200 : -200))).rounded()
            guard target != current.rounded() else { return nil }
            service = "turn_on"; data["color_temp_kelvin"] = .number(target)
        case .openCover: service = "open_cover"
        case .closeCover: service = "close_cover"
        case .stopCover: service = "stop_cover"
        }
        if entity.domain == "climate", service == "turn_on" || service == "turn_off" {
            guard flags & (service == "turn_on" ? 256 : 128) != 0 else { return nil }
        }
        if entity.domain == "cover" {
            let required = action == .openCover ? 1 : action == .closeCover ? 2 : 8
            guard flags & required != 0 else { return nil }
        }
        guard services[entity.domain]?.object?[service] != nil else { return nil }
        return HACommand(domain: entity.domain, service: service, entityID: entity.id, data: data)
    }
}
