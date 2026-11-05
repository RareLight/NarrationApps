import Foundation
import Darwin

/// One native LAME state per output, owned by the synchronous writer. No global
/// codec search, gain processing, ReplayGain analysis or integer PCM intermediate.
final class MP3Encoder {
    private typealias Initialize = @convention(c) () -> OpaquePointer?
    private typealias SetInteger = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias SetFlag = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias SetFloat = @convention(c) (OpaquePointer?, Float) -> Int32
    private typealias GetFloat = @convention(c) (OpaquePointer?) -> Float
    private typealias StateCall = @convention(c) (OpaquePointer?) -> Int32
    private typealias Encode = @convention(c) (OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias Flush = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    private typealias Tag = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int
    private typealias AlbumArt = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
    private let audioOffset: UInt64
    private let library: UnsafeMutableRawPointer
    private let state: OpaquePointer
    private let encode: Encode
    private let flush: Flush
    private let tag: Tag
    private let close: StateCall
    private let file: FileHandle?
    private let sink: (Data) throws -> Void
    private var finished = false

    convenience init(libraryURL: URL?, output: URL, sampleRate: Int, coverArtwork: CoverArtwork? = nil) throws {
        try self.init(libraryURL: libraryURL, output: output, sampleRate: sampleRate, coverArtwork: coverArtwork, sink: nil)
    }

    /// Non-seeking responses omit the placeholder Xing frame instead of
    /// pretending that a socket can be rewritten after encoding.
    convenience init(libraryURL: URL?, sampleRate: Int, sink: @escaping (Data) throws -> Void) throws {
        try self.init(libraryURL: libraryURL, output: nil, sampleRate: sampleRate, coverArtwork: nil, sink: sink)
    }

    private init(libraryURL: URL?, output: URL?, sampleRate: Int, coverArtwork: CoverArtwork?, sink: ((Data) throws -> Void)?) throws {
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
                ("lame_set_bWriteVbrTag", output == nil ? 0 : 1)
            ] {
                guard try symbol(name, SetInteger.self)(state, value) == 0 else { throw AudioOutputError.encoding }
            }
            if let coverArtwork {
                guard coverArtwork.data.count <= 128 * 1024 else { throw ArtworkError.tooLarge }
                try symbol("lame_set_write_id3tag_automatic", SetFlag.self)(state, 0)
                let setArt = try symbol("id3tag_set_albumart", AlbumArt.self)
                let status = coverArtwork.data.withUnsafeBytes { setArt(state, $0.bindMemory(to: CChar.self).baseAddress, $0.count) }
                guard status == 0 else { throw ArtworkError.metadata }
            }
            guard try symbol("lame_set_scale", SetFloat.self)(state, 1) == 0,
                  try symbol("lame_init_params", StateCall.self)(state) == 0 else { throw AudioOutputError.encoding }
            // Upstream CBR/ABR preset initialization multiplies scale by 0.95.
            // Require our pinned preservation patch; never compensate by gain.
            for name in ["lame_get_scale", "lame_get_scale_left", "lame_get_scale_right"] {
                guard try symbol(name, GetFloat.self)(state) == 1 else { throw AudioOutputError.encoderUnavailable }
            }
            guard try symbol("lame_get_findReplayGain", StateCall.self)(state) == 0 else { throw AudioOutputError.encoderUnavailable }
            self.encode = try symbol("lame_encode_buffer_ieee_float", Encode.self)
            self.flush = try symbol("lame_encode_flush", Flush.self)
            self.tag = try symbol("lame_get_lametag_frame", Tag.self)
            let file = try output.map { try FileHandle(forWritingTo: $0) }
            self.file = file
            self.sink = sink ?? { bytes in
                guard let file else { throw AudioOutputError.encoding }
                try file.write(contentsOf: bytes)
            }
            if coverArtwork != nil {
                let id3 = try symbol("lame_get_id3v2_tag", Tag.self)
                let count = id3(state, nil, 0)
                guard count > 0, count <= 256 * 1024 else { throw ArtworkError.metadata }
                var bytes = [UInt8](repeating: 0, count: count)
                let written = bytes.withUnsafeMutableBufferPointer { id3(state, $0.baseAddress!, $0.count) }
                guard written == count else { throw ArtworkError.metadata }
                try self.sink(Data(bytes))
                self.audioOffset = UInt64(count)
            } else { self.audioOffset = 0 }
            self.library = library; self.state = state; self.close = close
        } catch {
            if let state = openedState { _ = closeState?(state) }
            dlclose(library)
            throw error
        }
    }

    deinit { try? file?.close(); _ = close(state); dlclose(library) }

    func append(_ samples: [Float]) throws {
        guard !finished else { throw AudioOutputError.encoding }
        // LAME's documented maximum: 1.25 * samples + 7200 bytes. Feed small
        // slices so cancellation remains responsive even for a large chunk.
        for start in stride(from: 0, to: samples.count, by: 16_384) {
            try AudioWorkCheckpoint.check()
            let count = min(16_384, samples.count - start)
            var bytes = [UInt8](repeating: 0, count: count * 5 / 4 + 7_200)
            let written = samples.withUnsafeBufferPointer { input in
                bytes.withUnsafeMutableBufferPointer { output in
                    encode(state, input.baseAddress! + start, nil, Int32(count), output.baseAddress!, Int32(output.count))
                }
            }
            guard written >= 0, written <= bytes.count else { throw AudioOutputError.encoding }
            if written > 0 { try sink(Data(bytes.prefix(Int(written)))) }
        }
    }

    func finish() throws {
        guard !finished else { return }
        try AudioWorkCheckpoint.check()
        var bytes = [UInt8](repeating: 0, count: 7_200)
        let written = bytes.withUnsafeMutableBufferPointer { flush(state, $0.baseAddress!, Int32($0.count)) }
        guard written >= 0, written <= bytes.count else { throw AudioOutputError.encoding }
        if written > 0 { try sink(Data(bytes.prefix(Int(written)))) }
        // Replace LAME's initial placeholder with its seek/gapless information.
        // ReplayGain stays disabled; no volume-adjustment tag is generated.
        if let file {
            let tagSize = bytes.withUnsafeMutableBufferPointer { tag(state, $0.baseAddress!, $0.count) }
            guard tagSize >= 0, tagSize <= bytes.count else { throw AudioOutputError.encoding }
            if tagSize > 0 {
                try file.seek(toOffset: audioOffset)
                try file.write(contentsOf: Data(bytes.prefix(tagSize)))
            }
            try file.close()
        }
        finished = true
    }
}
