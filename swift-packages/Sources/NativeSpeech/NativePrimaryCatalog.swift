import NarrationCore
// Required runtime files from the pinned Hub trees. English Kokoro voices only.
// Local bytes were verified against published LFS hashes or Git blob IDs.
import Foundation

public enum NativePrimaryCatalog {
    public static func specification(for model: SpeechModel) -> NativePrimarySpecification {
        switch model {
        case .kokoro:
            .init(model: model, repository: "mlx-community/Kokoro-82M-bf16", revision: "a71e4d38b236d968966a2002c4c895dbd12b1c3c", files: [
                .init(path: "config.json", bytes: 2351, sha256: "5abb01e2403b072bf03d04fde160443e209d7a0dad49a423be15196b9b43c17f", gitOID: "14a726edd3718279eac426630879ff743955b16a", compatibleKokoroConfigSHA256: "507dbf092628a6b7b7da5e399e86824ae5109174e52580e6196f8f52daaadd8b"),
                .init(path: "kokoro-v1_0.safetensors", bytes: 327115152, sha256: "4e9ecdf03b8b6cf906070390237feda473dc13327cb8d56a43deaa374c02acd8", gitOID: "1df1761542c63dd4e8cccfcffa765aeb4884b017"),
                .init(path: "voices/af_alloy.safetensors", bytes: 522320, sha256: "5bb848d02ade7e37981809acad52a1761ef7a586ff9f30d02d65fd71c4af95f9", gitOID: "8a30535d695e2134f3b2f87b93034546ac44d396"),
                .init(path: "voices/af_aoede.safetensors", bytes: 522320, sha256: "23809148777f2a2378983dd856bc14b9c261018279f916f98c23d86e844409a5", gitOID: "5485e1b61d3877b0edac804ee5007cab634d13c9"),
                .init(path: "voices/af_bella.safetensors", bytes: 522320, sha256: "112d310468cbb3cf23404d3d0b50ad3adf017b87bf38bf9edd15f4ad572df6a3", gitOID: "2ef1cbc48b116ad1a4db5e52703a6139451861bc"),
                .init(path: "voices/af_heart.safetensors", bytes: 522320, sha256: "2c1c733b0e6576c810e268d3e440c21dea4e0f0131a3ba4cfc98d7fe6136d094", gitOID: "9260494272e2ada295a2c75dffdaace4b402b5e4"),
                .init(path: "voices/af_jessica.safetensors", bytes: 522320, sha256: "c358448e4277b79e8b13b92033711660a1a2205c3940c2dfb16698b99fed58a8", gitOID: "3c15ed357553dc95e1b31cc089eea87ac8bb3286"),
                .init(path: "voices/af_kore.safetensors", bytes: 522320, sha256: "c491174280cb1ad25210a842f2f34b46a9ef904ec6f6a8e784839531795fa278", gitOID: "42108829844b64fc39773d1e1ffd1dd05363c3c3"),
                .init(path: "voices/af_nicole.safetensors", bytes: 522320, sha256: "574656386022c81a029e9a72558191925f44c3de2dad2fa2e45751938557d062", gitOID: "0b5567641ffb8f218eb4bfd8113c4df1a8ac5e91"),
                .init(path: "voices/af_nova.safetensors", bytes: 522320, sha256: "242b9a0a01eac1ac2865c69fc617a756b20d86df82d5fae3970533e2312ca50e", gitOID: "ddb8706f5cd7d0bae409609788b256d9cc80f947"),
                .init(path: "voices/af_river.safetensors", bytes: 522320, sha256: "82c866b0b976d50e82cbd781ac7bc771471ce5bd21decf05ab92812a08fb1c04", gitOID: "3ee0ce6a7ec4d1e1775c410c30b15b9d8b9a4267"),
                .init(path: "voices/af_sarah.safetensors", bytes: 522320, sha256: "4940072182542f54c1035d1daf4c1cf3136ca9baa9ac57c8e006b4befcc50be6", gitOID: "892f90a486feccc4bc90b71ad20ebcf022e0263b"),
                .init(path: "voices/af_sky.safetensors", bytes: 522320, sha256: "957af332330db8e9bd7f9dc449475a946cb0d7d689afef64b91007bbbf20eaa0", gitOID: "3f31f633e11cba84bf7a5984424f5eda6f7c18a8"),
                .init(path: "voices/am_adam.safetensors", bytes: 522320, sha256: "a4f60a3b9c20353c2604a17485ba53260502a758681a84d41e8af53cc559d929", gitOID: "ac564f073ad6b35fed52e06aaf2fa40593206f57"),
                .init(path: "voices/am_echo.safetensors", bytes: 522320, sha256: "031fc608a900332c4e1a29bd0884f5d0e84bd0348261fa79981e5cbd138c950d", gitOID: "bf11cadf346f8405d75b3079296dff752f07ea89"),
                .init(path: "voices/am_eric.safetensors", bytes: 522320, sha256: "1fb4a61dcee1f114f90886ecf29bc2feed05e29eed9caa6ddb109f1934d73274", gitOID: "6ce2e4a7ae665b3363c6d6e26511b741d6243af3"),
                .init(path: "voices/am_fenrir.safetensors", bytes: 522320, sha256: "9abed964b906c4cae6f404d9849e76260689aea862bc6ca85fc3f5207ba96538", gitOID: "eeefadae1d7403baeae0e423df11be145faa1ca8"),
                .init(path: "voices/am_liam.safetensors", bytes: 522320, sha256: "66b65a96e16c3d91035a6e9019d9986ed524d27ce35b487270cdf61c99e3ebad", gitOID: "39e72e006fce6d1c6c7c6b728bf708463ec585c7"),
                .init(path: "voices/am_michael.safetensors", bytes: 522320, sha256: "3940147ded35deba0bb52e8132f89b719298e0520258c34584358aa5a24da2ea", gitOID: "6e39c7787a51e2de0051b8f48978561c1e8dbba0"),
                .init(path: "voices/am_onyx.safetensors", bytes: 522320, sha256: "b5d6132a5747648d98c82c9c4aaa9cf52d7230e63e403c1cb9c12858446ca5f5", gitOID: "aa94550838b65cfed731098c05599e5ae4fb63a1"),
                .init(path: "voices/am_puck.safetensors", bytes: 522320, sha256: "9a8c2e56413bd2063f814cb4c3885fc425876157369117c3f8258d03c8a9ad89", gitOID: "cf251d14f16b4a75c9ff4a66bcd93f41d8befbc9"),
                .init(path: "voices/am_santa.safetensors", bytes: 522320, sha256: "d1f433b57ffccf105ea9e434ea19af6c2a8a7916ba6d1a73c34f0046bd226084", gitOID: "f3b83229cf50c5b2aabed5c7b258aca08feaf26e"),
                .init(path: "voices/bf_alice.safetensors", bytes: 522320, sha256: "9c77e390d93d9db7c4a7526c3b1f393290a2be46f233b89a00b8188e850c20a8", gitOID: "b368a2b4eca9d337b500424bd20bedc611f693a0"),
                .init(path: "voices/bf_emma.safetensors", bytes: 522320, sha256: "8878a75a6661305849eeb1d6293a7177250193616e161b4c3100636434dfe69f", gitOID: "7b2098b172373c16e1de751ddc46f7c29cb1800c"),
                .init(path: "voices/bf_isabella.safetensors", bytes: 522320, sha256: "f7b6076f025649699fcfed1a6debf13049a87afdc7aafc8c72b7d81246db6ead", gitOID: "ab144916f419eb576b7cb5999eded18d17fd3c07"),
                .init(path: "voices/bf_lily.safetensors", bytes: 522320, sha256: "ee77a419046a765420ac82cb46e8b8cf5754a0b9d20c340fece1d4b18be7ecdb", gitOID: "09e6ee99ec65a201dc58500dac1cd43d45d7b538"),
                .init(path: "voices/bm_daniel.safetensors", bytes: 522320, sha256: "b195dec592ee024f57ddc5bf481464596082ba60998a2a295eba90bfc1064f4b", gitOID: "5dc3156ec80f7cd1e228d2b54201621ee5db9b27"),
                .init(path: "voices/bm_fable.safetensors", bytes: 522320, sha256: "9fa80184e96d016a744bc13b0b2e7695e55d6b855556fa003325cb1e5ebf2c2b", gitOID: "df720ebe5cc7626efa5cb67987e15820772dbff4"),
                .init(path: "voices/bm_george.safetensors", bytes: 522320, sha256: "a3d9b8995cbbe5536f954b6be2a0f1f312f077118ba0d4d2178fc41dc8306672", gitOID: "a12417bd396077cfc980da5b72c6941de566ef2c"),
                .init(path: "voices/bm_lewis.safetensors", bytes: 522320, sha256: "e1e68013c21a141efe527aaec561e1174c2f5a6951b3bcecc8396adab315b247", gitOID: "b39e1ee2a6d7c4c244a9c4313025b0564aebdcb8"),
            ])
        case .qwen3, .chatterbox, .orpheus:
            ExpandedModelAssets.primary(model)
        case .soprano:
            .init(model: model, repository: "mlx-community/Soprano-1.1-80M-bf16", revision: "745350c27f356c3910eebcb49e29760dcf6a643c", files: [
                .init(path: "config.json", bytes: 1249, sha256: "6cc152a1b30adc090a0096d9d1b83dc2bcc01a0a8b2a3daf8c3e02fc9e0a703c", gitOID: "465d525e8029143c0fe3af3f06bb0536ba2e2374"),
                .init(path: "model.safetensors", bytes: 280868459, sha256: "1680a01ef354f883699c86cf434fc67b087a8c58cec288c9084d5828a3074575", gitOID: "4a31fb4c58906479e398027ce1607ec0aa27c37f"),
                .init(path: "tokenizer.json", bytes: 1630675, sha256: "eb27ca6c9b55d2f880659a9619d6b8f9b9e6d8553d3ea424f5427788688d7286", gitOID: "5e905c28f54b110fb3eed47e7334463c5f7b1efd"),
                .init(path: "tokenizer_config.json", bytes: 1366802, sha256: "06e83fdb0bdf94eef83ebb08f30620c8ab640344babb4d405ff27befd1a4c270", gitOID: "586fe239657d33b3f95891ad3185b389dd518896"),
            ])
        }
    }
}
