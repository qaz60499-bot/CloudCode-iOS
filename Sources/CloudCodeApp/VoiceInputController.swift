import AVFoundation
import Combine
import Speech

@MainActor
final class VoiceInputController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var recognizedText = ""
    @Published private(set) var errorMessage: String?

    // Keep AVFoundation/Speech service construction off the app's first-frame path.
    // Legacy/over-privileged TrollStore builds may tighten service access. These
    // objects are needed only after the user explicitly starts
    // dictation, so constructing them while ChatView is being created is unnecessary
    // launch risk.
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionGeneration: UUID?
    private var initialText = ""

    func start(existingText: String) {
        guard !isRecording, recognitionGeneration == nil else { return }
        errorMessage = nil
        initialText = existingText.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        recognitionGeneration = generation

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.recognitionGeneration == generation else { return }
                guard status == .authorized else {
                    self.recognitionGeneration = nil
                    self.errorMessage = "语音识别权限未授予。"
                    return
                }
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
                    Task { @MainActor [weak self] in
                        guard let self, self.recognitionGeneration == generation else { return }
                        guard granted else {
                            self.recognitionGeneration = nil
                            self.errorMessage = "麦克风权限未授予。"
                            return
                        }
                        self.beginRecording(generation: generation)
                    }
                }
            }
        }
    }

    func stop() {
        stopRecording()
    }

    private func beginRecording(generation: UUID) {
        guard recognitionGeneration == generation, !isRecording else { return }
        let recognizer = speechRecognizer ?? SFSpeechRecognizer(locale: Locale.current)
        speechRecognizer = recognizer
        guard let recognizer, recognizer.isAvailable else {
            recognitionGeneration = nil
            errorMessage = "语音识别当前不可用。"
            return
        }
        let engine = audioEngine ?? AVAudioEngine()
        audioEngine = engine

        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0 else {
                throw CocoaError(.fileReadUnknown)
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let isFinal = result?.isFinal == true
                Task { @MainActor [weak self] in
                    guard let self, self.recognitionGeneration == generation else { return }
                    if let text, !text.isEmpty {
                        self.recognizedText = [self.initialText, text]
                            .filter { !$0.isEmpty }
                            .joined(separator: " ")
                    }
                    if let error {
                        self.stopRecording()
                        self.errorMessage = "语音识别失败：\(error.localizedDescription)"
                    } else if isFinal {
                        self.stopRecording()
                    }
                }
            }

            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            stopRecording()
            errorMessage = "无法开始语音输入：\(error.localizedDescription)"
        }
    }

    private func stopRecording() {
        recognitionGeneration = nil
        let hadRecognitionResources = isRecording || recognitionRequest != nil || recognitionTask != nil
        guard hadRecognitionResources else { return }

        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
    }
}
