// Transcribe a WAV file with the Apple on-device SpeechTranscriber (macOS 26+).
// Usage: apple-stt <wav> [locale]   (default locale: en-US)
// Writes the text to stdout. Writes errors to stderr and exits with code 1.
// ponytail: one process for each transcription, so each call has a cold start.
// If the latency is too high, keep one process alive and send paths on stdin.

import AVFoundation
import Speech

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: apple-stt <wav> [locale]\n".data(using: .utf8)!)
    exit(2)
}

do {
    let transcriber = SpeechTranscriber(locale: Locale(identifier: args.count > 2 ? args[2] : "en-US"), preset: .transcription)
    // First run downloads the model for the locale. Later runs skip this.
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
        try await request.downloadAndInstall()
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let collector = Task {
        var text = ""
        for try await result in transcriber.results where result.isFinal {
            text += String(result.text.characters)
        }
        return text
    }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
    if let end = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    print(try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines))
} catch {
    FileHandle.standardError.write("apple-stt: \(error)\n".data(using: .utf8)!)
    exit(1)
}
