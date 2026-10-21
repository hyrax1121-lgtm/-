import Foundation
import Combine
import AVFoundation
import Speech

@MainActor
final class VoiceService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var microphoneReady = false
    @Published private(set) var isPreparing = false
    @Published private(set) var isRecording = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var message = "先启用语音，再按住下方按钮说话。录音会保存在本机。"
    @Published private(set) var playingFilename: String?
    var onRecordingSaved: ((String) -> Void)?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionContinuation: CheckedContinuation<String, Error>?
    private var recognitionID: UUID?
    private var recognitionTimeout: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var recordingFilename: String?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.stopRecording() } }
    }

    /// Permission requests happen on an ordinary tap, before a recording gesture.
    /// The user must press again after the system alert, so a released finger never
    /// starts a recording when the asynchronous permission callback completes.
    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        microphoneReady = await AVAudioApplication.requestRecordPermission()
        guard microphoneReady else {
            message = "麦克风尚未允许。可以在系统设置中开启，也可以继续写文字。"
            return
        }
        let speechAllowed = await authorizeTranscription()
        if !speechAllowed {
            message = "可以录音。语音识别尚未允许，录音仍会保留，可稍后转写。"
        } else if SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))?.supportsOnDeviceRecognition != true {
            message = "可以录音。当前设备的中文离线转写不可用，录音会保留；不会自动发送到网络识别。"
        } else {
            message = "准备好了。按住说话，松开保存并尝试本机转写。"
        }
    }

    @discardableResult
    func authorizeTranscription() async -> Bool {
        // Existing/imported audio needs speech permission, not microphone access.
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        if status != .authorized {
            message = "语音识别尚未允许，录音仍会保留。可以在系统设置中开启后重试。"
        }
        return status == .authorized
    }

    func startRecording() {
        guard microphoneReady, !isPreparing, !isRecording, !isTranscribing else { return }
        do {
            stopPlayback()
            try AppPaths.ensureDirectories()
            let filename = "\(UUID().uuidString).m4a"
            let url = AppPaths.audioDirectory.appendingPathComponent(filename)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            let instance = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            instance.delegate = self
            guard instance.prepareToRecord(), instance.record() else {
                throw VoiceError.recordingUnavailable
            }
            recorder = instance
            recordingFilename = filename
            isRecording = true
            message = "正在录音，松开即可保存。"
        } catch {
            message = "未能开始录音：\(error.localizedDescription)"
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stopRecording() {
        guard isRecording, let filename = recordingFilename else { return }
        // Clear state before stop(), whose delegate can call us again.
        isRecording = false
        recordingFilename = nil
        recorder?.stop()
        recorder = nil
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: AppPaths.audioDirectory.appendingPathComponent(filename).path)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        message = "录音已保存。"
        onRecordingSaved?(filename)
    }

    func transcribe(filename: String) async throws -> String {
        try Task.checkCancellation()
        guard !isTranscribing else { throw VoiceError.busy }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            message = "录音已保留。请先允许语音识别，再重试转写。"
            throw VoiceError.permission
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.supportsOnDeviceRecognition else {
            message = "录音已保留。此设备当前不支持中文离线转写。可手动填写文字，或下载系统语音资源后重试。"
            throw VoiceError.offlineUnavailable
        }
        guard recognizer.isAvailable else { throw VoiceError.recognizerUnavailable }
        let url = AppPaths.audioDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { throw VoiceError.missingAudio }
        isTranscribing = true
        message = "正在本机转写，录音已保存。"
        defer { isTranscribing = false; recognitionTask = nil }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let sessionID = UUID()
        recognitionID = sessionID
        do {
            let result: String = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    recognitionContinuation = continuation
                    recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                        Task { @MainActor in
                            if let result, result.isFinal {
                                self.resolveTranscription(.success(result.bestTranscription.formattedString), id: sessionID)
                            } else if let error {
                                self.resolveTranscription(.failure(error), id: sessionID)
                            }
                        }
                    }
                    recognitionTimeout = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                        catch { return }
                        self.resolveTranscription(.failure(VoiceError.timedOut), id: sessionID)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.resolveTranscription(.failure(CancellationError()), id: sessionID) }
            }
            guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VoiceError.emptyTranscript }
            message = "已转写。可以打开记录校对文字，转写原文会保留。"
            return result
        } catch {
            message = "转写未完成，录音已保留。可以重试或手动填写文字。"
            throw error
        }
    }

    private func resolveTranscription(_ result: Result<String, Error>, id: UUID) {
        // Success, failure, cancellation and the watchdog all use this one gate.
        guard recognitionID == id, let continuation = recognitionContinuation else { return }
        recognitionID = nil
        recognitionContinuation = nil
        recognitionTimeout?.cancel()
        recognitionTimeout = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        continuation.resume(with: result)
    }

    func play(filename: String) {
        do {
            stopPlayback()
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player = try AVAudioPlayer(contentsOf: AppPaths.audioDirectory.appendingPathComponent(filename))
            guard player?.play() == true else { throw VoiceError.missingAudio }
            playingFilename = filename
        } catch { message = "无法播放录音：\(error.localizedDescription)" }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingFilename = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in stopRecording() }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            stopRecording()
            message = "录音被中断，已保留可用文件。请打开检查。"
        }
    }
}

enum VoiceError: LocalizedError {
    case recordingUnavailable, permission, offlineUnavailable, recognizerUnavailable, missingAudio, emptyTranscript, busy, timedOut
    var errorDescription: String? {
        switch self {
        case .recordingUnavailable: return "麦克风暂时不可用，请稍后重试。"
        case .permission: return "尚未允许语音识别，请在系统设置中开启。录音已保留。"
        case .offlineUnavailable: return "当前无法进行中文离线转写，录音已保留。"
        case .recognizerUnavailable: return "语音识别服务暂不可用，请稍后重试。录音已保留。"
        case .missingAudio: return "录音文件不存在或暂时无法读取。"
        case .emptyTranscript: return "没有识别到文字，录音已保留。"
        case .busy: return "正在转写上一段录音，请稍候。"
        case .timedOut: return "转写超过一分钟，已停止等待。录音已保留，可以重试。"
        }
    }
}
