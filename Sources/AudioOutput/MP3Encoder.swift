import Foundation
import Darwin

/// One native LAME state per output, owned by the synchronous writer. No global
/// codec search, gain processing, ReplayGain analysis or integer PCM intermediate.
final class MP3Encoder {
    private typealias Initialize = @convention(c) () -> OpaquePointer?
    private typealias SetInteger = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias SetFloat = @convention(c) (OpaquePointer?, Float) -> Int32
    private typealias StateCall = @convention(c) (OpaquePointer?) -> Int32
    private typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias Flush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias Tag = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int
    private let library: UnsafeMutableRawPointer
    private let state: OpaquePointer
    private let encode: Encode
    private let flush: Flush
    private let tag: Tag
    private let close: StateCall
    private let file: FileHandle
    private var finished = false

    init(libraryURL: URL?, output: URL, sampleRate: Int) throws {
        guard let url = libraryURL ?? Bundle.main.privateFrameworksURL?.appendingPathComponent("libmp3lame.0.dylib"),
              let library = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else { throw AudioOutputError.encoderUnavailable }
        var openedState: OpaquePointer?
        var closeState: StateCall?
        do {
            func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
                guard let pointer = dlsym(library, name) else { throw AudioOutputError.encoderUnavailable }
                return unsafeBitCast(pointer, to: type)
            }
            let close = try symbol("lame_close", StateCall.self)
            closeState = close
            guard let state = try symbol("lame_init", Initialize.self)() else { throw AudioOutputError.encoding }
            openedState = state
            for (name, value): (String, Int32) in [
                ("lame_set_num_channels", 1), ("lame_set_in_samplerate", Int32(sampleRate)),
                ("lame_set_out_samplerate", Int32(sampleRate)), ("lame_set_mode", 3),
                ("lame_set_brate", 128), ("lame_set_quality", 2),
                ("lame_set_findReplayGain", 0), ("lame_set_decode_on_the_fly", 0),
                ("lame_set_bWriteVbrTag", 1)
            ] {
                guard try symbol(name, SetInteger.self)(state, value) == 0 else { throw AudioOutputError.encoding }
            }
            guard try symbol("lame_set_scale", SetFloat.self)(state, 1) == 0,
                  try symbol("lame_init_params", StateCall.self)(state) == 0 else { throw AudioOutputError.encoding }
            self.encode = try symbol("lame_encode_buffer_ieee_float", Encode.self)
            self.flush = try symbol("lame_encode_flush", Flush.self)
            self.tag = try symbol("lame_get_lametag_frame", Tag.self)
            self.file = try FileHandle(forWritingTo: output)
            self.library = library; self.state = state; self.close = close
        } catch {
            if let state = openedState { _ = closeState?(state) }
            dlclose(library)
            throw error
        }
    }

    deinit { try? file.close(); _ = close(state); dlclose(library) }

    func append(_ samples: [Float]) throws {
        guard !finished else { throw AudioOutputError.encoding }
        // LAME's documented maximum: 1.25 * samples + 7200 bytes. Feed small
        // slices so cancellation remains responsive even for a large chunk.
        for start in stride(from: 0, to: samples.count, by: 16_384) {
            try Task.checkCancellation()
            let count = min(16_384, samples.count - start)
            var bytes = [UInt8](repeating: 0, count: count * 5 / 4 + 7_200)
            let written = samples.withUnsafeBufferPointer { input in
                bytes.withUnsafeMutableBufferPointer { output in
                    encode(state, input.baseAddress! + start, nil, Int32(count), output.baseAddress!, Int32(output.count))
                }
            }
            guard written >= 0, written <= bytes.count else { throw AudioOutputError.encoding }
            try file.write(contentsOf: Data(bytes.prefix(Int(written))))
        }
    }

    func finish() throws {
        guard !finished else { return }
        var bytes = [UInt8](repeating: 0, count: 7_200)
        let written = bytes.withUnsafeMutableBufferPointer { flush(state, $0.baseAddress!, Int32($0.count)) }
        guard written >= 0, written <= bytes.count else { throw AudioOutputError.encoding }
        try file.write(contentsOf: Data(bytes.prefix(Int(written))))
        // Replace LAME's initial placeholder with its seek/gapless information.
        // ReplayGain stays disabled; no volume-adjustment tag is generated.
        let tagSize = bytes.withUnsafeMutableBufferPointer { tag(state, $0.baseAddress!, $0.count) }
        guard tagSize >= 0, tagSize <= bytes.count else { throw AudioOutputError.encoding }
        if tagSize > 0 {
            try file.seek(toOffset: 0)
            try file.write(contentsOf: Data(bytes.prefix(tagSize)))
        }
        try file.close()
        finished = true
    }
}
