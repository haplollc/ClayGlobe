import SwiftUI
import Photos

/// The view model. Owns what the globe shows and how new countries arrive.
///
/// Plug in with two lines:
///
///     @StateObject private var globe = GlobeManager()
///     ClayGlobeView(manager: globe)
///
/// then call `plant("JPN")` (ISO alpha-3) when your user visits somewhere, or
/// `scanPhotoLibrary()` to discover their whole travel history from photo
/// metadata: on device, metadata only, no image ever loaded.
@MainActor
public final class GlobeManager: ObservableObject {

    /// ISO alpha-3 codes of visited countries ("JPN", "FRA", "USA").
    @Published public var visited: Set<String>

    /// USPS codes of visited U.S. states, shown when the USA is visited and
    /// the configuration allows states.
    @Published public var visitedStates: Set<String>

    /// How visited countries render: orange clay, flag fill, or planted flags.
    @Published public var style: GlobeStyle

    /// Motion and detail switches. See `GlobeConfiguration`.
    @Published public var configuration: GlobeConfiguration

    /// Countries whose flags should erupt with the next change, set
    /// automatically by `plant` and the scanner.
    @Published public internal(set) var celebrating: Set<String> = []
    /// Increments once per celebration; drive burst animations off it.
    @Published public internal(set) var celebrationTrigger = 0

    public init(visited: Set<String> = [],
                visitedStates: Set<String> = [],
                style: GlobeStyle = .planted,
                configuration: GlobeConfiguration = GlobeConfiguration()) {
        self.visited = visited
        self.visitedStates = visitedStates
        self.style = style
        self.configuration = configuration
    }

    // MARK: - Growing the map

    /// Marks countries visited, with the planting animation and celebration.
    public func plant(_ codes: String...) { plant(Set(codes)) }

    /// Marks a whole set visited at once; only genuinely new countries
    /// celebrate, replants are silently ignored.
    public func plant(_ codes: Set<String>) {
        let fresh = codes.subtracting(visited)
        guard !fresh.isEmpty else { return }
        celebrating = fresh
        celebrationTrigger += 1
        visited.formUnion(fresh)
    }

    /// Removes a country (no ceremony: taking a pin out is not a party).
    public func remove(_ code: String) {
        visited.remove(code)
    }

    // MARK: - Photo scan

    /// What a library scan found.
    public struct ScanResult: Sendable {
        /// Newly discovered countries (not already on the globe).
        public let newCountries: Set<String>
        /// Newly discovered U.S. states.
        public let newStates: Set<String>
        /// First-visit dates per country, from the earliest matching photo.
        public let firstVisits: [String: Date]
    }

    /// Scans photo-library metadata for countries the user has photographed
    /// in, plants the new ones, and returns what was found. Requests photo
    /// access if needed; returns nil when access is denied.
    @discardableResult
    public func scanPhotoLibrary() async -> ScanResult? {
        guard await VisitedCountryScanner.requestAccess() else { return nil }
        let found = await VisitedCountryScanner.scan()
        let newCountries = found.countries.subtracting(visited)
        let newStates = found.states.subtracting(visitedStates)
        visitedStates.formUnion(newStates)
        plant(newCountries)
        return ScanResult(newCountries: newCountries,
                          newStates: newStates,
                          firstVisits: found.firstVisits)
    }

    // MARK: - Lookups

    /// The country containing a coordinate, fully offline. "JPN" for Tokyo.
    public nonisolated static func countryCode(latitude: Double, longitude: Double) -> String? {
        CountryAtlas.shared.countryCode(latitude: latitude, longitude: longitude)
    }

    /// Display name for an alpha-3 code, from the bundled map data.
    public nonisolated static func countryName(for code: String) -> String? {
        CountryAtlas.shared.country(code: code)?.name
    }

    /// Every country on the globe, for pickers and progress counts.
    public nonisolated static var allCountryCodes: [String] {
        CountryAtlas.shared.countries.map(\.code)
    }
}
