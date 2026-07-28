//
//  SpeechService.swift
//  KB_Tune
//
//  기기 내 인식만 사용하는 받아쓰기.
//
//  OCR을 Apple Vision으로 기기 안에서 처리하는 것과 같은 원칙이다.
//  소비·일정 이야기는 민감해서 온디바이스 한국어 모델이 없으면 음성 입력을 끈다.
//  Apple 음성 인식 서버로 자동 전환하지 않는다.
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechService: ObservableObject {

    /// 녹음 중인지. 버튼 모양과 안내 문구가 이 값을 따라간다.
    @Published private(set) var isRecording = false
    /// 지금까지 알아들은 문장. 말하는 동안 계속 갱신된다.
    @Published private(set) var transcript = ""
    /// 사용자에게 보여줄 실패 사유. 성공하면 nil.
    @Published private(set) var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// 권한 팝업을 기다리는 사이 화면을 떠난 경우 뒤늦게 녹음이 시작되지 않게 한다.
    private var startGeneration = 0

    /// 마이크와 음성 인식 권한을 함께 묻는다. 둘 다 있어야 시작할 수 있다.
    func requestPermission() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    func start() async {
        guard !isRecording else { return }
        startGeneration += 1
        let generation = startGeneration
        transcript = ""
        error = nil

        guard let recognizer, recognizer.isAvailable else {
            error = "지금은 음성 인식을 쓸 수 없어요."
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            error = "이 기기에는 한국어 온디바이스 음성 인식이 없어 키보드로 입력해 주세요."
            return
        }
        guard await requestPermission() else {
            error = "마이크와 음성 인식 권한이 필요해요. 설정에서 켜주세요."
            return
        }
        guard generation == startGeneration else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true          // 말하는 동안 화면에 바로 보이게
        // 개인정보가 담긴 음성이 서버로 폴백하지 않도록 강제한다.
        req.requiresOnDeviceRecognition = true
        request = req

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            self.error = "마이크를 열지 못했어요."
            cleanup()
            return
        }

        isRecording = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, err in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                // 인식이 끝났거나 실패하면 마이크를 놓아준다 — 안 그러면 계속 잡고 있다.
                if err != nil || result?.isFinal == true {
                    // 한 글자도 못 알아들었을 때만 알린다. 그마저도 잠깐만 띄우고 지운다 —
                    // 계속 남아 있으면 녹음을 안 하는 동안에도 경고가 붙어 있는 것처럼 보인다.
                    if self.transcript.isEmpty, err != nil {
                        self.showTemporaryError("잘 못 알아들었어요. 다시 말해 주실래요?")
                    }
                    self.stop()
                }
            }
        }
    }

    /// 녹음을 멈추고 지금까지 알아들은 문장을 남긴다.
    func stop() {
        startGeneration += 1
        guard isRecording else {
            cleanup()
            return
        }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        cleanup()
    }

    /// 오류 문구를 잠깐만 띄운다. 다음 녹음을 시작할 때도 지워진다.
    private func showTemporaryError(_ message: String) {
        error = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if !isRecording { error = nil }
        }
    }

    private func cleanup() {
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
