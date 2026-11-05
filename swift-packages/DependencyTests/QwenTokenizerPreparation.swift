import Foundation

@main
enum QwenTokenizerPreparationCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let vocab = root.appendingPathComponent("vocab.json")
        let merges = root.appendingPathComponent("merges.txt")
        let config = root.appendingPathComponent("tokenizer_config.json")
        let output = root.appendingPathComponent("tokenizer.json")
        try JSONSerialization.data(withJSONObject: ["a": 0, "b": 1, "ab": 2]).write(to: vocab)
        try Data("#version: 0.2\na b\n\n".utf8).write(to: merges)
        let tokens: [String: Any] = ["added_tokens_decoder": [
            "4": ["content": "<end>", "special": true],
            "3": ["content": "<start>", "special": true, "lstrip": true]]]
        try JSONSerialization.data(withJSONObject: tokens).write(to: config)
        try Qwen3TTSModel.generateTokenizerJson(vocabPath: vocab, mergesPath: merges, tokenizerConfigPath: config, outputPath: output)
        let bytes = try Data(contentsOf: output)
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        let model = json["model"] as! [String: Any]
        precondition(model["vocab"] as? [String: Int] == ["a": 0, "b": 1, "ab": 2])
        precondition(model["merges"] as? [String] == ["a b"])
        precondition(model["type"] as? String == "BPE")
        let added = json["added_tokens"] as! [[String: Any]]
        precondition(added.compactMap { $0["id"] as? Int } == [3, 4])
        precondition(added[0]["lstrip"] as? Bool == true)
        precondition(added[1]["lstrip"] as? Bool == false)
        precondition((json["decoder"] as? [String: Any])?["type"] as? String == "ByteLevel")
        try Qwen3TTSModel.generateTokenizerJson(vocabPath: vocab, mergesPath: merges, tokenizerConfigPath: config, outputPath: output)
        let repeated = try Data(contentsOf: output)
        precondition(repeated == bytes)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("model.safetensors").path))
        print("Qwen tokenizer conversion passed: deterministic local BPE, merges and special tokens; no model weights or MLX.")
    }
}
