import SwiftUI

/// The globe. Drop it in a ZStack, give it a manager, done.
///
///     ZStack {
///         GlobeNightSky()          // optional starfield backdrop
///         ClayGlobeView(manager: globe)
///     }
///
/// The globe spins gently until grabbed, orbits with a drag, squishes on tap,
/// and plants a flag with a little tour whenever `manager.plant` runs.
public struct ClayGlobeView: View {
    @ObservedObject private var manager: GlobeManager

    public init(manager: GlobeManager) {
        self.manager = manager
    }

    public var body: some View {
        ClayGlobeSceneView(
            configuration: manager.configuration,
            visited: manager.visited,
            visitedStates: manager.configuration.showsUSStates ? manager.visitedStates : [],
            style: manager.style
        )
    }
}

/// The deep-indigo night the globe floats in. Optional, but it is the look.
public struct GlobeNightSky: View {
    public init() {}
    public var body: some View { NightSkyView().ignoresSafeArea() }
}

/// A burst of waving emoji flags for freshly planted countries. Drive it from
/// `GlobeManager`: overlay it on your globe and pass the manager's published
/// celebration state straight through.
///
///     ClayGlobeView(manager: manager)
///         .overlay { GlobeCelebration(manager: manager) }
public struct GlobeCelebration: View {
    @ObservedObject private var manager: GlobeManager

    public init(manager: GlobeManager) {
        self.manager = manager
    }

    public var body: some View {
        FlagConfettiBurst(
            flags: manager.celebrating.compactMap { CountryFlags.flag(forAlpha3: $0) },
            trigger: manager.celebrationTrigger
        )
        .allowsHitTesting(false)
    }
}

public extension GlobeManager {
    /// The emoji flag for an ISO alpha-3 code, e.g. "JPN" gives the Japanese flag.
    nonisolated static func flagEmoji(for code: String) -> String? {
        CountryFlags.flag(forAlpha3: code)
    }
}
