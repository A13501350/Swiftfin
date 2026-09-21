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
/// to route subtitle/trickplay requests through a custom scheme, enabling
/// `X-TIMESTAMP-MAP` fix in VTT responses.
///
/// The Jellyfin server hardcodes `MPEGTS:900000` in `X-TIMESTAMP-MAP`
/// for VTT subtitle files from transmuxed streams (e.g., MKV → HLS).
/// This value is incorrect for fMP4 segments (should be 0), causing
/// subtitle timing offset.
///
/// This interceptor only rewrites subtitle/trickplay URIs in the master
/// manifest to use a custom scheme. VTT files fetched via that scheme
/// have their `X-TIMESTAMP-MAP` line fixed in the proxy response.
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

// MARK: - AVAssetResourceLoaderDelegate

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
            await proxyRequest(request)
        }
    }

    private func proxyRequest(_ request: AVAssetResourceLoadingRequest) async {
        let requestURL = request.request.url ?? URL(string: "nil")!
        let originalURL = self.originalURL(for: requestURL)

        do {
            var urlRequest = URLRequest(url: originalURL)
            urlRequest.httpMethod = request.request.httpMethod ?? "GET"

            if let allHeaders = request.request.allHTTPHeaderFields {
                for (key, value) in allHeaders {
                    urlRequest.setValue(value, forHTTPHeaderField: key)
                }
            }

            var (data, response) = try await URLSession.shared.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                throw NSError(
                    domain: "HLSManifestInterceptor",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Proxy failed: \(response)"]
                )
            }

            if originalURL.path.hasSuffix(".vtt"),
               var content = String(data: data, encoding: .utf8),
               content.contains("X-TIMESTAMP-MAP")
            {
                let original = content
                content = content.replacing(Self.timestampMapPattern) { match in
                    match.output.replacing(/MPEGTS:\d+/, with: "MPEGTS:0")
                }
                logger.info("Fixed X-TIMESTAMP-MAP in VTT: \(original.prefix(120)) → \(content.prefix(120))")
                data = Data(content.utf8)
            }

            if let infoRequest = request.contentInformationRequest {
                if originalURL.path.hasSuffix(".mp4") || originalURL.path.hasSuffix(".cmfv") || originalURL.path.hasSuffix(".cmfa") {
                    infoRequest.contentType = "public.mpeg-4"
                } else if originalURL.path.hasSuffix(".m4s") {
                    infoRequest.contentType = "public.mpeg-4-segment"
                } else if originalURL.path.hasSuffix(".vtt") {
                    infoRequest.contentType = "text/vtt"
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

        if content.contains("#EXT-X-STREAM-INF") {
            content = rewriteMasterManifest(content)
        }

        let preview = String(content.prefix(500))
        logger.info("HLS manifest returned to player:\n\(preview)")

        return Data(content.utf8)
    }

    /// Rewrites the master manifest:
    /// - Subtitle/trickplay URIs → custom scheme (for X-TIMESTAMP-MAP fixing)
    /// - Variant playlist URLs → absolute HTTP (for direct AVPlayer fetching)
    private func rewriteMasterManifest(_ content: String) -> String {
        let originalComponents = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)!
        var basePath = (originalComponents.path as NSString).deletingLastPathComponent
        if !basePath.hasSuffix("/") {
            basePath.append("/")
        }
        var baseURLComponents = originalComponents
        baseURLComponents.path = basePath
        baseURLComponents.query = nil
        let baseURL = baseURLComponents.url!
        let originalQueryItems = originalComponents.queryItems ?? []

        var lines = content.components(separatedBy: .newlines)
        var i = lines.startIndex

        while i < lines.endIndex {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXT-X-MEDIA:") && line.contains("URI=\"") {
                lines[i] = rewriteURIAttribute(
                    in: line,
                    baseURL: baseURL,
                    appendQueryItems: originalQueryItems,
                    targetScheme: Self.scheme
                )
            } else if line.hasPrefix("#EXT-X-IMAGE-STREAM-INF:") && line.contains("URI=\"") {
                lines[i] = rewriteURIAttribute(
                    in: line,
                    baseURL: baseURL,
                    appendQueryItems: originalQueryItems,
                    targetScheme: Self.scheme
                )
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                // Variant playlist URL follows after blank lines
                var searchIndex = lines.index(after: i)
                while searchIndex < lines.endIndex {
                    let nextLine = lines[searchIndex].trimmingCharacters(in: .whitespaces)
                    if nextLine.isEmpty {
                        searchIndex = lines.index(after: searchIndex)
                        continue
                    }
                    if !nextLine.hasPrefix("#") {
                        // Rewrite to absolute HTTP so AVPlayer fetches directly
                        if let resolved = URL(string: nextLine, relativeTo: baseURL) {
                            let absolute = resolved.absoluteURL
                            if absolute.scheme != Self.scheme {
                                let resolvedComponents = URLComponents(url: absolute, resolvingAgainstBaseURL: false)!
                                let existingParamNames = Set((resolvedComponents.queryItems ?? []).compactMap(\.name))
                                let newParams = originalQueryItems.filter { !existingParamNames.contains($0.name) }
                                var mergedComponents = resolvedComponents
                                if !newParams.isEmpty {
                                    mergedComponents.queryItems = (resolvedComponents.queryItems ?? []) + newParams
                                }
                                if let rewritten = mergedComponents.url {
                                    lines[searchIndex] = rewritten.absoluteString
                                }
                            }
                        }
                    }
                    break
                }
            }

            i = lines.index(after: i)
        }

        return lines.joined(separator: "\n")
    }

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
