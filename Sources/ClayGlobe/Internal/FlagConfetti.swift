import SwiftUI

// MARK: - Shared confetti physics

/// One piece of popper confetti. Physics is closed-form in the piece's local
/// time, so every frame is computed directly from the start date; nothing is
/// integrated and dropped frames can't drift.
private struct ConfettiPiece {
    let emojiIndex: Int
    /// Emission stagger so the pop feels organic, not stamped.
    let birth: Double
    let vx: CGFloat
    let vy: CGFloat
    /// Air drag; the launch bleeds off within ~half a second.
    let k: CGFloat
    /// Paper-flutter fall speed the piece settles at. Slow terminal
    /// fall is the single thing that most makes it read as confetti.
    let terminal: CGFloat
    /// When this piece crests; sway ramps in only after that.
    let apex: Double
    /// Flat spin: fast out of the barrel, decaying to a lazy residual.
    let spin0: Double
    let spinEnd: Double
    let angle0: Double
    /// Sheet tumble: y-scale oscillates through zero like paper
    /// flipping over; sway slips sideways at half that rate.
    let tumbleFreq: Double
    let tumblePhase: Double
    let swayAmp: CGFloat
    let xSquash: CGFloat
    let sizeScale: CGFloat
    let lifetime: Double
}

/// Spin decay rate (s^-1), shared by all pieces.
private let confettiSpinDecay = 1.8

/// Builds a popper burst's pieces. Triangular angle distribution clusters
/// pieces near the cone's center with sparse edges; uniform sampling makes the
/// telltale expanding ring. A few weak strays off-axis sell the popper.
private func makeConfettiPieces(count: Int, maxDistance: CGFloat, emojiCount: Int) -> [ConfettiPiece] {
    let scale = maxDistance / 150
    let vMin = maxDistance * 5.6
    let vMax = maxDistance * 10.6
    return (0..<count).map { i -> ConfettiPiece in
        let stray = Double.random(in: 0...1) < 0.12
        var theta = (Double.random(in: 0...1) + Double.random(in: 0...1) - 1) * 45
        var speed = vMin + (vMax - vMin) * pow(.random(in: 0...1), 0.7)
        if stray {
            theta *= 1.8
            speed *= 0.5
        }
        let rad = Angle.degrees(theta).radians
        let vx = CGFloat(sin(rad)) * speed
        let vy = -CGFloat(cos(rad)) * speed

        let k = CGFloat.random(in: 3.5...5.5)
        let sizeScale = CGFloat.random(in: 0.75...1.35)
        let sizeNorm = (sizeScale - 0.75) / 0.6
        // Bigger pieces fall a touch faster, layering the field.
        let terminal = 70 + 55 * sizeNorm + CGFloat.random(in: -15...15)
        let spinDir: Double = Bool.random() ? 1 : -1
        return ConfettiPiece(
            emojiIndex: i % max(1, emojiCount),
            birth: .random(in: 0...0.08),
            vx: vx,
            vy: vy,
            k: k,
            terminal: terminal,
            apex: Double(log(1 - vy / terminal) / k),
            spin0: spinDir * .random(in: 360...720),
            spinEnd: spinDir * .random(in: 30...90),
            angle0: .random(in: 0...360),
            tumbleFreq: .random(in: 1.2...3.0),
            tumblePhase: .random(in: 0...(2 * .pi)),
            swayAmp: .random(in: 18...42) * scale,
            xSquash: .random(in: 0.92...1.0),
            sizeScale: sizeScale,
            lifetime: .random(in: 2.0...3.2) * (0.8 + 0.2 * scale)
        )
    }
}

/// Draws one piece at `now` seconds since its burst started, launching from
/// `origin`. Skips pieces that are unborn or dead.
private func drawConfettiPiece(_ piece: ConfettiPiece, at now: TimeInterval,
                               origin: CGPoint,
                               symbol: GraphicsContext.ResolvedSymbol,
                               in context: inout GraphicsContext) {
    let t = now - piece.birth
    guard t > 0, t < piece.lifetime else { return }
    let a = CGFloat(t)

    // Launch velocity decays exponentially toward the slow terminal
    // fall; position is the closed-form integral of that.
    let decay = (1 - exp(-piece.k * a)) / piece.k

    // Falling-leaf sideslip: zero through the ballistic launch,
    // ramping in over 0.6s after this piece's own apex.
    let sway: CGFloat
    if t > piece.apex {
        let u = min(1, (t - piece.apex) / 0.6)
        let ramp = CGFloat(u * u * (3 - 2 * u))
        sway = piece.swayAmp * ramp * CGFloat(
            sin(.pi * piece.tumbleFreq * t + piece.tumblePhase))
    } else {
        sway = 0
    }
    // Pieces hesitate as they flip flat, coupled to the tumble.
    let hesitation = piece.terminal * 0.15 / (2 * .pi * CGFloat(piece.tumbleFreq))
        * CGFloat(sin(2 * .pi * piece.tumbleFreq * t + piece.tumblePhase))

    let x = origin.x + piece.vx * decay + sway
    let y = origin.y + piece.terminal * a
        + (piece.vy - piece.terminal) * decay + hesitation

    // Opaque paper through most of the fall; smoothstep out over
    // the final 22% so the field dissolves raggedly.
    let fadeU = max(0, min(1, (t - 0.78 * piece.lifetime) / (0.22 * piece.lifetime)))
    let opacity = 1 - fadeU * fadeU * (3 - 2 * fadeU)

    let spinDecayed = (1 - exp(-confettiSpinDecay * t)) / confettiSpinDecay
    let angle = piece.angle0 + piece.spinEnd * t
        + (piece.spin0 - piece.spinEnd) * spinDecayed

    // Tumble mirrors through zero like a flipping sheet; clamp so
    // the glyph never collapses into an invisible line.
    let tumble = cos(2 * .pi * piece.tumbleFreq * t + piece.tumblePhase)
    let yScale = max(0.15, abs(tumble)) * (tumble < 0 ? -1 : 1)

    var ctx = context
    ctx.opacity = opacity
    ctx.translateBy(x: x, y: y)
    ctx.rotate(by: .degrees(angle))
    ctx.scaleBy(x: piece.xSquash * piece.sizeScale,
                y: CGFloat(yScale) * piece.sizeScale)
    ctx.draw(symbol, at: .zero)
}

// MARK: - Flag confetti (single burst)

/// A celebratory burst of emoji flags, simulated like real popper confetti.
/// Overlay it on the view the burst should erupt from and bump `trigger` to
/// fire. Pieces launch instantly in an upward cone, drag slows them fast,
/// then they flutter down slowly with sway and tumble, fading only at the
/// end of their life. Purely decorative (never hit-testable).
///
/// For rapid multi-burst shows (e.g. checkbox cascades) use
/// `FlagConfettiField`: each `FlagConfettiBurst` owns a TimelineView, and
/// mounting/unmounting those mid-animation stalls rendering (SwiftUI timeline
/// (re)registration does dynamic casts that scan the protocol-conformance
/// tables of every loaded image, which is expensive).
struct FlagConfettiBurst: View {
    /// The emoji to throw; repeated round-robin across pieces.
    let flags: [String]
    /// Fire the burst by incrementing this.
    let trigger: Int
    var pieceCount: Int = 48
    /// Rough radius of the burst; launch speed, sway, and the canvas all
    /// scale from it so small per-row bursts stay tight.
    var maxDistance: CGFloat = 150

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst: Burst?

    private struct Burst {
        let id: Int
        let start: Date
        let emoji: [String]
        let pieces: [ConfettiPiece]
        let maxLifetime: Double
    }

    private var scale: CGFloat { maxDistance / 150 }

    var body: some View {
        ZStack {
            if let burst {
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        let now = timeline.date.timeIntervalSince(burst.start)
                        // Launch point: pieces rise ~2.3x maxDistance and
                        // flutter down well past the origin, so it sits in the
                        // canvas's upper part.
                        let origin = CGPoint(x: size.width / 2, y: maxDistance * 2.3 + 60)
                        for piece in burst.pieces {
                            guard let symbol = context.resolveSymbol(id: piece.emojiIndex) else { continue }
                            drawConfettiPiece(piece, at: now, origin: origin,
                                              symbol: symbol, in: &context)
                        }
                    } symbols: {
                        ForEach(Array(burst.emoji.enumerated()), id: \.offset) { index, emoji in
                            Text(emoji)
                                .font(.system(size: 22 * (0.75 + 0.25 * scale)))
                                .tag(index)
                        }
                    }
                }
                // Generous canvas so pieces never clip mid-flight: room for
                // the full rise above the origin and a long flutter below.
                .frame(width: maxDistance * 4.4 + 100,
                       height: maxDistance * 5.6 + 260)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
        // Hoisted bursts are created with a nonzero trigger and live for
        // one show; fire the moment they appear.
        .onAppear { if trigger > 0 { fire() } }
        // Tear the canvas down once the last piece dies so TimelineView
        // stops redrawing. Keyed to the burst id: a retrigger cancels the
        // old countdown and starts a fresh one.
        .task(id: burst?.id) {
            guard let burst else { return }
            try? await Task.sleep(for: .seconds(burst.maxLifetime + 0.3))
            if !Task.isCancelled { self.burst = nil }
        }
    }

    private func fire() {
        guard !reduceMotion else { return }
        let emoji = flags.filter { !$0.isEmpty }
        guard !emoji.isEmpty else { return }
        let count = max(pieceCount, emoji.count)
        let pieces = makeConfettiPieces(count: count, maxDistance: maxDistance,
                                        emojiCount: emoji.count)
        burst = Burst(
            id: trigger,
            start: Date(),
            emoji: emoji,
            pieces: pieces,
            maxLifetime: pieces.map { $0.birth + $0.lifetime }.max() ?? 3.4
        )
    }
}

// MARK: - Flag confetti field (many bursts, one canvas)

/// Renders many bursts through ONE persistent TimelineView + Canvas. Appending
/// to `shots` fires a burst at its center point; no animated subtree is ever
/// inserted or removed per burst, so rapid cascades stay smooth. The timeline
/// mounts on the first shot and unmounts only after every piece has died,
/// both transitions land on effectively static content.
struct FlagConfettiField: View {
    struct Shot: Equatable {
        let flag: String
        /// Launch anchor in the field's coordinate space (e.g. the checkmark
        /// of the tapped row).
        let center: CGPoint
    }

    /// Append-only while bursts are flying; safe to clear once idle.
    let shots: [Shot]
    var pieceCount: Int = 14
    var maxDistance: CGFloat = 90

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var live: [LiveBurst] = []
    @State private var consumed = 0

    private struct LiveBurst: Identifiable {
        let id: Int
        let flag: String
        let start: Date
        let origin: CGPoint
        let pieces: [ConfettiPiece]
        let deadline: Date
    }

    /// Matches FlagConfettiBurst's geometry: within its own canvas the launch
    /// point sits above center, so anchoring at a row's checkmark means
    /// launching this far above it.
    private var originYOffset: CGFloat {
        (maxDistance * 2.3 + 60) - (maxDistance * 5.6 + 260) / 2
    }

    var body: some View {
        ZStack {
            if !live.isEmpty {
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        for burst in live {
                            guard let symbol = context.resolveSymbol(id: burst.id) else { continue }
                            let now = timeline.date.timeIntervalSince(burst.start)
                            for piece in burst.pieces {
                                drawConfettiPiece(piece, at: now, origin: burst.origin,
                                                  symbol: symbol, in: &context)
                            }
                        }
                    } symbols: {
                        ForEach(live) { burst in
                            Text(burst.flag)
                                .font(.system(size: 22 * (0.75 + 0.25 * maxDistance / 150)))
                                .tag(burst.id)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: shots.count) { _, _ in ingest() }
        // Retire everything once the last piece has died, unmounting the
        // timeline on a static field.
        .task(id: live.count) {
            guard let last = live.map(\.deadline).max() else { return }
            let wait = max(0.1, last.timeIntervalSinceNow + 0.3)
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled, live.allSatisfy({ $0.deadline < Date() }) {
                live.removeAll()
            }
        }
    }

    private func ingest() {
        if shots.count < consumed { consumed = shots.count }   // shots were cleared
        guard !reduceMotion else { consumed = shots.count; return }
        while consumed < shots.count {
            let shot = shots[consumed]
            let pieces = makeConfettiPieces(count: pieceCount, maxDistance: maxDistance,
                                            emojiCount: 1)
            let maxLife = pieces.map { $0.birth + $0.lifetime }.max() ?? 3.4
            live.append(LiveBurst(
                id: consumed,
                flag: shot.flag,
                start: Date(),
                origin: CGPoint(x: shot.center.x, y: shot.center.y + originYOffset),
                pieces: pieces,
                deadline: Date().addingTimeInterval(maxLife)
            ))
            consumed += 1
        }
    }
}

// MARK: - Flag emoji lookup

/// ISO 3166-1 alpha-3 → flag emoji (via alpha-2 regional indicators).
/// Covers the atlas's countries; unknown codes return nil so callers can
/// skip the flag rather than show a wrong one.
nonisolated enum CountryFlags {
    static func flag(forAlpha3 code: String) -> String? {
        guard let alpha2 = alpha3to2[code.uppercased()] else { return nil }
        var flag = ""
        for scalar in alpha2.unicodeScalars {
            guard let indicator = Unicode.Scalar(127397 + scalar.value) else { return nil }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    private static let alpha3to2: [String: String] = [
        "AFG": "AF", "ALB": "AL", "DZA": "DZ", "AND": "AD", "AGO": "AO",
        "ATG": "AG", "ARG": "AR", "ARM": "AM", "AUS": "AU", "AUT": "AT",
        "AZE": "AZ", "BHS": "BS", "BHR": "BH", "BGD": "BD", "BRB": "BB",
        "BLR": "BY", "BEL": "BE", "BLZ": "BZ", "BEN": "BJ", "BTN": "BT",
        "BOL": "BO", "BIH": "BA", "BWA": "BW", "BRA": "BR", "BRN": "BN",
        "BGR": "BG", "BFA": "BF", "BDI": "BI", "CPV": "CV", "KHM": "KH",
        "CMR": "CM", "CAN": "CA", "CAF": "CF", "TCD": "TD", "CHL": "CL",
        "CHN": "CN", "COL": "CO", "COM": "KM", "COG": "CG", "COD": "CD",
        "CRI": "CR", "CIV": "CI", "HRV": "HR", "CUB": "CU", "CYP": "CY",
        "CZE": "CZ", "DNK": "DK", "DJI": "DJ", "DMA": "DM", "DOM": "DO",
        "ECU": "EC", "EGY": "EG", "SLV": "SV", "GNQ": "GQ", "ERI": "ER",
        "EST": "EE", "SWZ": "SZ", "ETH": "ET", "FJI": "FJ", "FIN": "FI",
        "FRA": "FR", "GAB": "GA", "GMB": "GM", "GEO": "GE", "DEU": "DE",
        "GHA": "GH", "GRC": "GR", "GRD": "GD", "GTM": "GT", "GIN": "GN",
        "GNB": "GW", "GUY": "GY", "HTI": "HT", "HND": "HN", "HUN": "HU",
        "ISL": "IS", "IND": "IN", "IDN": "ID", "IRN": "IR", "IRQ": "IQ",
        "IRL": "IE", "ISR": "IL", "ITA": "IT", "JAM": "JM", "JPN": "JP",
        "JOR": "JO", "KAZ": "KZ", "KEN": "KE", "KIR": "KI", "PRK": "KP",
        "KOR": "KR", "KWT": "KW", "KGZ": "KG", "LAO": "LA", "LVA": "LV",
        "LBN": "LB", "LSO": "LS", "LBR": "LR", "LBY": "LY", "LIE": "LI",
        "LTU": "LT", "LUX": "LU", "MDG": "MG", "MWI": "MW", "MYS": "MY",
        "MDV": "MV", "MLI": "ML", "MLT": "MT", "MHL": "MH", "MRT": "MR",
        "MUS": "MU", "MEX": "MX", "FSM": "FM", "MDA": "MD", "MCO": "MC",
        "MNG": "MN", "MNE": "ME", "MAR": "MA", "MOZ": "MZ", "MMR": "MM",
        "NAM": "NA", "NRU": "NR", "NPL": "NP", "NLD": "NL", "NZL": "NZ",
        "NIC": "NI", "NER": "NE", "NGA": "NG", "MKD": "MK", "NOR": "NO",
        "OMN": "OM", "PAK": "PK", "PLW": "PW", "PSE": "PS", "PAN": "PA",
        "PNG": "PG", "PRY": "PY", "PER": "PE", "PHL": "PH", "POL": "PL",
        "PRT": "PT", "QAT": "QA", "ROU": "RO", "RUS": "RU", "RWA": "RW",
        "KNA": "KN", "LCA": "LC", "VCT": "VC", "WSM": "WS", "SMR": "SM",
        "STP": "ST", "SAU": "SA", "SEN": "SN", "SRB": "RS", "SYC": "SC",
        "SLE": "SL", "SGP": "SG", "SVK": "SK", "SVN": "SI", "SLB": "SB",
        "SOM": "SO", "ZAF": "ZA", "SSD": "SS", "ESP": "ES", "LKA": "LK",
        "SDN": "SD", "SUR": "SR", "SWE": "SE", "CHE": "CH", "SYR": "SY",
        "TWN": "TW", "TJK": "TJ", "TZA": "TZ", "THA": "TH", "TLS": "TL",
        "TGO": "TG", "TON": "TO", "TTO": "TT", "TUN": "TN", "TUR": "TR",
        "TKM": "TM", "TUV": "TV", "UGA": "UG", "UKR": "UA", "ARE": "AE",
        "GBR": "GB", "USA": "US", "URY": "UY", "UZB": "UZ", "VUT": "VU",
        "VAT": "VA", "VEN": "VE", "VNM": "VN", "YEM": "YE", "ZMB": "ZM",
        "ZWE": "ZW", "KOS": "XK", "GRL": "GL", "PRI": "PR", "GUF": "GF",
        "NCL": "NC", "PYF": "PF", "FLK": "FK", "ATA": "AQ", "ESH": "EH",
        "CUW": "CW", "ABW": "AW", "CYM": "KY", "BMU": "BM", "AIA": "AI",
        "TCA": "TC", "VGB": "VG", "MSR": "MS", "GIB": "GI", "IMN": "IM",
        "JEY": "JE", "GGY": "GG", "FRO": "FO", "HKG": "HK", "MAC": "MO",
        "SXM": "SX", "BLM": "BL", "MAF": "MF", "SPM": "PM", "WLF": "WF",
        "COK": "CK", "NIU": "NU", "TKL": "TK", "ASM": "AS", "GUM": "GU",
        "MNP": "MP", "VIR": "VI", "NFK": "NF", "CXR": "CX", "CCK": "CC",
        "HMD": "HM", "IOT": "IO", "SGS": "GS", "SHN": "SH", "PCN": "PN",
        "MYT": "YT", "REU": "RE", "GLP": "GP", "MTQ": "MQ", "SJM": "SJ",
        "ALA": "AX", "BES": "BQ", "BVT": "BV", "ATF": "TF", "UMI": "UM",
    ]
}
