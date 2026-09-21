//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Foundation

// MARK: - URL scheme helpers

extension URL {

    /// Routes HLS loading through our `AVAssetResourceLoaderDelegate` by swapping the scheme
    /// to a non-native one (e.g. `https` -> `sf-https`). AVFoundation only natively handles
    /// a handful of schemes, so anything else is handed to the resource loader delegate.
    var hlsInterceptURL: URL? {
        guard let scheme else { return nil }
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.scheme = "sf-\(scheme)"
        return components?.url
    }

    /// Reverse of `hlsInterceptURL`.
    var hlsRealURL: URL? {
        guard let scheme, scheme.hasPrefix("sf-") else { return nil }
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        components?.scheme = String(scheme.dropFirst(3))
        return components?.url
    }
}

// MARK: - Workaround for server-side HLS subtitle offset bug

/// Temporary client-side workaround for Jellyfin server issue #16647 (fixed server-side in v13.0 / PR #17299).
///
/// When HLS subtitles are delivered over fMP4 segments, the server hardcodes
/// `X-TIMESTAMP-MAP=MPEGTS:900000` (a 10s offset that is only correct for MPEG-TS segments),
/// which delays subtitles by ~10s in `AVPlayer`. The Native player always transcodes to fMP4
/// (`VideoPlayerType+Native.swift`), so the correct offset there is `0`.
///
/// This delegate:
/// - rewrites `MPEGTS:900000` -> `MPEGTS:0` for `.vtt` subtitle segments,
/// - proxies HLS manifests / playlists unchanged (so their child requests stay on the custom
///   scheme and reach this delegate),
/// - redirects heavy media segments (`.mp4`/`.ts`/`.key`/...) back to HTTPS, since they are
///   leaf resources and do not need inspection.
final class HLSWebVTTTimestampMapFixer: NSObject, AVAssetResourceLoaderDelegate {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url,
              url.scheme?.hasPrefix("sf-") == true,
              let realURL = url.hlsRealURL
        else {
            return false
        }

        let isPlaylist = realURL.pathExtension == "m3u8"
        let isWebVTT = realURL.lastPathComponent.contains("stream.vtt") || realURL.pathExtension == "vtt"

        // Leaf media segments: let AVPlayer load them natively via a redirect.
        if !isPlaylist, !isWebVTT {
            let redirectResponse = HTTPURLResponse(
                url: realURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": realURL.absoluteString]
            )
            loadingRequest.redirect = URLRequest(url: realURL)
            loadingRequest.response = redirectResponse
            loadingRequest.finishLoading()
            return true
        }

        Task {
            await self.load(loadingRequest: loadingRequest, realURL: realURL, isWebVTT: isWebVTT)
        }
        return true
    }

    private func load(loadingRequest: AVAssetResourceLoadingRequest, realURL: URL, isWebVTT: Bool) async {
        do {
            let (data, response) = try await session.data(from: realURL)

            if isWebVTT, let string = String(data: data, encoding: .utf8) {
                // Idempotent: a server that already sends `MPEGTS:0` (post-fix) is left untouched.
                let fixed = string.replacingOccurrences(of: "MPEGTS:900000", with: "MPEGTS:0")
                let outData = Data(fixed.utf8)

                loadingRequest.contentInformationRequest?.contentType = "text/vtt"
                loadingRequest.contentInformationRequest?.contentLength = Int64(outData.count)
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
                loadingRequest.dataRequest?.respond(with: outData)
                loadingRequest.finishLoading()
                return
            }

            if let http = response as? HTTPURLResponse {
                loadingRequest.contentInformationRequest?.contentType = http.mimeType
                loadingRequest.contentInformationRequest?.contentLength = http.expectedContentLength
                loadingRequest.contentInformationRequest?.isByteRangeAccessSupported =
                    http.allHeaderFields["Accept-Ranges"] != nil
            }

            loadingRequest.dataRequest?.respond(with: data)
            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
    }
}
