//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation
import Logging
import WebVTTParser

struct WebVTTCue: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

enum SubtitleVTTParser {

    private static let logger = Logger.swiftfin()

    static func parse(_ content: String) -> [WebVTTCue] {
        let parser = WebVTTParser()

        do {
            let vtt = try parser.parse(content)
            let cues = vtt.elements.compactMap { element -> WebVTTCue? in
                guard case let .cue(cue) = element else { return nil }

                let startTime = cue.timing.start.interval
                let endTime = cue.timing.end.interval
                let text = flattenPayload(cue.payload)

                guard !text.isEmpty else { return nil }
                return WebVTTCue(startTime: startTime, endTime: endTime, text: text)
            }

            logger.info("Parsed \(cues.count) VTT cues via WebVTTParser library")
            return cues
        } catch {
            logger.error("WebVTTParser library failed: \(error.localizedDescription)")
            return []
        }
    }

    private static func flattenPayload(_ payload: WebVTTParser.WebVTT.CuePayload) -> String {
        payload.components.map { flattenComponent($0) }.joined()
    }

    private static func flattenComponent(_ component: WebVTTParser.WebVTT.CuePayload.Component) -> String {
        switch component {
        case let .plain(text):
            return text
        case let .bold(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .italic(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .underline(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .ruby(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .rubyText(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .class(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .voice(_, _, children):
            return children.map { flattenComponent($0) }.joined()
        case let .timestamp(_, children):
            return children.map { flattenComponent($0) }.joined()
        case let .language(_, _, children):
            return children.map { flattenComponent($0) }.joined()
        @unknown default:
            return ""
        }
    }
}
