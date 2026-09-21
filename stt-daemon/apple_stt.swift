// Live transcription with the Apple on-device SpeechTranscriber (macOS 26+).
// Usage: apple-stt [locale] < audio   (default locale: en-US)
// Input on stdin: raw 16 kHz mono Int16 PCM, until EOF.
// Output on stdout: 1 JSON line for each result:
//   {"type": "partial", "text": "..."}   the transcript so far, while audio arrives
//   {"type": "final", "text": "..."}     the full transcript, after EOF
// Writes errors to stderr and exits with code 1.
// To download the model for the locale without audio: apple-stt < /dev/null

import AVFoundation
import Speech

func emit(_ type: String, _ text: String) {
    let json = try! JSONSerialization.data(withJSONObject: ["type": type, "text": text])
    // FileHandle writes have no buffer, so each line goes out immediately.
    FileHandle.standardOutput.write(json + Data("\n".utf8))
}

let locale = Locale(identifier: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "en-US")
// ponytail: fixed input format. SpeechAnalyzer.bestAvailableAudioFormat gives this
// format for en-US. If a locale needs a different format, add an AVAudioConverter.
let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!

do {
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    // First run downloads the model for the locale. Later runs skip this.
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: format)

    let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    Thread.detachNewThread {
        while true {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)! // 100 ms
            // fread blocks until 1600 samples arrive or stdin closes.
            let count = fread(buffer.int16ChannelData![0], 2, 1600, stdin)
            if count == 0 { break }
            buffer.frameLength = AVAudioFrameCount(count)
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        continuation.finish()
    }

    let collector = Task {
        var finalized = ""
        for try await result in transcriber.results {
            // A volatile result is a guess for the newest audio. The final result for
            // the same audio replaces it.
            let text = String(result.text.characters)
            if result.isFinal { finalized += text }
            emit("partial", result.isFinal ? finalized : finalized + text)
        }
        return finalized
    }

    _ = try await analyzer.analyzeSequence(input)
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    emit("final", try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines))
} catch {
    FileHandle.standardError.write("apple-stt: \(error)\n".data(using: .utf8)!)
    exit(1)
}
