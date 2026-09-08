import Foundation

/// How visited countries render on the globe.
public enum GlobeStyle: String, CaseIterable, Identifiable, Sendable {
    /// Visited pieces are orange clay.
    case clay
    /// Visited pieces are filled edge to edge with their flag.
    case flags
    /// Visited pieces turn a brighter green and get a little flag planted in them.
    case planted

    public var id: String { rawValue }

    /// A short human-readable name, ready for a picker.
    public var displayName: String {
        switch self {
        case .clay: return "Orange clay"
        case .flags: return "Flag fill"
        case .planted: return "Planted flags"
        }
    }
}
