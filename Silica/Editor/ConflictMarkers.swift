import Foundation

/// The conflicts git leaves in a file it couldn't merge: between "<<<<<<<" and
/// "=======" the text as it is on the current branch, then to ">>>>>>>" the
/// text coming in.
nonisolated enum ConflictMarkers {
    struct Region: Sendable, Equatable {
        /// The whole conflict, from the first marker's line to the end of the
        /// last marker's, line ending included.
        var whole: NSRange
        /// The lines of each side, with their line endings.
        var current: NSRange
        var incoming: NSRange
    }

    enum Choice: Sendable {
        case current, incoming, both
    }

    static func regions(in text: NSString) -> [Region] {
        var regions: [Region] = []
        // Where the conflict being read began, where its current side ends (at a
        // "|||||||" line of the common ancestor, if the file has those, or at the
        // separator), and where its incoming side begins.
        var start: Int?
        var currentEnd: Int?
        var incomingStart: Int?
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(line) }
            func begins(_ marker: String) -> Bool {
                line.length >= marker.count && text.substring(with: NSRange(location: line.location, length: marker.count)) == marker
            }
            if begins("<<<<<<<") {
                start = line.location
                currentEnd = nil
                incomingStart = nil
            } else if start != nil, begins("|||||||"), incomingStart == nil {
                if currentEnd == nil { currentEnd = line.location }
            } else if start != nil, begins("======="), incomingStart == nil {
                if currentEnd == nil { currentEnd = line.location }
                incomingStart = NSMaxRange(line)
            } else if let begun = start, let currentEnd, let incomingStart, begins(">>>>>>>") {
                let currentStart = NSMaxRange(text.lineRange(for: NSRange(location: begun, length: 0)))
                regions.append(Region(
                    whole: NSRange(location: begun, length: NSMaxRange(line) - begun),
                    current: NSRange(location: currentStart, length: currentEnd - currentStart),
                    incoming: NSRange(location: incomingStart, length: line.location - incomingStart)
                ))
                start = nil
            }
        }
        return regions
    }

    /// What takes the conflict's place.
    static func resolution(of region: Region, in text: NSString, taking choice: Choice) -> String {
        switch choice {
        case .current: text.substring(with: region.current)
        case .incoming: text.substring(with: region.incoming)
        case .both: text.substring(with: region.current) + text.substring(with: region.incoming)
        }
    }
}
