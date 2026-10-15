import Foundation
import MLX
import MLXLLM
import MLXNN

// Runtime fixtures for the recorded warning adapters, using Xcode's actual
// package objects. No weights, private documents, or model inference are used.
private enum FixtureError: Error {
    case assertion(String)
    case expected
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FixtureError.assertion(message) }
}

private final class ParameterTree: Module {
    let scalar = MLXArray(Float(1))
    let array = [MLXArray(Float(2)), MLXArray(Float(3))]
    let dictionary = ["entry": MLXArray(Float(4))]
    let child: ParameterLeaf = ParameterLeaf()
    let absent: Identity? = nil
    let metadata = "ignored"
}

private final class ParameterLeaf: Module {
    @ParameterInfo(key: "renamed") var weight = MLXArray(Float(5))
}

@main
private struct EngineBehavior {
    static func main() async throws {
        try optionalWrappers()
        try parameterTraversal()
        try textEncodings()
        try await deviceScopes()
        try await streamScopes()
        try await randomScopes()
        try await cancelledScopes()
        print("Dependency behavior: 7 fixture groups passed.")
    }

    static func optionalWrappers() throws {
        let missing = ParameterInfo<MLXArray?>()
        try expect(missing.wrappedValue == nil, "uninitialized optional parameter")
        let explicitNil = ParameterInfo<MLXArray?>(wrappedValue: nil)
        try expect(explicitNil.wrappedValue == nil, "explicit nil parameter")
        let value = MLXArray([Float(1), Float(2)])
        let present = ParameterInfo<MLXArray?>(wrappedValue: value)
        try expect(present.wrappedValue === value, "optional parameter identity")
        let required = ParameterInfo<MLXArray>(wrappedValue: value)
        try expect(required.wrappedValue === value, "required parameter identity")
        missing.wrappedValue = value
        try expect(missing.wrappedValue === value, "parameter initialization through setter")

        let absent = ModuleInfo<Identity?>()
        try expect(absent.wrappedValue == nil, "uninitialized optional module")
        let nilModule = ModuleInfo<Identity?>(wrappedValue: nil)
        try expect(nilModule.wrappedValue == nil, "explicit nil module")
        let module = Identity()
        let optional = ModuleInfo<Identity?>(wrappedValue: module)
        let nonoptional = ModuleInfo<Identity>(wrappedValue: module)
        try expect(optional.wrappedValue === module, "optional module identity")
        try expect(nonoptional.wrappedValue === module, "required module identity")
        absent.wrappedValue = module
        try expect(absent.wrappedValue === module, "module initialization through setter")
        let nested = ModuleInfo<Identity??>()
        try expect(nested.wrappedValue == nil, "nested optional module promotion")
        print("PASS optional parameter/module getters and initialization")
    }

    static func parameterTraversal() throws {
        let parameters = ParameterTree().parameters().flattened()
        let expected: [String: Float] = [
            "scalar": 1, "array.0": 2, "array.1": 3,
            "dictionary.entry": 4, "child.renamed": 5,
        ]
        try expect(Set(parameters.map(\.0)) == Set(expected.keys), "parameter tree paths")
        for (key, array) in parameters {
            try expect(array.item(Float.self) == expected[key], "parameter value at \(key)")
        }
        // Force structural handling of non-parameter leaves as well as arrays,
        // dictionaries, modules, and absent values in the exhaustive switch.
        let ignored = ParameterTree().filterMap(
            filter: { _, _, _ in true }, map: { _ in Optional<Int>.none },
            isLeaf: { _, _, _ in false })
        try expect(ignored.flattened().isEmpty, "ignored structural leaves")
        print("PASS exhaustive parameter tree traversal")
    }

    static func textEncodings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibroEncodingFixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let encodings: [(String.Encoding, [UInt8])] = [
            (.utf8, []), (.utf16LittleEndian, [0xff, 0xfe]), (.utf16BigEndian, [0xfe, 0xff]),
        ]
        let texts = ["Hello café", "第二行"]
        let lines = "\(texts[0])\n\n\(texts[1])\n"
        let json = "{\"text\":\"\(texts[0])\"}\nignored\n{\"text\":null}\n{\"text\":\"\(texts[1])\"}\n"
        for (index, entry) in encodings.enumerated() {
            for (suffix, contents) in [("txt", lines), ("jsonl", json)] {
                let url = directory.appendingPathComponent("input-\(index).\(suffix)")
                var data = Data(entry.1)
                data.append(contents.data(using: entry.0)!)
                try data.write(to: url)
                let decoded = try loadLoRAData(url: url)
                try expect(decoded == texts, "\(suffix) encoding \(entry.0)")
            }
        }
        let missing = directory.appendingPathComponent("missing.txt")
        do {
            _ = try loadLoRAData(url: missing)
            throw FixtureError.assertion("missing reader input must fail")
        } catch is CocoaError { }
        print("PASS TXT/JSONL UTF-8 and UTF-16 LE/BE detection and missing input")
    }

    static func deviceScopes() async throws {
        let original = Device.defaultDevice()
        var calls = 0
        let array = try await Device.withDefaultDevice(.cpu) {
            calls += 1
            try expect(Device.defaultDevice() === Device.cpu, "device scope entry")
            await Task.yield()
            try expect(Device.defaultDevice() === Device.cpu, "device scope suspension")
            let child = await Task { Device.defaultDevice() }.value
            try expect(child === Device.cpu, "inherited device scope")
            await Device.withDefaultDevice(.gpu) {
                await Task.yield()
                precondition(Device.defaultDevice() === Device.gpu)
            }
            try expect(Device.defaultDevice() === Device.cpu, "nested device restoration")
            return MLXArray(Float(7))
        }
        try expect(array.item(Float.self) == 7, "non-Sendable generic result")
        try expect(calls == 1, "callback executes exactly once")
        try expect(Device.defaultDevice() === original, "device restoration")
        do {
            try await Device.withDefaultDevice(.cpu) {
                await Task.yield()
                throw FixtureError.expected
            }
        } catch FixtureError.expected { }
        try expect(Device.defaultDevice() === original, "throwing device restoration")
        print("PASS async device nesting, suspension, child inheritance, throw, generic result")
    }

    static func streamScopes() async throws {
        let original = StreamOrDevice.default.stream
        try await Stream.withNewDefaultStream(device: .cpu) {
            let scoped = StreamOrDevice.default.stream
            try expect(scoped != original && scoped != Stream.cpu, "fresh scoped stream")
            await Task.yield()
            try expect(StreamOrDevice.default.stream == scoped, "stream suspension")
            let inherited = await Task { StreamOrDevice.default.stream }.value
            try expect(inherited == scoped, "child stream inheritance")
            try await Stream.withNewDefaultStream(device: .cpu) {
                await Task.yield()
                try expect(StreamOrDevice.default.stream != scoped, "nested stream")
            }
            try expect(StreamOrDevice.default.stream == scoped, "nested stream restoration")
        }
        try expect(StreamOrDevice.default.stream == original, "stream restoration")
        do {
            try await Stream.withNewDefaultStream(device: .cpu) {
                await Task.yield()
                throw FixtureError.expected
            }
        } catch FixtureError.expected { }
        try expect(StreamOrDevice.default.stream == original, "throwing stream restoration")
        print("PASS async stream nesting, suspension, child inheritance and throw")
    }

    static func randomScopes() async throws {
        // Evaluate keys in one process and sequence; never share MLX arrays
        // between simultaneous evaluators merely because a state is Sendable.
        func nextKey() -> [UInt32] { resolve().asArray(UInt32.self) }
        func expectedKey(_ seed: UInt64) -> [UInt32] {
            MLXRandom.RandomState(seed: seed).next().asArray(UInt32.self)
        }
        let outer = MLXRandom.RandomState(seed: 101)
        try await withRandomState(outer) {
            await Task.yield()
            try expect(nextKey() == expectedKey(101), "random scope suspension")
            outer.seed(102)
            let child = await Task { nextKey() }.value
            try expect(child == expectedKey(102), "child random inheritance")
            try await withRandomState(MLXRandom.RandomState(seed: 201)) {
                await Task.yield()
                try expect(nextKey() == expectedKey(201), "nested random state")
            }
            outer.seed(103)
            try expect(nextKey() == expectedKey(103), "nested random restoration")
            do {
                try await withRandomState(MLXRandom.RandomState(seed: 202)) {
                    await Task.yield()
                    throw FixtureError.expected
                }
            } catch FixtureError.expected { }
            outer.seed(104)
            try expect(nextKey() == expectedKey(104), "throwing random restoration")
        }
        MLXRandom.globalState.seed(301)
        try expect(nextKey() == expectedKey(301), "global random restoration")
        print("PASS async random state nesting, suspension, child inheritance and throw")
    }

    static func cancelledScopes() async throws {
        let restored = await Task {
            let device = Device.defaultDevice()
            let stream = StreamOrDevice.default.stream
            do {
                try await Device.withDefaultDevice(.cpu) {
                    try await Stream.withNewDefaultStream {
                        try await withRandomState(MLXRandom.RandomState(seed: 401)) {
                            await Task.yield()
                            withUnsafeCurrentTask { $0?.cancel() }
                            try Task.checkCancellation()
                        }
                    }
                }
            } catch is CancellationError {
                MLXRandom.globalState.seed(402)
                let actual = resolve().asArray(UInt32.self)
                let expected = MLXRandom.RandomState(seed: 402).next().asArray(UInt32.self)
                return Device.defaultDevice() === device
                    && StreamOrDevice.default.stream == stream && actual == expected
            } catch { return false }
            return false
        }.value
        try expect(restored, "device, stream and random scope cancellation restoration")
        print("PASS nested async scopes unwind on cancellation")
    }
}
