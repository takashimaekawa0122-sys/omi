// AisaBackgroundAudio.swift
//
// A.I.S.A. Background Survival - Silent Audio Loop
//
// iOSはバックグラウンドのアプリを数分以内に殺す。
// 無音のWAVファイルを無限ループ再生することで、iOSに
// 「音声を再生中のアプリ」と認識させ、アプリの強制終了を防ぐ。
//
// Info.plistの UIBackgroundModes に "audio" が必要（設定済み）。
// バッテリー影響：無音再生のため実質ゼロ。

import AVFoundation
import UIKit

class AisaBackgroundAudio: NSObject {
    static let shared = AisaBackgroundAudio()

    private var audioPlayer: AVAudioPlayer?
    private var isRunning = false

    private override init() {
        super.init()
    }

    /// サイレント音声ループを開始してバックグラウンド生存を確保する
    func start() {
        guard !isRunning else { return }

        // AudioSessionをバックグラウンド再生用に設定
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]  // 他のアプリの音声と共存
            )
            try session.setActive(true)
        } catch {
            NSLog("[AISA BackgroundAudio] AudioSession設定失敗: \(error)")
            return
        }

        // silence.wavをバンドルから読み込む
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "wav") else {
            NSLog("[AISA BackgroundAudio] silence.wav が見つかりません")
            return
        }

        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1  // 無限ループ
            audioPlayer?.volume = 0.0        // 完全無音
            audioPlayer?.prepareToPlay()
            audioPlayer?.play()
            isRunning = true
            NSLog("[AISA BackgroundAudio] サイレントループ開始")
        } catch {
            NSLog("[AISA BackgroundAudio] 再生失敗: \(error)")
        }
    }

    /// サイレント音声ループを停止する
    func stop() {
        guard isRunning else { return }
        audioPlayer?.stop()
        audioPlayer = nil
        isRunning = false
        NSLog("[AISA BackgroundAudio] サイレントループ停止")
    }
}
