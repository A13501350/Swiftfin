//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// A minimal WebVTT parser for external subtitle sidecar files.
/// Parses timestamp cues from VTT content without depending on MPVUI.
struct WebVTTCue: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct WebVTTParser: Sendable {

    private static let logger = Logger.swiftfin()

    /// Parse WebVTT content into an array of timestamped cues.
    static func parse(_ content: String) -> [WebVTTCue] {
        var cues: [WebVTTCue] = []
        // Normalize line endings: split on any newline, then strip \r
        let rawLines = content.components(separatedBy: .newlines)
        let lines = rawLines.map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }

        var i = 0

        // Skip the WEBVTT header and any preceding blank lines / NOTE blocks
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("WEBVTT") || line.isEmpty || line.hasPrefix("NOTE") {
                i += 1
                // Skip NOTE block (until next empty line)
                if line.hasPrefix("NOTE") {
                    while i < lines.count && !lines[i].isEmpty {
                        i += 1
                    }
                }
                continue
            }
            break
        }

        logger.debug("Header skip done, i=\(i), total lines=\(lines.count)")

        // Parse cue blocks
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if line.isEmpty {
                i += 1
                continue
            }

            // Skip cue identifiers (lines that don't contain -->)
            if !line.contains("-->") {
                i += 1
                continue
            }

            // Parse timestamp line
            guard let cue = parseCueBlock(timestampLine: line, lines: lines, index: &i) else {
                continue
            }

            cues.append(cue)
        }

        return cues
    }

    private static func parseCueBlock(
        timestampLine: String,
        lines: [String],
        index: inout Int
    ) -> WebVTTCue? {
        let parts = timestampLine.components(separatedBy: "-->")
        guard parts.count == 2 else {
            logger.warning("Cue block has no '-->' separator: \(timestampLine)")
            index += 1
            return nil
        }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .first ?? ""

        guard let startTime = parseTimestamp(startStr),
              let endTime = parseTimestamp(endStr)
        else {
            logger.warning("Failed to parse timestamps: start='\(startStr)' end='\(endStr)'")
            index += 1
            return nil
        }

        index += 1

        // Collect cue text (lines until empty line or end of file)
        var textLines: [String] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                break
            }
            textLines.append(line)
            index += 1
        }

        let text = textLines.joined(separator: "\n")
        guard !text.isEmpty else { return nil }

        logger.debug("Parsed cue: \(startTime)s -> \(endTime)s, text=\(text.prefix(50))")
        return WebVTTCue(startTime: startTime, endTime: endTime, text: text)
    }

    /// Parse a VTT timestamp string like "00:01:23.456" or "01:23.456" or "1:23:45.678" into seconds.
    private static func parseTimestamp(_ string: String) -> TimeInterval? {
        let components = string.split(separator: ":")
        guard !components.isEmpty else {
            logger.warning("Empty timestamp string")
            return nil
        }

        var hours: Double = 0
        var minutes: Double = 0
        var seconds: Double = 0

        switch components.count {
        case 3:
            hours = Double(components[0]) ?? 0
            minutes = Double(components[1]) ?? 0
            seconds = Double(components[2]) ?? 0
        case 2:
            minutes = Double(components[0]) ?? 0
            seconds = Double(components[1]) ?? 0
        case 1:
            seconds = Double(components[0]) ?? 0
        default:
            logger.warning("Unexpected timestamp components count \(components.count): \(string)")
            return nil
        }

        return hours * 3600 + minutes * 60 + seconds
    }
}
