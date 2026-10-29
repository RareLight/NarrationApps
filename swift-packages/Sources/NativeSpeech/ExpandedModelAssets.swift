import NarrationCore

/// Immutable inventories promoted from the verified October 25 comparison.
enum ExpandedModelAssets {
    static let qwen3 = NativePrimarySpecification(model: .qwen3, repository: "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit", revision: "41d3337e8b7f2843a75841595fc14e4b9a7a4b96", files: [
        .init(path: "config.json", bytes: 6058, sha256: "43f29f9ab55cf387bd2ce1d07e9d95a5ca8974fa2fda4e2b45c13ae64aad3bfa"),
        .init(path: "generation_config.json", bytes: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
        .init(path: "merges.txt", bytes: 1671839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
        .init(path: "model.safetensors", bytes: 2393308931, sha256: "b696f4bf45f54497b6de758981e76f1410bd68af05a657477dee466b0202df1a"),
        .init(path: "model.safetensors.index.json", bytes: 71786, sha256: "2551ed02dc288b90cd6b7ec98652433f08ef2ae98fb3eda5248a4b9e5b47d08b"),
        .init(path: "preprocessor_config.json", bytes: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
        .init(path: "speech_tokenizer/config.json", bytes: 2336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
        .init(path: "speech_tokenizer/configuration.json", bytes: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
        .init(path: "speech_tokenizer/model.safetensors", bytes: 682293092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
        .init(path: "speech_tokenizer/preprocessor_config.json", bytes: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
        .init(path: "tokenizer_config.json", bytes: 7344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
        .init(path: "vocab.json", bytes: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
    ])
    static let chatterbox = NativePrimarySpecification(model: .chatterbox, repository: "mlx-community/chatterbox-turbo-fp16", revision: "b2d0a13aa7cfff0a06d9acb247ae91c8f19a6d75", files: [
        .init(path: "added_tokens.json", bytes: 418, sha256: "72e4ab6acb0d9309ac3df4b526ae5fd80a2da5bc5ab7bb02d85096a374f69193"),
        .init(path: "conds.safetensors", bytes: 164884, sha256: "df9ad2c54848027d94cf01f9fc0ed22bc5d3165df6e6a85c903c1124b8a78a4a"),
        .init(path: "config.json", bytes: 2059, sha256: "aacce8af47c9c930636e47da981339fe0d30e08623d19226aa9a43bd3425b736"),
        .init(path: "merges.txt", bytes: 456318, sha256: "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
        .init(path: "model.safetensors", bytes: 2985990960, sha256: "9f70328a3f6c5257257aea76e9b14c34d8225745d133e4c1e83aa31f3f72a80b"),
        .init(path: "special_tokens_map.json", bytes: 470, sha256: "92ba8063bf40aa163eadebbfe0de07c2aebe44cf0d4a9e8726580b0781fd2640"),
        .init(path: "tokenizer_config.json", bytes: 3878, sha256: "bca16a2ac1ddbd78b8d6228f0031884cc74b6ea54b967d6f6d2ebae9ccde23e6"),
        .init(path: "vocab.json", bytes: 999186, sha256: "f6bd25a65e4e63ca31360e9fb11c7e4f9a391a78385d640acd814092dd6eee4f"),
    ])
    static let chatterboxDependency = NativePrimarySpecification(model: .chatterbox, repository: "mlx-community/S3TokenizerV2", revision: "e0c9886f0e1c35ae85b1f27277416fb19fc72bec", files: [
        .init(path: "config.json", bytes: 126, sha256: "8591fcc0eaae8c2bbfc69cf9d439933ecdf2d58cb9be63d00ce88736c4f2aa9d"),
        .init(path: "model.safetensors", bytes: 494868984, sha256: "928726bc1f206a613d36b8f49e297eae9c5593a21bf9b92ddfe2c23f85eb92cc"),
    ])
    static let orpheus = NativePrimarySpecification(model: .orpheus, repository: "mlx-community/orpheus-3b-0.1-ft-bf16", revision: "3786aac51797181edddeb0d89a8253deaee99aab", files: [
        .init(path: "config.json", bytes: 915, sha256: "2a067afab9ecc1ffd77451cfbab8a50ae1293e3edc865f79f2bfcb9488220982"),
        .init(path: "model-00001-of-00002.safetensors", bytes: 5343373454, sha256: "4250df1165548af4609e8ac7a02a873c22142af32a7c4dca8534f99312a33d4a"),
        .init(path: "model-00002-of-00002.safetensors", bytes: 1258390005, sha256: "4d3f2e09c49e91a614eb154e87c0facdf6b5f6476b374568c60873546c0099a4"),
        .init(path: "model.safetensors.index.json", bytes: 21946, sha256: "3e8331ae3164065405d71d504fe249c6743a5db5912a087dc939680572dfac4d"),
        .init(path: "special_tokens_map.json", bytes: 350, sha256: "02726c1fa32b9ca7e0630f81bf34b76998fe9353a43089d571ee826bae672b25"),
        .init(path: "tokenizer.json", bytes: 22849547, sha256: "fc3fecb199b4170636dbfab986d25f628157268d37b861f9cadaca60b1353bce"),
        .init(path: "tokenizer_config.json", bytes: 5407395, sha256: "cc63c5a97dd0daef0ab805a44e440464aa82ffa8923e6a6477a330b1f96de339"),
    ])
    static let orpheusDependency = NativePrimarySpecification(model: .orpheus, repository: "mlx-community/snac_24khz", revision: "556af1cd3b1c5f2d294f6aa9bb886245d7b716ac", files: [
        .init(path: "config.json", bytes: 300, sha256: "e119b9366d4f5e73c6ca5f31137c4ff361578bbb132953a5203afe037c4012be"),
        .init(path: "model.safetensors", bytes: 79404951, sha256: "e61ae2f638f56ee07a37592cd5a6a9e7d642560ddc78a76ee4a7f96d6922f1be"),
    ])
    static func primary(_ model: SpeechModel) -> NativePrimarySpecification {
        switch model { case .qwen3: qwen3; case .chatterbox: chatterbox; case .orpheus: orpheus
        default: preconditionFailure("Not an expanded model") }
    }
    static func dependencies(_ model: SpeechModel) -> [NativePrimarySpecification] {
        switch model { case .chatterbox: [chatterboxDependency]; case .orpheus: [orpheusDependency]; default: [] }
    }
}

public extension NativePrimaryCatalog {
    static func dependencies(for model: SpeechModel) -> [NativePrimarySpecification] { ExpandedModelAssets.dependencies(model) }
    static func totalBytes(for model: SpeechModel) -> Int64 {
        ([specification(for: model)] + dependencies(for: model)).reduce(0) { $0 + $1.files.reduce(Int64(0)) { $0 + Int64($1.bytes) } }
    }
}

public extension NativePrimaryCatalog {
    /// Structurally pinned fast-tokenizer sidecars generated by the Swift SDK.
    /// They are not remote downloads, but must be validated before use.
    static func generatedFiles(for specification: NativePrimarySpecification) -> [NativePrimaryFile] {
        switch specification.repository {
        case "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit": return [.init(path: "tokenizer.json", bytes: 4762740, sha256: "0af4d885f1e1f86f9307dce16a7f191e5d4df64f318f85fa5e34d474d209b85c", structuralJSONSHA256: "e3be9e3fe14b6bc266118d7b974fbf61652aa1239a135fdb6c3f80ec8efd4e53")]
        case "mlx-community/chatterbox-turbo-fp16": return [.init(path: "tokenizer.json", bytes: 1357942, sha256: "f27d3f0380f8c80badad797cad9b0a2318d1f1015c7e00a051e9e57e2aed4255", structuralJSONSHA256: "b0368ba66dcae7e85555847943bbdd68d72e45497b8cdb5b1079c8a5e88dd89f")]
        default: return []
        }
    }
}
