import NarrationCore

public extension ModelPreparationProgress {
    func isValid(for model: SpeechModel) -> Bool {
        let expected = scope == .primary ? NativePrimaryCatalog.specification(for: model).files.reduce(Int64(0)) { $0 + Int64($1.bytes) }
            : NativeG2P.requiredFiles.values.reduce(Int64(0)) { $0 + Int64($1) }
        return (scope != .g2p || model == .kokoro) && (totalBytes == expected || (scope == .g2p && totalBytes == BritishG2P.totalBytes)) && completedBytes >= 0 && completedBytes <= totalBytes
    }
}
