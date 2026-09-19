//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging

/// Intercepts VTT subtitle responses and fixes the `X-TIMESTAMP-MAP` line.
///
/// The Jellyfin server hardcodes `MPEGTS:900000` in VTT files, which may
/// not match the actual video segment PTS, causing subtitle timing offset.
///
/// This interceptor removes the `X-TIMESTAMP-MAP` line so AVPlayer uses
/// the VTT timestamps directly (which the server already adjusts to the
/// video timeline via the `StartPositionTicks`/`EndPositionTicks` params).
///
/// Must be registered early in app lifecycle:
/// `URLProtocol.registerClass(VTTResponseInterceptor.self)`
final class VTTResponseInterceptor: URLProtocol {

    private static let logger = Logger.swiftfin()
    private static let marker = "vtt-intercepted"

    private var dataTask: URLSessionDataTask?

    // MARK: - URLProtocol Overrides

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: marker, in: request) == nil else {
            return false
        }
        guard let url = request.url,
              url.path.hasSuffix("stream.vtt") || url.path.hasSuffix(".vtt")
        else {
            return false
        }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        super.requestIsCacheEquivalent(a, to: b)
    }

    override func startLoading() {
        let originalRequest = self.request
        guard originalRequest.url != nil else {
            client?.urlProtocol(self, didFailWithError: NSError(
                domain: "VTTResponseInterceptor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No URL in request"]
            ))
            return
        }

        var mutableRequest = originalRequest
        URLProtocol.setProperty(true, forKey: Self.marker, in: mutableRequest)

        dataTask = URLSession.shared.dataTask(with: mutableRequest) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse,
                  let data
            else {
                self.client?.urlProtocol(self, didFailWithError: NSError(
                    domain: "VTTResponseInterceptor",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No response data"]
                ))
                return
            }

            let contentType = httpResponse.allHeaderFields["Content-Type"] as? String ?? ""
            let isVTT = contentType.contains("text/vtt") || data.starts(with: "WEBVTT".utf8)

            if isVTT, var content = String(data: data, encoding: .utf8) {
                let original = content
                content = self.fixTimestampMap(content)

                if content != original {
                    Self.logger.info("Fixed X-TIMESTAMP-MAP in VTT response")
                    let newData = Data(content.utf8)
                    self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: newData)
                    self.client?.urlProtocolDidFinishLoading(self)
                    return
                }
            }

            self.client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        dataTask?.resume()
    }

    override func stopLoading() {
        dataTask?.cancel()
        dataTask = nil
    }

    // MARK: - Private

    /// Removes the `X-TIMESTAMP-MAP` line from VTT content.
    ///
    /// The server hardcodes `MPEGTS:900000` which may not match the video
    /// segment PTS. The VTT timestamps are already adjusted by the server
    /// (via `StartPositionTicks`/`EndPositionTicks`), so removing this
    /// line lets AVPlayer use them directly.
    private func fixTimestampMap(_ content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        lines.removeAll { line in
            line.trimmingCharacters(in: .whitespaces)
                .uppercased()
                .hasPrefix("X-TIMESTAMP-MAP")
        }
        return lines.joined(separator: "\n")
    }
}
