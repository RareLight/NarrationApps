import MLXAudioTTS
import MLXLMCommon

// Compile-only ownership checks against the actual patched engine APIs.
// No model objects, weights or inference are created by these fixtures.
func transferLlama(_ model: LlamaTTSModel, cache: sending [KVCache]?) {
    _ = model.generateStream(text: "Fixture", cache: cache)
    #if REUSE_LLAMA_CACHE
    print(cache?.count as Any)
    #endif
}

func transferQwen(_ model: Qwen3Model, cache: sending [KVCache]?) {
    _ = model.generateStream(text: "Fixture", cache: cache)
    #if REUSE_QWEN_CACHE
    print(cache?.count as Any)
    #endif
}
