public func load_config() -> AppConfig {
    __swift_bridge__$load_config().intoSwiftRepr()
}
public func save_config(_ config: AppConfig) -> Bool {
    __swift_bridge__$save_config(config.intoFfiRepr())
}
public func get_config_path() -> Optional<RustString> {
    { let val = __swift_bridge__$get_config_path(); if val != nil { return RustString(ptr: val!) } else { return nil } }()
}
public func read_config_toml() -> Optional<RustString> {
    { let val = __swift_bridge__$read_config_toml(); if val != nil { return RustString(ptr: val!) } else { return nil } }()
}
public func write_config_toml<GenericIntoRustString: IntoRustString>(_ content: GenericIntoRustString) -> Bool {
    __swift_bridge__$write_config_toml({ let rustString = content.intoRustString(); rustString.isOwned = false; return rustString.ptr }())
}
public struct WordToken {
    public var text: RustString
    public var index: UInt32
    public var total: UInt32
    public var display_time_ms: UInt32

    public init(text: RustString,index: UInt32,total: UInt32,display_time_ms: UInt32) {
        self.text = text
        self.index = index
        self.total = total
        self.display_time_ms = display_time_ms
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$WordToken {
        { let val = self; return __swift_bridge__$WordToken(text: { let rustString = val.text.intoRustString(); rustString.isOwned = false; return rustString.ptr }(), index: val.index, total: val.total, display_time_ms: val.display_time_ms); }()
    }
}
extension __swift_bridge__$WordToken {
    @inline(__always)
    func intoSwiftRepr() -> WordToken {
        { let val = self; return WordToken(text: RustString(ptr: val.text), index: val.index, total: val.total, display_time_ms: val.display_time_ms); }()
    }
}
extension __swift_bridge__$Option$WordToken {
    @inline(__always)
    func intoSwiftRepr() -> Optional<WordToken> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<WordToken>) -> __swift_bridge__$Option$WordToken {
        if let v = val {
            return __swift_bridge__$Option$WordToken(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$WordToken(is_some: false, val: __swift_bridge__$WordToken())
        }
    }
}
public struct PlaybackConfig {
    public var wpm: UInt32
    public var pause_on_punctuation: Bool
    public var punctuation_multiplier: Float

    public init(wpm: UInt32,pause_on_punctuation: Bool,punctuation_multiplier: Float) {
        self.wpm = wpm
        self.pause_on_punctuation = pause_on_punctuation
        self.punctuation_multiplier = punctuation_multiplier
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$PlaybackConfig {
        { let val = self; return __swift_bridge__$PlaybackConfig(wpm: val.wpm, pause_on_punctuation: val.pause_on_punctuation, punctuation_multiplier: val.punctuation_multiplier); }()
    }
}
extension __swift_bridge__$PlaybackConfig {
    @inline(__always)
    func intoSwiftRepr() -> PlaybackConfig {
        { let val = self; return PlaybackConfig(wpm: val.wpm, pause_on_punctuation: val.pause_on_punctuation, punctuation_multiplier: val.punctuation_multiplier); }()
    }
}
extension __swift_bridge__$Option$PlaybackConfig {
    @inline(__always)
    func intoSwiftRepr() -> Optional<PlaybackConfig> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<PlaybackConfig>) -> __swift_bridge__$Option$PlaybackConfig {
        if let v = val {
            return __swift_bridge__$Option$PlaybackConfig(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$PlaybackConfig(is_some: false, val: __swift_bridge__$PlaybackConfig())
        }
    }
}
public struct AppConfig {
    public var window_width: UInt32
    public var window_height: UInt32
    public var wpm: UInt32
    public var inter_word_delay_ms: UInt32

    public init(window_width: UInt32,window_height: UInt32,wpm: UInt32,inter_word_delay_ms: UInt32) {
        self.window_width = window_width
        self.window_height = window_height
        self.wpm = wpm
        self.inter_word_delay_ms = inter_word_delay_ms
    }

    @inline(__always)
    func intoFfiRepr() -> __swift_bridge__$AppConfig {
        { let val = self; return __swift_bridge__$AppConfig(window_width: val.window_width, window_height: val.window_height, wpm: val.wpm, inter_word_delay_ms: val.inter_word_delay_ms); }()
    }
}
extension __swift_bridge__$AppConfig {
    @inline(__always)
    func intoSwiftRepr() -> AppConfig {
        { let val = self; return AppConfig(window_width: val.window_width, window_height: val.window_height, wpm: val.wpm, inter_word_delay_ms: val.inter_word_delay_ms); }()
    }
}
extension __swift_bridge__$Option$AppConfig {
    @inline(__always)
    func intoSwiftRepr() -> Optional<AppConfig> {
        if self.is_some {
            return self.val.intoSwiftRepr()
        } else {
            return nil
        }
    }

    @inline(__always)
    static func fromSwiftRepr(_ val: Optional<AppConfig>) -> __swift_bridge__$Option$AppConfig {
        if let v = val {
            return __swift_bridge__$Option$AppConfig(is_some: true, val: v.intoFfiRepr())
        } else {
            return __swift_bridge__$Option$AppConfig(is_some: false, val: __swift_bridge__$AppConfig())
        }
    }
}

public class Skim: SkimRefMut {
    var isOwned: Bool = true

    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }

    deinit {
        if isOwned {
            __swift_bridge__$Skim$_free(ptr)
        }
    }
}
extension Skim {
    public convenience init() {
        self.init(ptr: __swift_bridge__$Skim$new())
    }
}
public class SkimRefMut: SkimRef {
    public override init(ptr: UnsafeMutableRawPointer) {
        super.init(ptr: ptr)
    }
}
extension SkimRefMut {
    public func read_clipboard() -> Optional<RustString> {
        { let val = __swift_bridge__$Skim$read_clipboard(ptr); if val != nil { return RustString(ptr: val!) } else { return nil } }()
    }

    public func has_clipboard_text() -> Bool {
        __swift_bridge__$Skim$has_clipboard_text(ptr)
    }

    public func load_text<GenericIntoRustString: IntoRustString>(_ text: GenericIntoRustString) {
        __swift_bridge__$Skim$load_text(ptr, { let rustString = text.intoRustString(); rustString.isOwned = false; return rustString.ptr }())
    }

    public func set_config(_ config: PlaybackConfig) {
        __swift_bridge__$Skim$set_config(ptr, config.intoFfiRepr())
    }

    public func advance() -> Optional<WordToken> {
        __swift_bridge__$Skim$advance(ptr).intoSwiftRepr()
    }

    public func go_back() -> Optional<WordToken> {
        __swift_bridge__$Skim$go_back(ptr).intoSwiftRepr()
    }

    public func seek_to(_ index: UInt32) -> Optional<WordToken> {
        __swift_bridge__$Skim$seek_to(ptr, index).intoSwiftRepr()
    }

    public func reset() {
        __swift_bridge__$Skim$reset(ptr)
    }
}
public class SkimRef {
    var ptr: UnsafeMutableRawPointer

    public init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }
}
extension SkimRef {
    public func get_word_count() -> UInt32 {
        __swift_bridge__$Skim$get_word_count(ptr)
    }

    public func get_current_word() -> Optional<WordToken> {
        __swift_bridge__$Skim$get_current_word(ptr).intoSwiftRepr()
    }

    public func is_at_start() -> Bool {
        __swift_bridge__$Skim$is_at_start(ptr)
    }

    public func is_at_end() -> Bool {
        __swift_bridge__$Skim$is_at_end(ptr)
    }

    public func get_progress_percent() -> Float {
        __swift_bridge__$Skim$get_progress_percent(ptr)
    }
}
extension Skim: Vectorizable {
    public static func vecOfSelfNew() -> UnsafeMutableRawPointer {
        __swift_bridge__$Vec_Skim$new()
    }

    public static func vecOfSelfFree(vecPtr: UnsafeMutableRawPointer) {
        __swift_bridge__$Vec_Skim$drop(vecPtr)
    }

    public static func vecOfSelfPush(vecPtr: UnsafeMutableRawPointer, value: Skim) {
        __swift_bridge__$Vec_Skim$push(vecPtr, {value.isOwned = false; return value.ptr;}())
    }

    public static func vecOfSelfPop(vecPtr: UnsafeMutableRawPointer) -> Optional<Self> {
        let pointer = __swift_bridge__$Vec_Skim$pop(vecPtr)
        if pointer == nil {
            return nil
        } else {
            return (Skim(ptr: pointer!) as! Self)
        }
    }

    public static func vecOfSelfGet(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<SkimRef> {
        let pointer = __swift_bridge__$Vec_Skim$get(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return SkimRef(ptr: pointer!)
        }
    }

    public static func vecOfSelfGetMut(vecPtr: UnsafeMutableRawPointer, index: UInt) -> Optional<SkimRefMut> {
        let pointer = __swift_bridge__$Vec_Skim$get_mut(vecPtr, index)
        if pointer == nil {
            return nil
        } else {
            return SkimRefMut(ptr: pointer!)
        }
    }

    public static func vecOfSelfAsPtr(vecPtr: UnsafeMutableRawPointer) -> UnsafePointer<SkimRef> {
        UnsafePointer<SkimRef>(OpaquePointer(__swift_bridge__$Vec_Skim$as_ptr(vecPtr)))
    }

    public static func vecOfSelfLen(vecPtr: UnsafeMutableRawPointer) -> UInt {
        __swift_bridge__$Vec_Skim$len(vecPtr)
    }
}



