import CryptoKit
import Foundation

indirect enum OBSValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: OBSValue]), array([OBSValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([OBSValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: OBSValue].self)) }
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
    var object: [String: OBSValue]? { if case .object(let v) = self { v } else { nil } }
    var array: [OBSValue]? { if case .array(let v) = self { v } else { nil } }
}

typealias OBSData = [String: OBSValue]
struct OBSMessage: Codable, Sendable { let op: Int; let d: OBSData }

enum OBSProtocol {
    static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }
}

public enum OBSAction: String, Codable, CaseIterable, Identifiable {
    case none, record, pauseRecord, stream, studio, transition, scene, inputMute, sourceVisibility, replayBuffer, saveReplay, virtualCamera, hotkey
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .none: "留空"
        case .record: "录制"
        case .pauseRecord: "暂停录制"
        case .stream: "推流"
        case .studio: "工作室模式"
        case .transition: "切换到预览"
        case .scene: "切换场景"
        case .inputMute: "音频源静音"
        case .sourceVisibility: "来源显示/隐藏"
        case .replayBuffer: "回放缓存"
        case .saveReplay: "保存回放"
        case .virtualCamera: "虚拟相机"
        case .hotkey: "OBS 热键"
        }
    }
}

public struct OBSBinding: Codable, Equatable {
    public var action: OBSAction
    public var target: String = ""
    public var scene: String = ""
    public var itemID: Int? = nil
    public var automaticIndex: Int = 0
    public init(action: OBSAction, automaticIndex: Int = 0) {
        self.action = action
        self.automaticIndex = automaticIndex
    }
    static var defaults: [OBSBinding] {
        [.init(action: .record), .init(action: .pauseRecord), .init(action: .stream), .init(action: .studio), .init(action: .transition)]
        + (0..<5).map { .init(action: .scene, automaticIndex: $0) }
        + [.init(action: .inputMute), .init(action: .inputMute, automaticIndex: 1),
           .init(action: .sourceVisibility), .init(action: .sourceVisibility, automaticIndex: 1), .init(action: .saveReplay)]
    }
}

struct OBSCommand: Equatable { let type: String; var data: OBSData = [:] }

struct OBSLocalConfiguration: Decodable {
    var server_enabled: Bool
    var server_port: Int
    var auth_required: Bool
    var server_password: String?
    static func read() throws -> Self {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}
