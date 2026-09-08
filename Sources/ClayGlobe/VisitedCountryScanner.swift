import Foundation
import Photos
import CoreLocation

/// Discovers which countries someone has been to from the photos they already
/// have. Reads `PHAsset` location metadata only: no image data is loaded,
/// nothing leaves the device, and a library of thousands scans in seconds.
public enum VisitedCountryScanner {

    public struct Findings: Sendable {
        public let countries: Set<String>          // ISO alpha-3
        public let states: Set<String>             // USPS, when inside the USA
        public let firstVisits: [String: Date]     // earliest photo per country
    }

    /// Prompts for photo access when undetermined. Photos has no read-only
    /// level, so this asks for `.readWrite`; limited selections work too.
    public static func requestAccess() async -> Bool {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return true
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited
        default: return false
        }
    }

    /// Walks every geotagged photo, resolves each coordinate to a country
    /// (and a U.S. state) with the bundled offline map, and keeps the earliest
    /// photo date per country as the first visit.
    public static func scan() async -> Findings {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
            let assets = PHAsset.fetchAssets(with: .image, options: options)

            var countries = Set<String>()
            var states = Set<String>()
            var firstVisits: [String: Date] = [:]
            let atlas = CountryAtlas.shared

            assets.enumerateObjects { asset, _, _ in
                guard let coordinate = asset.location?.coordinate else { return }
                guard let code = atlas.countryCode(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude) else { return }
                if countries.insert(code).inserted, let date = asset.creationDate {
                    firstVisits[code] = date   // ascending sort: first hit is earliest
                }
                if code == "USA",
                   let state = atlas.stateCode(latitude: coordinate.latitude,
                                               longitude: coordinate.longitude) {
                    states.insert(state)
                }
            }
            return Findings(countries: countries, states: states, firstVisits: firstVisits)
        }.value
    }
}
