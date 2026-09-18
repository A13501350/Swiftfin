//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
@preconcurrency import JellyfinAPI
import Observation

/// Manages external VTT subtitle presentation for the native AVPlayer proxy.
/// Fetches subtitle files via REST API delivery URL, parses them,
/// and provides the current cue based on playback time.
@MainActor
@Observable
final class AVPlayerSubtitlePresentation {

    private(set) var currentText: String = ""

    @ObservationIgnored
    private var cues: [WebVTTCue] = []

    /// Load an external subtitle stream by fetching its VTT content from the delivery URL.
    func load(subtitleStream: MediaStream, client: JellyfinClient) {
        clear()

        guard let streamIndex = subtitleStream.index else { return }
        guard let deliveryURL = subtitleStream.deliveryURL else { return }

        // Build the direct URL to the VTT subtitle file
        let fullPath = deliveryURL.removingFirst(
            if: client.configuration.url.absoluteString.hasSuffix("/")
        )
        guard let url = client.url(path: fullPath) else { return }

        let logger = Logger.swiftfin()

        // Build authenticated request with Jellyfin authorization header
        var request = URLRequest(url: url)
        if let accessToken = client.configuration.accessToken {
            let config = client.configuration
            let authHeader = "MediaBrowser Token=\"\(accessToken)\", Client=\"\(config.client)\", Device=\"\(config.deviceName)\", DeviceId=\"\(config.deviceID)\", Version=\"\(config.version)\""
            request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        }

        Task { [weak self] in
            guard let self else { return }

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let content = String(data: data, encoding: .utf8) else {
                    logger.warning("Failed to decode VTT content for stream index \(streamIndex)")
                    return
                }

                let parsedCues = WebVTTParser.parse(content)
                logger.info("Loaded \(parsedCues.count) VTT cues for stream index \(streamIndex)")

                self.cues = parsedCues
            } catch {
                logger.error("Failed to fetch VTT subtitle: \(error.localizedDescription)")
            }
        }
    }

    /// Update the current subtitle text based on the current playback time.
    func update(for playbackSeconds: TimeInterval) {
        let found = findCue(at: playbackSeconds)
        let newText = found?.text ?? ""

        if newText != currentText {
            currentText = newText
        }
    }

    /// Clear the current subtitle.
    func clear() {
        cues = []
        currentText = ""
    }

    /// Find the cue active at the given time using binary search.
    private func findCue(at time: TimeInterval) -> WebVTTCue? {
        guard !cues.isEmpty else { return nil }

        var low = 0
        var high = cues.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let cue = cues[mid]

            if time < cue.startTime {
                high = mid - 1
            } else if time >= cue.endTime {
                low = mid + 1
            } else {
                return cue
            }
        }

        return nil
    }
}
