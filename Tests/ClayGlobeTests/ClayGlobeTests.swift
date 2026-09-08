import Testing
import Foundation
@testable import ClayGlobe

@Suite("Country atlas")
struct AtlasTests {
    @Test("Coordinates resolve to countries, offline")
    func pointInCountry() {
        let atlas = CountryAtlas.shared
        #expect(atlas.countryCode(latitude: 35.68, longitude: 139.69) == "JPN")   // Tokyo
        #expect(atlas.countryCode(latitude: 48.86, longitude: 2.35) == "FRA")     // Paris
        #expect(atlas.countryCode(latitude: 40.71, longitude: -74.00) == "USA")   // NYC
        #expect(atlas.countryCode(latitude: 0, longitude: -140) == nil)           // Pacific
    }

    @Test("US coordinates resolve to states")
    func pointInState() {
        let atlas = CountryAtlas.shared
        #expect(atlas.stateCode(latitude: 45.52, longitude: -122.68) == "OR")     // Portland
        #expect(atlas.stateCode(latitude: 30.27, longitude: -97.74) == "TX")      // Austin
    }

    @Test("The map ships with the world on it")
    func worldLoaded() {
        #expect(CountryAtlas.shared.countries.count > 150)
        #expect(CountryAtlas.shared.country(code: "JPN")?.name.isEmpty == false)
    }

    @Test("Every country has somewhere to plant a flag")
    func flagSites() {
        let atlas = CountryAtlas.shared
        for code in ["JPN", "FRA", "BRA", "USA", "IDN"] {   // incl. archipelagos
            #expect(atlas.flagSite(forAlpha3: code) != nil, "no site for \(code)")
        }
    }
}

@Suite("Globe manager")
@MainActor
struct ManagerTests {
    @Test("Planting new countries celebrates exactly the new ones")
    func plantCelebrates() {
        let manager = GlobeManager(visited: ["FRA"])
        manager.plant(["FRA", "JPN", "BRA"])
        #expect(manager.visited == ["FRA", "JPN", "BRA"])
        #expect(manager.celebrating == ["JPN", "BRA"])
        #expect(manager.celebrationTrigger == 1)
    }

    @Test("Replanting an existing country is a no-op, not a re-celebration")
    func replantIsQuiet() {
        let manager = GlobeManager(visited: ["JPN"])
        manager.plant("JPN")
        #expect(manager.celebrationTrigger == 0)
    }

    @Test("Static lookups work without a manager instance")
    func lookups() {
        #expect(GlobeManager.countryCode(latitude: -33.87, longitude: 151.21) == "AUS")
        #expect(GlobeManager.allCountryCodes.count > 150)
    }
}
