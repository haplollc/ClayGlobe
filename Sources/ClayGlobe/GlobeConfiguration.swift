import Foundation

/// Everything an app can tune without touching the scene.
public struct GlobeConfiguration: Sendable, Equatable {
    /// Freezes the idle spin and skips the flag-planting camera tour, so the
    /// globe sits perfectly still. Useful for marketing captures and for
    /// honoring Reduce Motion.
    public var holdsStill: Bool

    /// Show U.S. states as their own pieces when the USA is visited.
    public var showsUSStates: Bool

    public init(holdsStill: Bool = false, showsUSStates: Bool = true) {
        self.holdsStill = holdsStill
        self.showsUSStates = showsUSStates
    }
}
