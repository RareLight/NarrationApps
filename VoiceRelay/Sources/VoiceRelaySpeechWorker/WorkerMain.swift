import NativeSpeechEngine

@main
struct VoiceRelaySpeechWorker {
    static func main() async { await NativeSpeechWorker.main() }
}
