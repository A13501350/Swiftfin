//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Combine
import Defaults
import Foundation
import Logging
@preconcurrency import JellyfinAPI
import SwiftUI

// TODO: After NativeVideoPlayer is removed, can move bindings and
//       observers to AVPlayerView, like the VLC delegate
//       - wouldn't need to have MediaPlayerProxy: MediaPlayerObserver
// TODO: report playback information
// TODO: report buffering state
// TODO: have set seconds with completion handler

@MainActor
class AVMediaPlayerProxy: VideoMediaPlayerProxy {

    let isBuffering: PublishedBox<Bool> = .init(initialValue: false)
    var isScrubbing: Binding<Bool> = .constant(false)
    var scrubbedSeconds: Binding<Duration> = .constant(.zero)
    var videoSize: PublishedBox<CGSize> = .init(initialValue: .zero)
    let droppedFrames: PublishedBox<Int> = .init(initialValue: 0)
    let corruptedFrames: PublishedBox<Int> = .init(initialValue: 0)

    let avPlayerLayer: AVPlayerLayer
    let player: AVPlayer

    private let logger = Logger.swiftfin()
    private var rateObserver: NSKeyValueObservation!
    private var statusObserver: NSKeyValueObservation!
    private var timeControlStatusObserver: NSKeyValueObservation!
    private var currentItemObserver: NSKeyValueObservation!
    private var timeObserver: Any!
    private var managerItemObserver: AnyCancellable?
    private var managerStateObserver: AnyCancellable?
    private var manifestInterceptor: HLSManifestInterceptor?

    weak var manager: MediaPlayerManager? {
        didSet {
            for var o in observers {
                o.manager = manager
            }

            if let manager {
                managerItemObserver = manager.$playbackItem
                    .sink { playbackItem in
                        if let playbackItem {
                            self.playNew(item: playbackItem)
                        }
                    }

                managerStateObserver = manager.$state
                    .sink { state in
                        switch state {
                        case .stopped:
                            self.playbackStopped()
                        default: break
                        }
                    }
            } else {
                managerItemObserver?.cancel()
                managerStateObserver?.cancel()
            }
        }
    }

    var observers: [any MediaPlayerObserver] = [
        NowPlayableObserver(),
    ]

    init() {
        self.player = AVPlayer()
        self.avPlayerLayer = AVPlayerLayer(player: player)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 1000),
            queue: .main
        ) { newTime in
            let newSeconds = Duration.seconds(newTime.seconds)

            if !self.isScrubbing.wrappedValue {
                self.scrubbedSeconds.wrappedValue = newSeconds
            }

            self.manager?.seconds = newSeconds
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.pause()
    }

    func jumpForward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = currentTime + CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func jumpBackward(_ seconds: Duration) {
        let currentTime = player.currentTime()
        let newTime = max(.zero, currentTime - CMTime(seconds: seconds.seconds, preferredTimescale: 1))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setSeconds(_ seconds: Duration) {
        let time = CMTime(seconds: seconds.seconds, preferredTimescale: 1)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // TODO: complete
    func setRate(_ rate: Float) {}
    func setAudioStream(_ stream: MediaStream) {}
    func setSubtitleStream(_ stream: MediaStream) {}

    func setAspectFill(_ aspectFill: Bool) {
        avPlayerLayer.videoGravity = aspectFill ? .resizeAspectFill : .resizeAspect
    }

    var videoPlayerBody: some View {
        AVPlayerView()
            .environmentObject(self)
    }
}

extension AVMediaPlayerProxy {

    private func playbackStopped() {
        logger.info("playbackStopped")
        player.pause()

        if let timeObserver {
            DispatchQueue.main.async {
                self.player.removeTimeObserver(timeObserver)
                self.timeObserver = nil
            }
        }

        if let rateObserver {
            rateObserver.invalidate()
            self.rateObserver = nil
        }

        if let statusObserver {
            statusObserver.invalidate()
            self.statusObserver = nil
        }

        if let timeControlStatusObserver {
            timeControlStatusObserver.invalidate()
            self.timeControlStatusObserver = nil
        }

        if let currentItemObserver {
            currentItemObserver.invalidate()
            self.currentItemObserver = nil
        }

        manifestInterceptor = nil
    }

    private func playNew(item: MediaPlayerItem) {
        let baseItem = item.baseItem

        logger.info("playNew: url=\(item.url.absoluteString)")
        logger.info("playNew: transcodeURL=\(item.mediaSource.transcodingURL?.absoluteString ?? "nil")")
        logger.info("playNew: mediaType=\(item.mediaSource.mediaStream?.type?.rawValue ?? "nil")")

        // Use HLS manifest interceptor for transcoded streams to fix X-TIMESTAMP-MAP
        let newAVPlayerItem: AVPlayerItem
        if item.mediaSource.transcodingURL != nil,
           let client = manager?.userSession?.client
        {
            let interceptor = HLSManifestInterceptor(url: item.url, client: client)
            manifestInterceptor = interceptor
            let asset = interceptor.makeAsset()
            newAVPlayerItem = AVPlayerItem(asset: asset)
            logger.info("playNew: using HLSManifestInterceptor with custom scheme")
        } else {
            manifestInterceptor = nil
            newAVPlayerItem = AVPlayerItem(url: item.url)
            logger.info("playNew: direct AVPlayerItem (no interception)")
        }
        newAVPlayerItem.externalMetadata = item.baseItem.avMetadata

        player.replaceCurrentItem(with: newAVPlayerItem)
        logger.info("playNew: player.replaceCurrentItem done, status=\(newAVPlayerItem.status.rawValue)")

        // Observe rate changes
        rateObserver = player.observe(\.rate, options: [.new, .initial]) { [logger] player, _ in
            logger.info("AVPlayer rate changed: \(player.rate)")
        }

        // Observe timeControlStatus
        timeControlStatusObserver = player.observe(\.timeControlStatus, options: [.new, .initial]) { [logger] player, _ in
            let status = player.timeControlStatus
            switch status {
            case .paused:
                logger.info("AVPlayer timeControlStatus: paused")
                DispatchQueue.main.async {
                    self.manager?.setPlaybackRequestStatus(status: .paused)
                }
            case .waitingToPlayAtSpecifiedRate:
                logger.info("AVPlayer timeControlStatus: waitingToPlayAtSpecifiedRate")
            case .playing:
                logger.info("AVPlayer timeControlStatus: playing")
                DispatchQueue.main.async {
                    self.manager?.setPlaybackRequestStatus(status: .playing)
                }
            @unknown default:
                logger.info("AVPlayer timeControlStatus: unknown(\(status.rawValue))")
            }
        }

        // Observe currentItem status
        statusObserver = player.observe(\.currentItem?.status, options: [.new, .initial]) { [logger] _, value in
            guard let newValue = value.newValue else { return }
            switch newValue {
            case .failed:
                logger.error("AVPlayer currentItem.status: FAILED")
                if let error = self.player.error {
                    logger.error("AVPlayer error: \(error.localizedDescription)")
                    if let nsError = error as NSError? {
                        logger.error("AVPlayer error domain=\(nsError.domain) code=\(nsError.code) userInfo=\(nsError.userInfo)")
                    }
                    DispatchQueue.main.async {
                        self.manager?.error(ErrorMessage("AVPlayer error: \(error.localizedDescription)"))
                    }
                }
                if let itemError = self.player.currentItem?.error {
                    logger.error("AVPlayer currentItem.error: \(itemError.localizedDescription)")
                }
            case .none:
                logger.info("AVPlayer currentItem.status: none")
            case .readyToPlay:
                logger.info("AVPlayer currentItem.status: readyToPlay")
                let startSeconds = max(.zero, (baseItem.startSeconds ?? .zero) - Duration.seconds(Defaults[.VideoPlayer.resumeOffset]))
                logger.info("playNew: seeking to \(startSeconds.components.seconds)s")

                self.player.seek(
                    to: CMTimeMake(
                        value: startSeconds.components.seconds,
                        timescale: 1
                    ),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { [logger] _ in
                        logger.info("playNew: seek completed, playing")
                        self.play()
                    }
                )
            case .unknown:
                logger.info("AVPlayer currentItem.status: unknown")
            @unknown default:
                logger.info("AVPlayer currentItem.status: unknown(\(newValue.rawValue))")
            }
        }

        // Observe currentItem changes
        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [logger] _, value in
            if let item = value.newValue as? AVPlayerItem {
                logger.info("AVPlayer currentItem changed: status=\(item.status.rawValue) duration=\(item.duration.seconds)s")
                if let tracks = item.tracks as? [AVPlayerItemTrack] {
                    logger.info("AVPlayer tracks: \(tracks.count)")
                    for (idx, track) in tracks.enumerated() {
                        logger.info("  track[\(idx)]: enabled=\(track.isEnabled) mediaType=\(track.assetTrack?.mediaType.rawValue ?? "nil")")
                    }
                }
            } else {
                logger.info("AVPlayer currentItem changed: nil")
            }
        }

        // Observe playbackBufferFull and playbackBufferEmpty
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: newAVPlayerItem,
            queue: .main
        ) { [logger] _ in
            logger.warning("AVPlayerItemPlaybackStalled notification")
        }

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: newAVPlayerItem,
            queue: .main
        ) { [logger] _ in
            logger.info("AVPlayerItemDidPlayToEndTime notification")
        }
    }
}

// MARK: - AVPlayerView

extension AVMediaPlayerProxy {

    struct AVPlayerView: PlatformViewRepresentable {

        @EnvironmentObject
        private var proxy: AVMediaPlayerProxy
        @EnvironmentObject
        private var scrubbedSeconds: PublishedBox<Duration>

        func makeUIView(context: Context) -> UIView {
//            proxy.isScrubbing = context.environment.isScrubbing
//            proxy.scrubbedSeconds = $scrubbedSeconds.value
            UIAVPlayerView(proxy: proxy)
        }

        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private class UIAVPlayerView: UIView {

        let proxy: AVMediaPlayerProxy

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy
            super.init(frame: .zero)
            layer.addSublayer(proxy.avPlayerLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            proxy.avPlayerLayer.frame = bounds
        }
    }
}
