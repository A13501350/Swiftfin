//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVKit
import FactoryKit
import JellyfinAPI
import Logging
import SwiftUI
import Transmission

// TODO: remove

struct NativeVideoPlayer: View {

    @Environment(\.presentationCoordinator)
    private var presentationCoordinator

    @InjectedObject(\.mediaPlayerManager)
    private var manager: MediaPlayerManager

    @LazyState
    private var proxy: AVMediaPlayerProxy

    @Router
    private var router

    init() {
        self._proxy = .init(wrappedValue: AVMediaPlayerProxy())
    }

    var body: some View {
        ZStack {

            Color.black

            switch manager.state {
            case .playback:
                NativeVideoPlayerView(proxy: proxy)
            default:
                ProgressView()
            }
        }
        .onAppear {
            manager.proxy = proxy
            manager.start()
        }
        .prefersStatusBarHidden()
        .onChange(of: presentationCoordinator.isPresented) {
            Container.shared.mediaPlayerManager.reset()
            guard !presentationCoordinator.isPresented else { return }
            manager.stop()
        }
        .alert(
            L10n.error,
            isPresented: .constant(manager.error != nil)
        ) {
            Button(L10n.close, role: .cancel) {
                Container.shared.mediaPlayerManager.reset()
                router.dismiss()
            }
        } message: {
            Text(L10n.unableToLoadThisItem)
        }
        .onFinalDisappear {
            manager.stop()
        }
    }
}

extension NativeVideoPlayer {

    private struct NativeVideoPlayerView: PlatformViewControllerRepresentable {

        let proxy: AVMediaPlayerProxy

        func makeUIViewController(context: Context) -> UINativeVideoPlayerViewController {
            UINativeVideoPlayerViewController(proxy: proxy)
        }

        func updateUIViewController(_ uiViewController: UINativeVideoPlayerViewController, context: Context) {}
    }

    private class UINativeVideoPlayerViewController: AVPlayerViewController {

        private let proxy: AVMediaPlayerProxy
        private let subtitleLabel = UILabel()

        init(proxy: AVMediaPlayerProxy) {
            self.proxy = proxy

            super.init(nibName: nil, bundle: nil)

            player = proxy.player

            player?.allowsExternalPlayback = true
            player?.appliesMediaSelectionCriteriaAutomatically = false
            player?.usesExternalPlaybackWhileExternalScreenIsActive = true
            allowsPictureInPicturePlayback = true

            #if !os(tvOS)
            updatesNowPlayingInfoCenter = false
            #endif
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()

            subtitleLabel.numberOfLines = 0
            subtitleLabel.textAlignment = .center
            subtitleLabel.textColor = .white
            subtitleLabel.font = .systemFont(ofSize: 21)
            subtitleLabel.shadowColor = .black
            subtitleLabel.shadowOffset = CGSize(width: 1, height: 1)
            subtitleLabel.layer.shadowRadius = 2
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            subtitleLabel.isHidden = true
            view.addSubview(subtitleLabel)

            NSLayoutConstraint.activate([
                subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                subtitleLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -50),
                subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            ])

            observeSubtitle()
        }

        private func observeSubtitle() {
            observe { [weak self] in
                guard let self else { return }
                let text = self.proxy.subtitlePresentation.currentText
                Task { @MainActor in
                    self.subtitleLabel.isHidden = text.isEmpty
                    self.subtitleLabel.text = text
                }
            }
        }
    }
}
