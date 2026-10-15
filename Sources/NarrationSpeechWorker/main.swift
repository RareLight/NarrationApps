import NativeSpeechEngine

@main
struct WorkerMain {
    static func main() async { await NativeSpeechWorker.main() }
}
