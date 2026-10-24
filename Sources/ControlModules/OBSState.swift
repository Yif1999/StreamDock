import Foundation

/// OBS state as last seen, split by where each part comes from, and kept current mainly by
/// OBS's own events: an event that carries the new value (recording started, scene switched,
/// input muted …) is applied directly; one that only says a list changed (scene created,
/// input removed …) asks for that part to be reloaded. Nothing is re-read just because
/// *something* happened.
///
/// Every part has a revision, bumped by each event that touches it. A reload remembers the
/// revision it started at and is dropped (and retried) if an event arrived meanwhile, so a
/// slow response can never overwrite a newer event.
struct OBSState: Equatable {
    /// Loaded in this order (scene items need the program scene).
    enum Part: Int, CaseIterable, Comparable {
        /// Scene list, program and preview scene.
        case scenes
        /// Recording (and pause), streaming, replay buffer, virtual camera, studio mode.
        case outputs
        /// Inputs that have audio, and their mute state.
        case inputs
        /// Items of the program scene and of scenes used by bindings.
        case sceneItems
        /// Registered hotkey names (no events; only the safety-net reload refreshes them).
        case hotkeys

        static func < (a: Part, b: Part) -> Bool { a.rawValue < b.rawValue }
    }

    var scenes: [String] = []
    var programScene = ""
    var previewScene = ""
    var recording: Bool?
    var recordPaused: Bool?
    var streaming: Bool?
    var studio: Bool?
    var replayActive: Bool?
    var virtualCamera: Bool?
    var recordTime = ""
    var streamTime = ""
    var audioInputs: [String] = []
    var inputMute: [String: Bool] = [:]
    var sceneItems: [OBSClient.SceneItem] = []
    var hotkeys: [String] = []
    private(set) var revisions: [Part: Int] = [:]

    func revision(_ part: Part) -> Int { revisions[part, default: 0] }

    /// Applies one event; returns the parts that must be reloaded because the event only says
    /// that they changed.
    mutating func apply(event type: String, data: OBSData) -> Set<Part> {
        switch type {
        case "RecordStateChanged", "StreamStateChanged", "ReplayBufferStateChanged", "VirtualcamStateChanged":
            touch(.outputs)
            guard let change = Self.outputChange(data["outputState"]?.string) else { return [.outputs] }
            switch type {
            case "RecordStateChanged":
                if let active = change.active { recording = active }
                if let paused = change.paused { recordPaused = paused }
            case "StreamStateChanged": if let active = change.active { streaming = active }
            case "ReplayBufferStateChanged": if let active = change.active { replayActive = active }
            default: if let active = change.active { virtualCamera = active }
            }
            return []
        case "StudioModeStateChanged":
            touch(.outputs)
            guard let enabled = data["studioModeEnabled"]?.bool else { return [.outputs] }
            studio = enabled
            if !enabled { touch(.scenes); previewScene = "" }
            // Entering studio mode picks a preview scene, which the event does not carry.
            return enabled ? [.scenes] : []
        case "CurrentProgramSceneChanged":
            touch(.scenes)
            guard let name = data["sceneName"]?.string else { return [.scenes] }
            programScene = name
            return [.sceneItems]
        case "CurrentPreviewSceneChanged":
            touch(.scenes)
            guard let name = data["sceneName"]?.string else { return [.scenes] }
            previewScene = name
            return []
        case "InputMuteStateChanged":
            touch(.inputs)
            guard let name = data["inputName"]?.string, let muted = data["inputMuted"]?.bool,
                  inputMute[name] != nil else { return [.inputs] }
            inputMute[name] = muted
            return []
        case "SceneItemEnableStateChanged":
            touch(.sceneItems)
            guard let scene = data["sceneName"]?.string, let id = data["sceneItemId"]?.number,
                  let enabled = data["sceneItemEnabled"]?.bool,
                  let index = sceneItems.firstIndex(where: { $0.scene == scene && $0.itemID == Int(id) }) else { return [.sceneItems] }
            let item = sceneItems[index]
            sceneItems[index] = .init(scene: item.scene, itemID: item.itemID, name: item.name, enabled: enabled)
            return []
        case "SceneCreated", "SceneRemoved", "SceneNameChanged", "SceneListChanged":
            touch(.scenes); touch(.sceneItems); return [.scenes, .sceneItems]
        case "InputCreated", "InputRemoved", "InputNameChanged":
            touch(.inputs); touch(.sceneItems); return [.inputs, .sceneItems]
        case "SceneItemCreated", "SceneItemRemoved", "SceneItemListReindexed":
            touch(.sceneItems); return [.sceneItems]
        case "CurrentSceneCollectionChanged", "CurrentProfileChanged":
            for part in Part.allCases { touch(part) }
            return Set(Part.allCases)
        default:
            return []
        }
    }

    mutating func touch(_ part: Part) { revisions[part, default: 0] += 1 }

    /// What an output-state event means, in the terms GetRecordStatus / GetStreamStatus use.
    /// The event's own `outputActive` is true only for STARTED and RESUMED — false while
    /// paused or reconnecting, when the output is still running — so the state is what counts.
    /// nil fields stay as they are (STARTING / STOPPING are transitions); an unknown state
    /// returns nil, and the part is read back.
    static func outputChange(_ state: String?) -> (active: Bool?, paused: Bool?)? {
        switch state {
        case "OBS_WEBSOCKET_OUTPUT_STARTED", "OBS_WEBSOCKET_OUTPUT_RESUMED": (true, false)
        case "OBS_WEBSOCKET_OUTPUT_PAUSED": (true, true)
        case "OBS_WEBSOCKET_OUTPUT_RECONNECTING", "OBS_WEBSOCKET_OUTPUT_RECONNECTED": (true, nil)
        case "OBS_WEBSOCKET_OUTPUT_STOPPED": (false, false)
        case "OBS_WEBSOCKET_OUTPUT_STARTING", "OBS_WEBSOCKET_OUTPUT_STOPPING": (nil, nil)
        default: nil
        }
    }

    /// Takes one part's values from a freshly read copy.
    mutating func adopt(_ part: Part, from other: OBSState) {
        switch part {
        case .scenes:
            scenes = other.scenes; programScene = other.programScene; previewScene = other.previewScene
        case .outputs:
            recording = other.recording; recordPaused = other.recordPaused; streaming = other.streaming
            studio = other.studio; replayActive = other.replayActive; virtualCamera = other.virtualCamera
            recordTime = other.recordTime; streamTime = other.streamTime
        case .inputs:
            audioInputs = other.audioInputs; inputMute = other.inputMute
        case .sceneItems:
            sceneItems = other.sceneItems
        case .hotkeys:
            hotkeys = other.hotkeys
        }
    }
}

/// When each part of `OBSState` is read back to catch an event that may have been missed:
/// once it has gone `quiet` without any news about it — neither an event nor a read.
///
/// A part that just had an event has missed nothing, and reading it then can only do harm:
/// OBS answers status requests from its own (busy) UI side, which may still report the state
/// from before that event — under encoding load a "still recording" answer can arrive after
/// the "recording stopped" event.
struct OBSVerification {
    let quiet: Duration
    private var lastNews: [OBSState.Part: ContinuousClock.Instant] = [:]

    init(quiet: Duration) { self.quiet = quiet }

    mutating func heard(_ parts: some Sequence<OBSState.Part>, at now: ContinuousClock.Instant) {
        for part in parts { lastNews[part] = now }
    }

    func due(at now: ContinuousClock.Instant) -> Set<OBSState.Part> {
        Set(OBSState.Part.allCases.filter { part in lastNews[part].map { now - $0 >= quiet } ?? true })
    }
}
