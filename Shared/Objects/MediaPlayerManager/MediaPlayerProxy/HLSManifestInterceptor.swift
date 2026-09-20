//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import AVFoundation
import Foundation
import JellyfinAPI
import Logging

/// Intercepts HLS manifest requests via `AVAssetResourceLoaderDelegate`
/// to fix the `X-TIMESTAMP-MAP` line before AVPlayer parses the manifest.
///
/// The Jellyfin server hardcodes `MPEGTS:900000` in `X-TIMESTAMP-MAP`
/// for transmuxed streams (e.g., MKV → HLS), which is incorrect for
/// fMP4 segments (should be 0). This causes subtitle timing offset.
///
/// Usage: wrap the HLS URL with `interceptedURL()` and create an
/// `AVURLAsset` from the result. The interceptor must be retained
/// for the lifetime of the asset.
final class HLSManifestInterceptor: NSObject, Sendable {

    private static let scheme = "jellyfin-hls"

    private let logger = Logger.swiftfin()
    private let originalURL: URL
    private let client: JellyfinClient

    private static let timestampMapPattern = /X-TIMESTAMP-MAP=.*/

    init(url: URL, client: JellyfinClient) {
        self.originalURL = url
        self.client = client
    }

    /// Returns a URL with a custom scheme that triggers
    /// `AVAssetResourceLoaderDelegate` callbacks.
    func interceptedURL() -> URL {
        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)!
        components.scheme = Self.scheme
        return components.url!
    }

    /// Creates an `AVURLAsset` configured with this interceptor.
    func makeAsset() -> AVURLAsset {
        let urlAsset = AVURLAsset(url: interceptedURL())
        urlAsset.resourceLoader.setDelegate(self, queue: .global(qos: .userInitiated))
        return urlAsset
    }
}

extension HLSManifestInterceptor: AVAssetResourceLoaderDelegate {

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let url = loadingRequest.request.url?.absoluteString ?? "nil"
        logger.info("HLS intercept requested: \(url)")
        Task {
            await handleLoadingRequest(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        loadingRequest.finishLoading(with: NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: nil
        ))
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForRenewalOfRequestedResource renewalRequest: AVAssetResourceRenewalRequest
    ) -> Bool {
        return false
    }

    // MARK: - Private

    private func handleLoadingRequest(_ request: AVAssetResourceLoadingRequest) async {
        let requestURL = request.request.url ?? URL(string: "nil")!
        let path = requestURL.path.lowercased()

        // Only intercept .m3u8 manifest files — proxy everything else directly
        if path.hasSuffix(".m3u8") {
            do {
                let originalURL = self.originalURL(for: requestURL)
                let data = try await fetchAndFixManifest(from: originalURL)

                if let infoRequest = request.contentInformationRequest {
                    infoRequest.contentType = "public.m3u-playlist"
                    infoRequest.contentLength = Int64(data.count)
                    infoRequest.isByteRangeAccessSupported = false
                }

                logger.info("HLS intercept responding \(data.count) bytes for: \(requestURL.absoluteString)")
                request.dataRequest?.respond(with: data)
                request.finishLoading()
            } catch {
                logger.error("HLS intercept failed for \(requestURL.absoluteString): \(error.localizedDescription)")
                request.finishLoading(with: error)
            }
        } else {
            // Proxy non-manifest requests (.mp4, etc.) directly
            await proxyRequest(request)
        }
    }

    /// Proxies a non-manifest request directly to the server.
    private func proxyRequest(_ request: AVAssetResourceLoadingRequest) async {
        let requestURL = request.request.url ?? URL(string: "nil")!
        let originalURL = self.originalURL(for: requestURL)

        do {
            var urlRequest = URLRequest(url: originalURL)
            urlRequest.httpMethod = request.request.httpMethod ?? "GET"

            // Forward headers from the original request
            if let allHeaders = request.request.allHTTPHeaderFields {
                for (key, value) in allHeaders {
                    urlRequest.setValue(value, forHTTPHeaderField: key)
                }
            }

            let (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw NSError(
                    domain: "HLSManifestInterceptor",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Proxy failed: \(response)"]
                )
            }

            if let infoRequest = request.contentInformationRequest {
                // Set content type based on file extension
                if originalURL.path.hasSuffix(".mp4") || originalURL.path.hasSuffix(".cmfv") || originalURL.path.hasSuffix(".cmfa") {
                    infoRequest.contentType = "public.mpeg-4"
                } else if originalURL.path.hasSuffix(".m4s") {
                    infoRequest.contentType = "public.mpeg-4-segment"
                } else {
                    infoRequest.contentType = "public.data"
                }
                infoRequest.contentLength = Int64(data.count)
                infoRequest.isByteRangeAccessSupported = true
            }

            request.dataRequest?.respond(with: data)
            request.finishLoading()
        } catch {
            logger.error("Proxy failed for \(requestURL.absoluteString): \(error.localizedDescription)")
            request.finishLoading(with: error)
        }
    }

    /// Reconstructs the original URL from a custom-scheme request URL.
    private func originalURL(for requestURL: URL) -> URL {
        guard requestURL.scheme == Self.scheme else { return requestURL }
        var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)!
        components.scheme = originalURL.scheme
        let result = components.url ?? requestURL
        logger.info("URL mapping: \(requestURL.absoluteString) → \(result.absoluteString)")
        return result
    }

    private func fetchAndFixManifest(from url: URL) async throws -> Data {
        logger.info("Fetching manifest from: \(url.absoluteString)")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw NSError(
                domain: "HLSManifestInterceptor",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch manifest: \(response)"]
            )
        }

        guard var content = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "HLSManifestInterceptor",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Manifest is not valid UTF-8"]
            )
        }

        logger.info("Fetched \(data.count) bytes from server")

        // Fix X-TIMESTAMP-MAP line in all playlist types
        content = fixTimestampMap(content)

        // Only rewrite URLs in master manifests (which contain #EXT-X-STREAM-INF).
        // Variant/subtitle playlists contain #EXT-X-MAP with binary init segments
        // (.mp4) that must NOT be intercepted.
        if content.contains("#EXT-X-STREAM-INF") {
            content = rewriteVariantURLs(content)
        }

        let preview = String(content.prefix(500))
        logger.info("HLS manifest returned to player:\n\(preview)")

        return Data(content.utf8)
    }

    /// Fixes the `X-TIMESTAMP-MAP` line by setting MPEGTS to 0.
    ///
    /// Before (broken): `X-TIMESTAMP-MAP=LOCAL:0x0000,MPEGTS:900000`
    /// After (fixed):   `X-TIMESTAMP-MAP=LOCAL:0x0000,MPEGTS:0`
    private func fixTimestampMap(_ content: String) -> String {
        content.replacing(Self.timestampMapPattern) { match in
            if match.output.contains("MPEGTS:0") {
                return match.output
            }
            let fixed = match.output.replacing(/MPEGTS:\d+/, with: "MPEGTS:0")
            logger.info("Fixed X-TIMESTAMP-MAP: \(match.output) → \(fixed)")
            return fixed
        }
    }

    /// Rewrites URLs in master manifest:
    /// - Subtitle/trickplay URIs → custom scheme (for X-TIMESTAMP-MAP fixing)
    /// - Variant playlist URLs → absolute HTTP (so AVPlayer fetches directly,
    ///   not through this interceptor, avoiding proxy overhead on .mp4 segments)
    private func rewriteVariantURLs(_ content: String) -> String {
        var lines = content.components(separatedBy: .newlines)
        var inMaster = false

        // Compute base directory for resolving relative URLs
        let originalComponents = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)!
        var basePath = (originalComponents.path as NSString).deletingLastPathComponent
        if !basePath.hasSuffix("/") {
            basePath.append("/")
        }
        var baseURLComponents = originalComponents
        baseURLComponents.path = basePath
        baseURLComponents.query = nil
        let baseURL = baseURLComponents.url!

        logger.info("Base URL for relative resolution: \(baseURL.absoluteString)")

        // Query parameters from the original master manifest URL to preserve
        let originalQueryItems = originalComponents.queryItems ?? []

        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTM3U") {
                inMaster = true
            }

            guard inMaster else {
                i = lines.index(after: i)
                continue
            }

            // Rewrite #EXT-X-MEDIA subtitle playlist URIs → custom scheme
            if line.hasPrefix("#EXT-X-MEDIA:") && line.contains("URI=\"") {
                lines[i] = rewriteURIAttribute(
                    in: line,
                    baseURL: baseURL,
                    appendQueryItems: originalQueryItems,
                    targetScheme: Self.scheme
                )
                i = lines.index(after: i)
                continue
            }

            // Rewrite #EXT-X-IMAGE-STREAM-INF trickplay URI → custom scheme
            if line.hasPrefix("#EXT-X-IMAGE-STREAM-INF:") && line.contains("URI=\"") {
                lines[i] = rewriteURIAttribute(
                    in: line,
                    baseURL: baseURL,
                    appendQueryItems: originalQueryItems,
                    targetScheme: Self.scheme
                )
                i = lines.index(after: i)
                continue
            }

            // Rewrite variant playlist URL (line after #EXT-X-STREAM-INF) → absolute HTTP
            // This is critical: if left as relative, AVPlayer resolves against
            // the custom scheme base URL, routing ALL segment requests through
            // the interceptor proxy, which adds latency and breaks streaming.
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let nextIndex = lines.index(after: i)
                if nextIndex < lines.endIndex {
                    let nextLine = lines[nextIndex].trimmingCharacters(in: .whitespaces)
                    if !nextLine.hasPrefix("#") && !nextLine.isEmpty {
                        // Resolve relative URL to absolute HTTP (not custom scheme)
                        if let resolved = URL(string: nextLine, relativeTo: baseURL),
                           let absolute = try? resolved.absoluteURL,
                           absolute.scheme != Self.scheme
                        {
                            // Preserve original query params
                            let resolvedComponents = URLComponents(url: absolute, resolvingAgainstBaseURL: false)!
                            let existingParamNames = Set((resolvedComponents.queryItems ?? []).compactMap(\.name))
                            let newParams = originalQueryItems.filter { !existingParamNames.contains($0.name) }
                            var mergedComponents = resolvedComponents
                            if !newParams.isEmpty {
                                mergedComponents.queryItems = (resolvedComponents.queryItems ?? []) + newParams
                            }
                            if let rewritten = mergedComponents.url {
                                logger.info("Variant playlist URL: \(nextLine) → \(rewritten.absoluteString)")
                                lines[nextIndex] = rewritten.absoluteString
                            }
                        }
                    }
                }
                i = lines.index(after: i)
                continue
            }

            i = lines.index(after: i)
        }

        return lines.joined(separator: "\n")
    }

    /// Rewrites URI="..." attribute value to use the specified scheme.
    private func rewriteURIAttribute(
        in line: String,
        baseURL: URL,
        appendQueryItems: [URLQueryItem],
        targetScheme: String
    ) -> String {
        guard let uriRange = line.range(of: "URI=\"") else { return line }
        let afterURI = line[uriRange.upperBound...]
        guard let endQuote = afterURI.firstIndex(of: "\"") else { return line }

        let uriValue = String(afterURI[afterURI.startIndex..<endQuote])
        guard let resolved = URL(string: uriValue, relativeTo: baseURL) else { return line }
        let absolute = resolved.absoluteURL

        // Merge query parameters: only append those not already present
        let resolvedComponents = URLComponents(url: absolute, resolvingAgainstBaseURL: false)!
        let existingParamNames = Set((resolvedComponents.queryItems ?? []).compactMap(\.name))
        let newParams = appendQueryItems.filter { !existingParamNames.contains($0.name) }
        var mergedComponents = resolvedComponents
        if !newParams.isEmpty {
            mergedComponents.queryItems = (resolvedComponents.queryItems ?? []) + newParams
        }
        mergedComponents.scheme = targetScheme
        guard let rewritten = mergedComponents.url else { return line }

        return String(line[line.startIndex..<uriRange.lowerBound])
            + "URI=\"\(rewritten.absoluteString)\""
            + String(line[line.index(after: endQuote)...])
    }
}
