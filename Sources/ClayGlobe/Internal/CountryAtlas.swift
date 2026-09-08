import Foundation
import CoreGraphics
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Offline world atlas backing the visited-countries globe. Loads the bundled
/// simplified country boundaries (world.geo.json, Natural Earth-derived,
/// ISO-3166 alpha-3 ids), and provides:
///  - the country list for pickers and editors,
///  - point-in-polygon lookup (photo coordinates → country, fully offline),
///  - an equirectangular texture with visited countries highlighted, which the
///    globe wraps around a sphere.
nonisolated final class CountryAtlas: @unchecked Sendable {

    struct Country: Identifiable {
        let code: String          // ISO-3166 alpha-3 ("JPN")
        let name: String          // "Japan"
        /// All rings (outer + holes), as (lon, lat) pairs. Fill/lookup use
        /// even-odd parity so enclaves (Lesotho) punch through correctly.
        let rings: [[CGPoint]]
        /// Lon/lat bounds of all rings, a cheap pre-filter so point lookups
        /// skip the polygon math for countries nowhere near the point.
        let bbox: CGRect

        var id: String { code }
    }

    /// A U.S. state (plus DC / PR), so the globe can show state-level detail
    /// inside the United States instead of one country-sized blob.
    struct USState: Identifiable {
        let code: String          // USPS 2-letter ("CA")
        let name: String          // "California"
        let rings: [[CGPoint]]
        let bbox: CGRect

        var id: String { code }
    }

    /// Lon/lat bounds of a set of rings.
    private static func boundingBox(of rings: [[CGPoint]]) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for ring in rings {
            for p in ring {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        guard minX <= maxX else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// ISO alpha-3 code the globe renders at state granularity instead of as a
    /// single filled country.
    static let stateDetailCountry = "USA"

    /// ISO alpha-3 codes whose photos should be attributed to a U.S. state row
    /// during a scan: the mainland USA plus territories that world.geo.json
    /// files as their own country but that appear in the state list: Puerto
    /// Rico ("PRI" → the "PR" state).
    static let stateDetailCountries: Set<String> = ["USA", "PRI"]

    static let shared = CountryAtlas()

    let countries: [Country]
    private let countriesByCode: [String: Country]

    let states: [USState]
    private let statesByCode: [String: USState]

    private init() {
        // Accumulate by code: the dataset repeats ids for disputed territories
        // (several "-99" features); merge rings per code and drop non-ISO ids.
        var names: [String: String] = [:]
        var ringsByCode: [String: [[CGPoint]]] = [:]
        if let url = Bundle.module.url(forResource: "world.geo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let features = json["features"] as? [[String: Any]] {
            for feature in features {
                guard let code = feature["id"] as? String,
                      code.count == 3, code.allSatisfy(\.isLetter),
                      let props = feature["properties"] as? [String: Any],
                      let name = props["name"] as? String,
                      let geometry = feature["geometry"] as? [String: Any],
                      let type = geometry["type"] as? String,
                      let coords = geometry["coordinates"] else { continue }

                var rings: [[CGPoint]] = []
                if type == "Polygon", let polygon = coords as? [[[Double]]] {
                    rings.append(contentsOf: polygon.map(Self.ring))
                } else if type == "MultiPolygon", let multi = coords as? [[[[Double]]]] {
                    for polygon in multi {
                        rings.append(contentsOf: polygon.map(Self.ring))
                    }
                }
                guard !rings.isEmpty else { continue }
                names[code] = names[code] ?? name
                ringsByCode[code, default: []].append(contentsOf: rings)
            }
        }
        let loaded = ringsByCode.map { code, rings in
            Country(code: code, name: names[code] ?? code, rings: rings,
                    bbox: Self.boundingBox(of: rings))
        }
        countries = loaded.sorted { $0.name < $1.name }
        countriesByCode = Dictionary(uniqueKeysWithValues: loaded.map { ($0.code, $0) })

        // U.S. states (us-states.geo.json, USPS 2-letter ids incl. DC/PR).
        var stateNames: [String: String] = [:]
        var stateRings: [String: [[CGPoint]]] = [:]
        if let url = Bundle.module.url(forResource: "us-states.geo", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let features = json["features"] as? [[String: Any]] {
            for feature in features {
                guard let code = feature["id"] as? String,
                      code.count == 2, code.allSatisfy(\.isLetter),
                      let props = feature["properties"] as? [String: Any],
                      let name = props["name"] as? String,
                      let geometry = feature["geometry"] as? [String: Any],
                      let type = geometry["type"] as? String,
                      let coords = geometry["coordinates"] else { continue }

                var rings: [[CGPoint]] = []
                if type == "Polygon", let polygon = coords as? [[[Double]]] {
                    rings.append(contentsOf: polygon.map(Self.ring))
                } else if type == "MultiPolygon", let multi = coords as? [[[[Double]]]] {
                    for polygon in multi {
                        rings.append(contentsOf: polygon.map(Self.ring))
                    }
                }
                guard !rings.isEmpty else { continue }
                stateNames[code] = stateNames[code] ?? name
                stateRings[code, default: []].append(contentsOf: rings)
            }
        }
        let loadedStates = stateRings.map { code, rings in
            USState(code: code, name: stateNames[code] ?? code, rings: rings,
                    bbox: Self.boundingBox(of: rings))
        }
        states = loadedStates.sorted { $0.name < $1.name }
        statesByCode = Dictionary(uniqueKeysWithValues: loadedStates.map { ($0.code, $0) })
    }

    private static func ring(_ raw: [[Double]]) -> [CGPoint] {
        raw.compactMap { pair in
            guard pair.count >= 2 else { return nil }
            return CGPoint(x: pair[0], y: pair[1])   // x = lon, y = lat
        }
    }

    func country(code: String) -> Country? {
        countriesByCode[code]
    }

    func name(for code: String) -> String {
        countriesByCode[code]?.name ?? code
    }

    // MARK: - Point-in-polygon

    /// The ISO code containing the coordinate, or nil over oceans/unmapped
    /// territories. Ray-casting over the simplified outer rings is plenty for
    /// "which country was this photo taken in".
    func countryCode(latitude: Double, longitude: Double) -> String? {
        let point = CGPoint(x: longitude, y: latitude)
        for country in countries where country.bbox.contains(point) {
            // Even-odd across every ring, so points inside a hole (an enclave
            // like Lesotho) don't count for the surrounding country.
            var inside = false
            for ring in country.rings where Self.contains(ring: ring, point: point) {
                inside.toggle()
            }
            if inside { return country.code }
        }
        return nil
    }

    /// The USPS code of the U.S. state containing the coordinate, or nil if the
    /// point falls outside every state polygon. Meaningful only for points
    /// already known to be in the U.S. (call after `countryCode == "USA"`).
    func stateCode(latitude: Double, longitude: Double) -> String? {
        let point = CGPoint(x: longitude, y: latitude)
        for state in states where state.bbox.contains(point) {
            var inside = false
            for ring in state.rings where Self.contains(ring: ring, point: point) {
                inside.toggle()
            }
            if inside { return state.code }
        }
        return nil
    }

    func stateName(for code: String) -> String {
        statesByCode[code]?.name ?? code
    }

    /// Cheap bounding box around all U.S. territory (CONUS, Alaska, Hawaii,
    /// Puerto Rico) including a wide coastal margin: a pre-filter before the
    /// polygon math in the photo scan. Foreign points that slip through resolve
    /// to a foreign country and add nothing.
    static func isInUSRegion(latitude: Double, longitude: Double) -> Bool {
        latitude >= 17 && latitude <= 72 && longitude >= -180 && longitude <= -64
    }

    /// The nearest state whose boundary lies within `maxDegrees` of the point,
    /// or nil if none is that close. Lets a photo taken just off a simplified
    /// coastline, on a lake, or on an island (a beach, a boat, Mackinac Island,
    /// Coney Island) still count toward the surrounding state; the simplified
    /// polygons don't cover open water. Distance uses a local equirectangular
    /// metric (longitude scaled by cos(latitude)).
    func nearestStateCode(latitude: Double, longitude: Double, within maxDegrees: Double) -> String? {
        let k = cos(latitude * .pi / 180)
        let px = longitude * k, py = latitude
        var bestCode: String?
        var bestDist = maxDegrees
        // Generous bbox cull (longitude compressed by cos(lat), so inflate
        // wider in x): only states plausibly within range pay for the
        // segment-distance math below.
        let searchBox = CGRect(x: longitude, y: latitude, width: 0, height: 0)
            .insetBy(dx: -maxDegrees * 4, dy: -maxDegrees * 1.5)
        for state in states where state.bbox.intersects(searchBox) {
            for ring in state.rings where ring.count >= 2 {
                for i in 0..<ring.count {
                    let a = ring[i]
                    let b = ring[(i + 1) % ring.count]
                    let d = Self.pointSegmentDistance(px: px, py: py,
                                                      ax: Double(a.x) * k, ay: Double(a.y),
                                                      bx: Double(b.x) * k, by: Double(b.y))
                    if d < bestDist {
                        bestDist = d
                        bestCode = state.code
                    }
                }
            }
        }
        return bestCode
    }

    private static func pointSegmentDistance(px: Double, py: Double,
                                             ax: Double, ay: Double,
                                             bx: Double, by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        if dx == 0 && dy == 0 { return hypot(px - ax, py - ay) }
        var t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
        t = max(0, min(1, t))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    private static func contains(ring: [CGPoint], point: CGPoint) -> Bool {
        guard ring.count > 2 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: - Globe texture

    /// The clay palette. Everything on the ball is matte plasticine: a bright
    /// Play-Doh ocean, green land pieces, orange visited pieces and white polar
    /// clay. Colours are hardcoded rather than read from the asset catalog:
    /// this renders off the main thread, where a dynamic colour resolves to
    /// whatever trait collection happens to be current.
    enum Clay {
        static let ocean = UIColor(red: 0.26, green: 0.56, blue: 0.91, alpha: 1)
        static let land = UIColor(red: 0.46, green: 0.78, blue: 0.34, alpha: 1)
        static let visited = UIColor(red: 1.00, green: 0.45, blue: 0.12, alpha: 1)
        static let snow = UIColor(red: 0.96, green: 0.95, blue: 0.90, alpha: 1)
        /// Visited pieces in the planted-flag style: a brighter, springier
        /// green than the rest, with the flag doing the real pointing.
        static let plantedGreen = UIColor(red: 0.66, green: 0.87, blue: 0.40, alpha: 1)
        /// Pieces rolled from white clay when unvisited: the ice caps.
        static let snowCodes: Set<String> = ["ATA", "GRL"]
    }

    /// Texture pixels a coastline is plumped outward on each side. Thin
    /// peninsulas and specks of islands swell into the chunky shapes a thumb
    /// would press out, instead of staying vector-sharp.
    private static let plumpWidth: CGFloat = 9

    /// A stable per-piece shade, so neighbouring pieces of clay never match
    /// exactly, the way hand-mixed dough never does. Same code, same shade,
    /// every launch.
    private static func clayShade(_ base: UIColor, seed: String) -> CGColor {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        base.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        var x: UInt64 = 1469598103934665603
        for byte in seed.utf8 { x = (x ^ UInt64(byte)) &* 1099511628211 }
        let u1 = Double(x >> 11) / 9007199254740992.0
        let u2 = Double((x &* 0x9E3779B97F4A7C15) >> 11) / 9007199254740992.0
        let hue = (h + CGFloat(u1 - 0.5) * 0.035 + 1).truncatingRemainder(dividingBy: 1)
        let bright = min(1, max(0, b + CGFloat(u2 - 0.5) * 0.13))
        return UIColor(hue: hue, saturation: s, brightness: bright, alpha: 1).cgColor
    }

    /// Memo of the last rendered texture. The render is a few hundred ms at
    /// 4K with the high-res boundary data, so reopening the globe with an
    /// unchanged visited set shouldn't pay it twice.
    private let textureMemoLock = NSLock()
    /// Up to one texture per style, so switching styles is instant.
    private var textureMemo: [String: UIImage] = [:]
    private var textureMemoOrder: [String] = []
    private static let textureMemoLimit = GlobeStyle.allCases.count

    /// Every piece of clay on the ball: its rings, its shade, and whether it
    /// is lit up. U.S. states replace the single USA piece when any are lit.
    private struct Piece {
        let rings: [[CGPoint]]
        let color: CGColor
        let visited: Bool
        /// Set only in the flag-fill style, for lit pieces: the flag that
        /// covers the piece edge to edge.
        let flag: UIImage?
    }

    private func pieces(visited: Set<String>, visitedStates: Set<String>,
                        style: GlobeStyle = .clay) -> [Piece] {
        // Render the U.S. at state granularity only when there are visited
        // states to show: skip the country-sized USA blob and draw its
        // states instead. With no visited states we fall back to the plain
        // USA country fill, so a country-level "USA visited" still lights up
        // (and matches the country counter) instead of leaving the US blank.
        let renderStates = !states.isEmpty && !visitedStates.isEmpty
        var out: [Piece] = []
        /// The clay a lit piece is rolled from, per style. In the flag-fill
        /// style it is plain land green: the flag covers it, and the green
        /// only shows if a flag is missing for the code.
        func litBase() -> UIColor {
            switch style {
            case .clay: return Clay.visited
            case .flags: return Clay.land
            case .planted: return Clay.plantedGreen
            }
        }
        for country in countries {
            if renderStates && country.code == Self.stateDetailCountry { continue }
            let lit = visited.contains(country.code)
            let base = lit ? litBase()
                : (Clay.snowCodes.contains(country.code) ? Clay.snow : Clay.land)
            out.append(Piece(rings: country.rings,
                             color: Self.clayShade(base, seed: country.code), visited: lit,
                             flag: lit && style == .flags ? flagImage(forAlpha3: country.code) : nil))
        }
        if renderStates {
            for state in states {
                let lit = visitedStates.contains(state.code)
                out.append(Piece(rings: state.rings,
                                 color: Self.clayShade(lit ? litBase() : Clay.land,
                                                       seed: "US-" + state.code),
                                 visited: lit,
                                 flag: lit && style == .flags
                                     ? flagImage(forAlpha3: Self.stateDetailCountry) : nil))
            }
        }
        return out
    }

    // MARK: - Flags

    private let flagImageLock = NSLock()
    private var flagImages: [String: UIImage] = [:]

    /// A country's flag emoji rendered to a bitmap and cropped to the glyph,
    /// cached per code. Big enough to stretch across a large country without
    /// its stripes going soft.
    func flagImage(forAlpha3 code: String) -> UIImage? {
        guard let emoji = CountryFlags.flag(forAlpha3: code) else { return nil }
        flagImageLock.lock()
        if let cached = flagImages[code] { flagImageLock.unlock(); return cached }
        flagImageLock.unlock()
        // Apple Color Emoji's largest bitmap strike is 160 px; anything
        // bigger is just that bitmap upscaled, so ask for exactly that.
        guard let image = Self.renderEmoji(emoji, pointSize: 160) else { return nil }
        flagImageLock.lock(); flagImages[code] = image; flagImageLock.unlock()
        return image
    }

    /// Draws an emoji on a transparent canvas and crops away the transparent
    /// margin around the glyph, so callers can fit the flag itself.
    private static func renderEmoji(_ emoji: String, pointSize: CGFloat) -> UIImage? {
        let font = UIFont.systemFont(ofSize: pointSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let text = emoji as NSString
        let size = text.size(withAttributes: attrs)
        guard size.width > 1, size.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1
        let raw = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            text.draw(at: .zero, withAttributes: attrs)
        }
        guard let cg = raw.cgImage else { return raw }
        // Tight alpha bounds.
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return raw }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 24 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY,
              let cropped = cg.cropping(to: CGRect(x: minX, y: minY,
                                                   width: maxX - minX + 1, height: maxY - minY + 1))
        else { return raw }
        return UIImage(cgImage: cropped)
    }

    /// Where to plant a flag in a country: the centroid of its biggest ring,
    /// or a point inside it if the centroid falls outside (crescent shapes).
    func flagSite(forAlpha3 code: String) -> (latitude: Double, longitude: Double)? {
        guard let country = countriesByCode[code] else { return nil }
        var best: (ring: [CGPoint], area: CGFloat)?
        for ring in country.rings {
            let pts = Self.normalized(ring, closePolar: false).points
            let box = Self.boundingBox(of: [pts])
            let area = box.width * box.height
            if best == nil || area > best!.area { best = (pts, area) }
        }
        guard let ring = best?.ring, ring.count > 2 else { return nil }
        var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in 0..<ring.count {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            let cross = p.x * q.y - q.x * p.y
            area += cross
            cx += (p.x + q.x) * cross
            cy += (p.y + q.y) * cross
        }
        var point = abs(area) > 1e-9 ? CGPoint(x: cx / (3 * area), y: cy / (3 * area)) : ring[0]
        if !Self.contains(ring: ring, point: point) {
            // Walk the box's middle row and take the widest run of inside points.
            let box = Self.boundingBox(of: [ring])
            var bestRun: (start: CGFloat, length: CGFloat)?
            var runStart: CGFloat?
            let steps = 60
            for i in 0...steps {
                let x = box.minX + box.width * CGFloat(i) / CGFloat(steps)
                let inside = Self.contains(ring: ring, point: CGPoint(x: x, y: box.midY))
                if inside, runStart == nil { runStart = x }
                if (!inside || i == steps), let start = runStart {
                    let length = x - start
                    if bestRun == nil || length > bestRun!.length { bestRun = (start, length) }
                    runStart = nil
                }
            }
            if let run = bestRun {
                point = CGPoint(x: run.start + run.length / 2, y: box.midY)
            } else {
                point = CGPoint(x: box.midX, y: box.midY)
            }
        }
        var lon = point.x
        while lon > 180 { lon -= 360 }
        while lon < -180 { lon += 360 }
        return (Double(point.y), Double(lon))
    }

    /// Unwrap longitudes so seam-crossing rings stay continuous, and (for
    /// fill) close polar rings (Antarctica) through their pole. Returns
    /// whether the ring wraps the globe so callers can treat the polar
    /// coastline specially.
    private static func normalized(_ ring: [CGPoint], closePolar: Bool) -> (points: [CGPoint], polar: Bool) {
        guard var previous = ring.first?.x else { return (ring, false) }
        var out: [CGPoint] = []
        for point in ring {
            var lon = point.x
            while lon - previous > 180 { lon -= 360 }
            while previous - lon > 180 { lon += 360 }
            out.append(CGPoint(x: lon, y: point.y))
            previous = lon
        }
        let lons = out.map(\.x)
        let polar = (lons.max() ?? 0) - (lons.min() ?? 0) >= 300
        if polar, closePolar, let first = out.first, let last = out.last {
            // Wraps the globe (Antarctica): close the cap through the
            // nearest pole, using the traversal endpoints, NOT min/max
            // longitude, whose edges would cross the coastline and let
            // the fill slice a wedge out of the continent. The closing
            // edges are pushed 1° PAST each endpoint so adjacent ±360°
            // seam copies overlap instead of abutting: coincident edges
            // under even-odd parity cancel and leave an unfilled
            // one-texel column running to the pole (a faint seam line).
            // Polar rings are therefore filled with NONZERO winding
            // (see ringsPaths/fillPiece), which unions the overlap away.
            let lats = out.map(\.y)
            let pole: CGFloat = (lats.reduce(0, +) / CGFloat(lats.count)) < 0 ? -90 : 90
            out.append(CGPoint(x: last.x + 1, y: pole))
            out.append(CGPoint(x: first.x - 1, y: pole))
        }
        return (out, polar)
    }

    /// One path from a set of rings (all rings, ±360° seam copies), filled
    /// even-odd so holes (enclaves) punch through. Shared by countries and
    /// U.S. states. `forStroke` builds the outline path: a polar coastline is
    /// left OPEN (its endpoints are a full 360° apart and it has no real edge
    /// to the pole), so a stroke doesn't draw a line across the map or down
    /// to the pole. Points that move less than ~a third of a pixel are
    /// decimated, the high-res boundary data is denser than the texture can
    /// show, and CoreGraphics shouldn't chew through invisible segments.
    /// Polar (globe-wrapping) rings come back in a separate path so the fill
    /// can use nonzero winding for them (see `normalized`).
    /// `minStep` is that decimation threshold in pixels: fills keep detail down
    /// to a third of a pixel, while a wide stroke can drop far more, since
    /// CoreGraphics builds a join at every vertex it keeps and the stroke's
    /// own width hides anything finer.
    private static func ringsPaths(_ rings: [[CGPoint]], forStroke: Bool,
                                   size: CGSize, minStep: CGFloat = 0.35) -> (evenOdd: CGMutablePath, polar: CGMutablePath) {
        let evenOddPath = CGMutablePath()
        let polarPath = CGMutablePath()
        for ring in rings {
            let (pts, polar) = normalized(ring, closePolar: !forStroke)
            let leaveOpen = forStroke && polar
            let path = polar ? polarPath : evenOddPath
            for shift in [CGFloat(-360), 0, 360] {
                var last: CGPoint?
                for (i, point) in pts.enumerated() {
                    let p = CGPoint(x: (point.x + shift + 180) / 360 * size.width,
                                    y: (90 - point.y) / 180 * size.height)
                    if let previous = last {
                        let isLast = i == pts.count - 1
                        guard isLast
                            || abs(p.x - previous.x) + abs(p.y - previous.y) >= minStep
                        else { continue }
                        path.addLine(to: p)
                    } else {
                        path.move(to: p)
                    }
                    last = p
                }
                if !leaveOpen { path.closeSubpath() }
            }
        }
        return (evenOddPath, polarPath)
    }

    /// Lays one piece of clay onto the context: filled, then plumped with a
    /// round-joined stroke of the same colour (see `plumpWidth`).
    private static func fillPiece(_ rings: [[CGPoint]], color: CGColor,
                                  in cg: CGContext, size: CGSize) {
        // Fill WITHOUT antialiasing: abutting fills (adjacent countries,
        // seam copies) otherwise each blend half-coverage against the
        // ocean and leave faint seam lines. Aliased fills rasterize
        // complementarily, and the antialiased plump stroke below traces
        // every real edge, so shapes still render smooth.
        let (evenOddFill, polarFill) = ringsPaths(rings, forStroke: false, size: size)
        cg.setShouldAntialias(false)
        cg.setFillColor(color)
        if !evenOddFill.isEmpty {
            // Even-odd so enclave holes (Lesotho) punch through.
            cg.addPath(evenOddFill)
            cg.fillPath(using: .evenOdd)
        }
        if !polarFill.isEmpty {
            // Nonzero for the globe-wrapping polar cap: its overlapping
            // seam copies union instead of parity-cancelling.
            cg.addPath(polarFill)
            cg.fillPath(using: .winding)
        }
        cg.setShouldAntialias(true)
        let width = plumpWidth * size.width / 4096
        let (evenOddStroke, polarStroke) = ringsPaths(rings, forStroke: true, size: size,
                                                      minStep: max(0.35, width * 0.4))
        cg.addPath(evenOddStroke)
        cg.addPath(polarStroke)
        cg.setStrokeColor(color)
        cg.setLineWidth(width)
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        cg.strokePath()
    }

    /// Lays a lit piece as its flag. The flag is scaled to cover the piece's
    /// main body (its biggest ring), clipped to the piece; islands too far off
    /// to be covered get a small flag of their own. The plumped rim is filled
    /// too, so the flag fills the same chunky shape a clay piece would.
    private static func fillFlagPiece(_ rings: [[CGPoint]], flag: UIImage, base: CGColor,
                                      in cg: CGContext, size: CGSize) {
        // Plain clay underneath first, so no sliver of the piece is ever left
        // as bare ocean (a speck too small for a flag, a hairline at a box edge).
        fillPiece(rings, color: base, in: cg, size: size)

        // Flag placements in texture pixels (unshifted copy). Rings are taken
        // biggest first; a ring whose box touches an existing placement grows
        // that placement to cover it, so Hokkaido shares Honshu's flag instead
        // of falling outside it, and placements are merged until disjoint so
        // no two flags ever paint the same pixel.
        let boxes: [CGRect] = rings.map { ring in
            let pts = normalized(ring, closePolar: false).points
            let box = boundingBox(of: [pts])
            return CGRect(x: (box.minX + 180) / 360 * size.width,
                          y: (90 - box.maxY) / 180 * size.height,
                          width: box.width / 360 * size.width,
                          height: box.height / 180 * size.height)
        }
        var placements: [CGRect] = []
        for i in boxes.indices.sorted(by: { boxes[$0].width * boxes[$0].height > boxes[$1].width * boxes[$1].height }) {
            let box = boxes[i]
            guard box.width >= 1, box.height >= 1 else { continue }
            if let j = placements.firstIndex(where: { $0.intersects(box) }) {
                placements[j] = placements[j].union(box)
            } else {
                placements.append(box)
            }
        }
        var merged = true
        while merged {
            merged = false
            search: for a in placements.indices {
                for b in placements.indices where b > a && placements[a].intersects(placements[b]) {
                    placements[a] = placements[a].union(placements[b])
                    placements.remove(at: b)
                    merged = true
                    break search
                }
            }
        }
        func drawFlags() {
            // The emoji bitmap is small; stretched across a big country it
            // would go blocky without smooth interpolation.
            cg.interpolationQuality = .high
            for box in placements {
                let scale = max(box.width / flag.size.width, box.height / flag.size.height) * 1.04
                let w = flag.size.width * scale, h = flag.size.height * scale
                for shift in [-size.width, 0, size.width] {
                    let shifted = box.offsetBy(dx: shift, dy: 0)
                    guard shifted.maxX > 0, shifted.minX < size.width else { continue }
                    // Each flag stays inside its own box: the cover-fit
                    // overhang must not repaint a neighbouring placement.
                    cg.saveGState()
                    cg.clip(to: shifted.insetBy(dx: -1, dy: -1))
                    flag.draw(in: CGRect(x: shifted.midX - w / 2, y: shifted.midY - h / 2, width: w, height: h))
                    cg.restoreGState()
                }
            }
        }
        let (evenOddFill, polarFill) = ringsPaths(rings, forStroke: false, size: size)
        if !evenOddFill.isEmpty {
            cg.saveGState()
            cg.addPath(evenOddFill)
            cg.clip(using: .evenOdd)
            drawFlags()
            cg.restoreGState()
        }
        if !polarFill.isEmpty {
            cg.saveGState()
            cg.addPath(polarFill)
            cg.clip(using: .winding)
            drawFlags()
            cg.restoreGState()
        }
        let width = plumpWidth * size.width / 4096
        let (evenOddStroke, polarStroke) = ringsPaths(rings, forStroke: true, size: size,
                                                      minStep: max(0.35, width * 0.4))
        cg.saveGState()
        cg.addPath(evenOddStroke)
        cg.addPath(polarStroke)
        cg.setLineWidth(width)
        cg.setLineJoin(.round)
        cg.setLineCap(.round)
        cg.replacePathWithStrokedPath()
        cg.clip()
        drawFlags()
        cg.restoreGState()
    }

    /// Strokes a piece's outline with whatever stroke state is already set:
    /// the seam where two pieces meet, or where land meets sea.
    private static func strokeSeam(_ rings: [[CGPoint]], lineWidth: CGFloat,
                                   in cg: CGContext, size: CGSize) {
        let (evenOddStroke, polarStroke) = ringsPaths(rings, forStroke: true, size: size,
                                                      minStep: max(0.35, lineWidth * 0.5))
        cg.addPath(evenOddStroke)
        cg.addPath(polarStroke)
        cg.strokePath()
    }

    /// Equirectangular clay texture: a Play-Doh ocean with every country laid
    /// on as its own pressed piece of green clay (orange when visited, white
    /// at the poles), seams pressed between the pieces, and a faint mottle
    /// over everything so no colour is dead flat. Wrapped directly onto the
    /// globe sphere (x: lon -180…180, y: lat 90…-90).
    func globeTexture(visited: Set<String>,
                      visitedStates: Set<String> = [],
                      style: GlobeStyle = .clay,
                      size: CGSize = CGSize(width: 4096, height: 2048)) -> UIImage {
        let memoKey = "\(Int(size.width))x\(Int(size.height))|\(style.rawValue)|"
            + visited.sorted().joined(separator: ",") + "|"
            + visitedStates.sorted().joined(separator: ",")
        textureMemoLock.lock()
        if let image = textureMemo[memoKey] {
            textureMemoLock.unlock()
            return image
        }
        textureMemoLock.unlock()

        let pieces = pieces(visited: visited, visitedStates: visitedStates, style: style)
        let clock = StageClock("globeTexture")
        let grain = clayGrain()
        clock.lap("grain")

        // Scale 1: the default (device-scale) renderer would triple this to a
        // huge bitmap for no visible gain on a sphere.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let rect = CGRect(origin: .zero, size: size)

            cg.setFillColor(Clay.ocean.cgColor)
            cg.fill(rect)

            // Unvisited first, visited on top, so a lit piece's plump edge
            // sits over its neighbours and its shape stays crisp.
            for piece in pieces where !piece.visited {
                Self.fillPiece(piece.rings, color: piece.color, in: cg, size: size)
            }
            for piece in pieces where piece.visited {
                if let flag = piece.flag {
                    Self.fillFlagPiece(piece.rings, flag: flag, base: piece.color, in: cg, size: size)
                } else {
                    Self.fillPiece(piece.rings, color: piece.color, in: cg, size: size)
                }
            }
            clock.lap("pieces")

            // Seams last, over everything. Multiply so the crease darkens
            // whichever colours sit on either side instead of drawing a
            // uniform outline; the normal map adds the actual groove.
            cg.setBlendMode(.multiply)
            cg.setStrokeColor(UIColor(white: 0, alpha: 0.30).cgColor)
            let seamWidth = 2.4 * size.width / 4096
            cg.setLineWidth(seamWidth)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            for piece in pieces {
                Self.strokeSeam(piece.rings, lineWidth: seamWidth, in: cg, size: size)
            }

            clock.lap("seams")

            // Mottle: hand-mixed dough is never one flat colour. (UIImage.draw
            // ignores the context's blend mode and alpha, so pass them here.)
            cg.setBlendMode(.normal)
            grain.image.draw(in: rect, blendMode: .softLight, alpha: 0.32)
            clock.lap("mottle")
        }
        clock.lap("bitmap")

        textureMemoLock.lock()
        textureMemo[memoKey] = image
        textureMemoOrder.append(memoKey)
        if textureMemoOrder.count > Self.textureMemoLimit {
            textureMemo[textureMemoOrder.removeFirst()] = nil
        }
        textureMemoLock.unlock()
        return image
    }

    // MARK: - Clay grain

    /// Tileable value noise: the fingerprint-and-thumb texture of worked
    /// clay. Used as a faint mottle on the colour texture and as fine bumps
    /// in the normal map. It wraps seamlessly in x (the sphere's seam) and is
    /// computed once, at half the relief-map resolution, it's soft anyway.
    struct Grain {
        let width: Int
        let height: Int
        let values: [UInt8]
        let image: UIImage
    }

    private let grainLock = NSLock()
    private var grainMemo: Grain?

    func clayGrain() -> Grain {
        grainLock.lock()
        if let g = grainMemo { grainLock.unlock(); return g }
        grainLock.unlock()

        let width = 512, height = 256
        func hash(_ x: Int, _ y: Int, _ octave: Int) -> Float {
            var h = UInt64(bitPattern: Int64(x)) &* 0x9E3779B97F4A7C15
            h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2AE3D27D4EB4F
            h ^= UInt64(octave &+ 1) &* 0x165667B19E3779F9
            h ^= h >> 29
            h = h &* 0xBF58476D1CE4E5B9
            h ^= h >> 32
            return Float(h & 0xFFFFFF) / Float(0xFFFFFF)
        }
        // (cells across the width, amplitude): thumbprints, then knuckle
        // dents, then fine grain.
        let octaves: [(cells: Int, amp: Float)] = [(18, 1.0), (64, 0.45), (200, 0.25)]
        let total = octaves.reduce(Float(0)) { $0 + $1.amp }
        var values = [UInt8](repeating: 0, count: width * height)
        values.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                for x in 0..<width {
                    var v: Float = 0
                    for (o, octave) in octaves.enumerated() {
                        let cells = octave.cells
                        let fx = Float(x) / Float(width) * Float(cells)
                        let fy = Float(y) / Float(width) * Float(cells)   // square cells
                        let ix = Int(fx), iy = Int(fy)
                        var tx = fx - Float(ix), ty = fy - Float(iy)
                        tx = tx * tx * (3 - 2 * tx)
                        ty = ty * ty * (3 - 2 * ty)
                        let x0 = ix % cells, x1 = (ix + 1) % cells   // wraps in x
                        let a = hash(x0, iy, o), b = hash(x1, iy, o)
                        let c = hash(x0, iy + 1, o), d = hash(x1, iy + 1, o)
                        let top = a + (b - a) * tx
                        let bottom = c + (d - c) * tx
                        v += octave.amp * (top + (bottom - top) * ty)
                    }
                    out[y * width + x] = UInt8(max(0, min(255, v / total * 255)))
                }
            }
        }
        let image = Self.grayImage(values, width: width, height: height)
        let grain = Grain(width: width, height: height, values: values, image: image)
        grainLock.lock(); grainMemo = grain; grainLock.unlock()
        return grain
    }

    // MARK: - Relief (displacement + normal map)

    /// The two maps that make the clay stand off the ball.
    struct ReliefMaps {
        /// Height: land stands proud of the sea, visited pieces higher still.
        /// Heavily softened so pieces rise as rounded pillows, not cliffs.
        let displacement: UIImage
        /// Tangent-space normals derived from that height, plus pressed seams
        /// between pieces and the clay grain. Displacement alone moves
        /// vertices but leaves the sphere's smooth normals, so without this
        /// the raised edges catch no light; this is what makes a coastline
        /// read as a bevelled edge of clay.
        let normal: UIImage
    }

    private let reliefMemoLock = NSLock()
    private var reliefMemo: (key: String, maps: ReliefMaps)?

    /// Equirectangular relief for the current visited set. Memoized on the
    /// set, since lit pieces are raised higher than the rest. Half the colour
    /// texture's resolution: relief is soft by design, and the per-pixel
    /// normal pass below runs on the CPU.
    func reliefMaps(visited: Set<String>,
                    visitedStates: Set<String> = [],
                    size: CGSize = CGSize(width: 1024, height: 512)) -> ReliefMaps {
        let memoKey = "\(Int(size.width))x\(Int(size.height))|"
            + visited.sorted().joined(separator: ",") + "|"
            + visitedStates.sorted().joined(separator: ",")
        reliefMemoLock.lock()
        if let memo = reliefMemo, memo.key == memoKey {
            let maps = memo.maps
            reliefMemoLock.unlock()
            return maps
        }
        reliefMemoLock.unlock()

        let pieces = pieces(visited: visited, visitedStates: visitedStates)
        let clock = StageClock("reliefMaps")
        let width = Int(size.width), height = Int(size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rect = CGRect(origin: .zero, size: size)

        // 1. Height: how far each piece stands off the ball.
        let heightImage = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(rect)
            let land = UIColor(white: 0.58, alpha: 1).cgColor
            let lit = UIColor.white.cgColor
            for piece in pieces where !piece.visited {
                Self.fillPiece(piece.rings, color: land, in: cg, size: size)
            }
            for piece in pieces where piece.visited {
                Self.fillPiece(piece.rings, color: lit, in: cg, size: size)
            }
            // Flatten the poles (top/bottom rows) to black so the UV-sphere's
            // pole vertex, where all longitudes converge, has no
            // displacement to spike into a visible dot.
            if let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [UIColor.black.cgColor,
                                              UIColor.black.withAlphaComponent(0).cgColor] as CFArray,
                                     locations: [0, 1]) {
                let h = size.height
                cg.drawLinearGradient(fade, start: CGPoint(x: 0, y: 0),
                                      end: CGPoint(x: 0, y: h * 0.07), options: [])
                cg.drawLinearGradient(fade, start: CGPoint(x: 0, y: h),
                                      end: CGPoint(x: 0, y: h * 0.93), options: [])
            }
        }
        // Soften the coastlines heavily so the relief reads as rounded, puffy
        // clay (like plasticine), not sheer torn cliffs or spiky peaks.
        clock.lap("height")
        let bevel = Self.blur(heightImage, radius: 4 * size.width / 1024) ?? heightImage
        clock.lap("bevel blur")

        // 2. Seams: shallow grooves pressed between the pieces.
        let seamImage = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(rect)
            cg.setStrokeColor(UIColor.white.cgColor)
            let seamWidth = 1.5 * size.width / 1024
            cg.setLineWidth(seamWidth)
            cg.setLineJoin(.round)
            cg.setLineCap(.round)
            for piece in pieces {
                Self.strokeSeam(piece.rings, lineWidth: seamWidth, in: cg, size: size)
            }
        }
        let grooves = Self.blur(seamImage, radius: 0.8 * size.width / 1024) ?? seamImage
        clock.lap("seams + blur")

        // 3. Height field = pillowed pieces, minus grooves, plus grain; then
        //    finite differences give the tangent-space normal.
        let bevelPx = Self.grayPixels(bevel, width: width, height: height)
        let groovePx = Self.grayPixels(grooves, width: width, height: height)
        let grain = clayGrain()
        var field = [Float](repeating: 0, count: width * height)
        let poleBand = Float(height) * 0.08
        field.withUnsafeMutableBufferPointer { f in
            bevelPx.withUnsafeBufferPointer { bevel in
                groovePx.withUnsafeBufferPointer { groove in
                    grain.values.withUnsafeBufferPointer { grainPx in
                        for y in 0..<height {
                            let fade = min(1, Float(min(y, height - 1 - y)) / poleBand)
                            let gy = min(grain.height - 1, y * grain.height / height)
                            for x in 0..<width {
                                let i = y * width + x
                                let gx = min(grain.width - 1, x * grain.width / width)
                                let g = Float(grainPx[gy * grain.width + gx]) / 255 - 0.5
                                f[i] = Float(bevel[i]) / 255
                                    - Float(groove[i]) / 255 * 0.5
                                    + g * 0.10 * fade
                            }
                        }
                    }
                }
            }
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        // Slope-to-tilt gain: the pillow ramp is a few texels wide, so this
        // makes a coastline lean about 60 degrees at its steepest.
        let strength = 11 * Float(size.width) / 1024
        rgba.withUnsafeMutableBufferPointer { out in
            field.withUnsafeBufferPointer { f in
                for y in 0..<height {
                    let up = max(0, y - 1), down = min(height - 1, y + 1)
                    for x in 0..<width {
                        let left = (x - 1 + width) % width, right = (x + 1) % width   // wraps at the seam
                        let dx = (f[y * width + right] - f[y * width + left]) * 0.5 * strength
                        let dy = (f[down * width + x] - f[up * width + x]) * 0.5 * strength
                        // OpenGL-style tangent space: +red is east (+U), +green
                        // is north (toward the top of the image).
                        var nx = -dx
                        var ny = dy
                        var nz: Float = 1
                        let len = (nx * nx + ny * ny + nz * nz).squareRoot()
                        nx /= len; ny /= len; nz /= len
                        let o = (y * width + x) * 4
                        out[o] = UInt8((nx * 0.5 + 0.5) * 255)
                        out[o + 1] = UInt8((ny * 0.5 + 0.5) * 255)
                        out[o + 2] = UInt8((nz * 0.5 + 0.5) * 255)
                    }
                }
            }
        }
        let normal = Self.rgbaImage(rgba, width: width, height: height)
        clock.lap("normals")
        let maps = ReliefMaps(displacement: bevel, normal: normal)
        reliefMemoLock.lock()
        reliefMemo = (memoKey, maps)
        reliefMemoLock.unlock()
        return maps
    }

    /// DEBUG-only stage timer for the texture pipeline, so a slow launch can
    /// be pinned to a stage instead of guessed at. Silent in release.
    private final class StageClock {
        private let name: String
        private var last = Date()
        init(_ name: String) { self.name = name }
        func lap(_ stage: String) {
            #if DEBUG
            let now = Date()
            print("[ClayGlobe] \(name): \(stage) \(String(format: "%.2f", now.timeIntervalSince(last)))s")
            last = now
            #endif
        }
    }

    /// One context for every blur: creating one is the expensive part.
    private static let ciContext = CIContext(options: nil)

    private static func blur(_ image: UIImage, radius: Double) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage else { return nil }
        guard let out = ciContext.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: out)
    }

    /// 8-bit luminance of an image, top row first.
    private static func grayPixels(_ image: UIImage, width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let cg = image.cgImage else { return pixels }
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    /// Grey image from 8-bit luminance, top row first.
    private static func grayImage(_ pixels: [UInt8], width: Int, height: Int) -> UIImage {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: cg)
    }

    /// RGBA image from packed 8-bit pixels, top row first. Tagged linear: this
    /// is vector data (a normal map), not colour, and must not be gamma-decoded
    /// on the way to the GPU.
    private static func rgbaImage(_ pixels: [UInt8], width: Int, height: Int) -> UIImage {
        let data = Data(pixels)
        let space = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return UIImage() }
        return UIImage(cgImage: cg)
    }
}
