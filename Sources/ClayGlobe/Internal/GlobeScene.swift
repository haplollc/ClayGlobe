import SwiftUI
import SceneKit

/// The clay planet. A SceneKit sphere wearing a matte plasticine material
/// with every country laid on as its own raised piece of clay, a few puffy
/// clay clouds drifting over it, and a chubby clay airplane circling the
/// world. Tap it and it squishes. Spin it with a finger; pinch to zoom.
struct ClayGlobeSceneView: UIViewRepresentable {
    var configuration: GlobeConfiguration = GlobeConfiguration()
    let visited: Set<String>
    let visitedStates: Set<String>
    /// How lit pieces show: orange clay, flag fill, or planted flags.
    var style: GlobeStyle = .clay

    /// Camera distance for a globe about 88% of the view's width. The field
    /// of view is pinned to the horizontal axis, so this holds on any device.
    private static let cameraDistance: Float = 2.21
    /// Pulled back a little for App Store captures so the clouds and plane
    /// have room around the ball.
    private static let holdStillCameraDistance: Float = 2.42

    /// Surface shader (Metal): a soft rim where the ball turns away from the
    /// viewer, like a backlit miniature on a stop-motion set. Emission is
    /// added after lighting, so it reads as a glow, not a colour shift.
    private static let rimModifier = """
    #pragma body
    float3 v = normalize(_surface.view);
    float rim = pow(1.0 - saturate(dot(v, _surface.normal)), 4.0);
    _surface.emission.rgb += float3(0.62, 0.74, 1.0) * rim * 0.16;
    """

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.inertiaEnabled = true
        view.antialiasingMode = .multisampling4X
        view.delegate = context.coordinator
        context.coordinator.view = view

        let scene = SCNScene()
        view.scene = scene

        // Soft studio light from all around: a cool sky above, a warm glow
        // at the horizon, dusty bounce from below. This is what keeps the
        // shaded side of the clay readable and the highlights broad.
        scene.lightingEnvironment.contents = Self.environmentImage()
        scene.lightingEnvironment.intensity = 0.9

        // The ball.
        let sphere = SCNSphere(radius: 1)
        // Dense enough that the displacement-mapped countries read as raised
        // clay relief rather than a faceted blob.
        sphere.segmentCount = 240
        let globe = SCNNode(geometry: sphere)
        globe.name = "globe"
        // Plain ocean placeholder; the real texture renders off-main below.
        let placeholder = SCNMaterial()
        placeholder.lightingModel = .physicallyBased
        placeholder.diffuse.contents = CountryAtlas.Clay.ocean
        placeholder.roughness.contents = NSNumber(value: 0.86)
        placeholder.metalness.contents = NSNumber(value: 0)
        globe.geometry?.materials = [placeholder]
        // A gentle idle spin, stopped the first time the user grabs the globe
        // so the camera orbit doesn't fight a moving target.
        globe.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 60)), forKey: "spin")

        // Everything that IS the world lives under one node that stays
        // invisible until the clay texture is on the ball, then springs in as
        // a whole (see growIn): the planet never shows as a bare placeholder.
        let world = SCNNode()
        world.name = "world"
        world.opacity = 0
        world.addChildNode(globe)
        // Clouds and the plane orbit the ball on their own, independent of
        // its spin, so there is always something moving over the map.
        world.addChildNode(Self.makeClouds())
        world.addChildNode(Self.makePlaneOrbit())
        scene.rootNode.addChildNode(world)

        // Camera.
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.fieldOfView = 60
        camera.projectionDirection = .horizontal
        camera.zNear = 0.1
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Self.cameraDistance)
        scene.rootNode.addChildNode(cameraNode)
        view.pointOfView = cameraNode
        view.defaultCameraController.target = SCNVector3Zero

        // A fixed orientation (no idle spin) for repeatable captures, opted
        // into through the configuration rather than an app-specific flag.
        if configuration.holdsStill {
            cameraNode.position = SCNVector3(0, 0, Self.holdStillCameraDistance)
            globe.removeAllActions()
            globe.eulerAngles = SCNVector3(Float(0.62), Float(-0.30), 0)
        }

        // Lights ride in a rig that follows whatever camera is live (the
        // built-in controller swaps in its own once the user touches the
        // view), so the hemisphere you're looking at is always the lit one.
        let rig = Self.makeLightRig()
        rig.transform = cameraNode.transform
        scene.rootNode.addChildNode(rig)
        context.coordinator.lightRig = rig

        let stopSpin = UIPanGestureRecognizer(target: context.coordinator,
                                              action: #selector(Coordinator.userGrabbedGlobe(_:)))
        stopSpin.cancelsTouchesInView = false
        stopSpin.delegate = context.coordinator
        view.addGestureRecognizer(stopSpin)

        let squish = UITapGestureRecognizer(target: context.coordinator,
                                            action: #selector(Coordinator.userTappedGlobe(_:)))
        squish.cancelsTouchesInView = false
        squish.delegate = context.coordinator
        view.addGestureRecognizer(squish)

        context.coordinator.globeNode = globe
        context.coordinator.lastVisited = visited
        context.coordinator.lastVisitedStates = visitedStates
        context.coordinator.lastStyle = style
        applyTexture(to: globe, coordinator: context.coordinator, newCodes: [], tourAll: true)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        guard let globe = view.scene?.rootNode.childNode(withName: "globe", recursively: true) else { return }

        // Re-texture only when the visited sets or the style actually change.
        if context.coordinator.lastVisited != visited
            || context.coordinator.lastVisitedStates != visitedStates
            || context.coordinator.lastStyle != style {
            let newCodes = visited.subtracting(context.coordinator.lastVisited)
            // Flags appearing for the first time (style just switched to
            // planted) get the full tour; otherwise only new countries do.
            let firstPlanting = context.coordinator.lastStyle != .planted
            context.coordinator.lastVisited = visited
            context.coordinator.lastVisitedStates = visitedStates
            context.coordinator.lastStyle = style
            applyTexture(to: globe, coordinator: context.coordinator, newCodes: newCodes,
                         tourAll: firstPlanting)
        }
    }

    // MARK: - Planted flags

    /// In the planted style, a little flag on a pole for every visited
    /// country, parented to the globe so it spins with the map. The cloth
    /// turns about its pole to face the camera and waves gently; brand-new
    /// countries' flags pop up from nothing.
    @discardableResult
    private static func plantFlags(on globe: SCNNode, style: GlobeStyle,
                                   codes: Set<String>, newCodes: Set<String>,
                                   tourAll: Bool, tourDisabled: Bool,
                                   front: simd_float3, schedule: Tour) -> [SCNNode] {
        globe.childNode(withName: "flags", recursively: false)?.removeFromParentNode()
        guard style == .planted, !codes.isEmpty else { return [] }
        let root = SCNNode()
        root.name = "flags"
        let atlas = CountryAtlas.shared
        var vanes: [SCNNode] = []

        let poleHeight: CGFloat = 0.13
        let pole = SCNCylinder(radius: 0.0045, height: poleHeight)
        pole.firstMaterial = clayMaterial(UIColor(red: 0.94, green: 0.91, blue: 0.85, alpha: 1))
        let knob = SCNSphere(radius: 0.0095)
        knob.firstMaterial = clayMaterial(CountryAtlas.Clay.visited)

        // Every flag's site, resolved once.
        struct Site { let code: String; let lat: Float; let lon: Float; let image: UIImage }
        let sites: [Site] = codes.sorted().compactMap { code in
            guard let site = atlas.flagSite(forAlpha3: code),
                  let image = atlas.flagImage(forAlpha3: code) else { return nil }
            return Site(code: code, lat: Float(site.latitude) * .pi / 180,
                        lon: Float(site.longitude) * .pi / 180, image: image)
        }
        // The tour: the flags being planted now (all of them when flags first
        // appear, only the new ones after a scan; none when a country is
        // removed or a state toggled), two a second, east to west so the
        // globe turns the way the Earth does. Marketing captures skip it.
        let touring: Set<String> = tourDisabled ? []
            : (tourAll ? Set(sites.map(\.code)) : newCodes)
        let tour = sites.filter { touring.contains($0.code) }.sorted { $0.lon > $1.lon }
        let tourIndex = Dictionary(uniqueKeysWithValues: tour.enumerated().map { ($1.code, $0) })
        // Two a second, starting once the world has finished growing in.
        // Per stop: a gentle turn (0.28s), then the flag rises and settles
        // (0.22s) while the globe holds still, then on to the next.
        let tourStart = 1.3, tourStep = 0.5, tourTurn = 0.28

        for site in sites {
            let code = site.code, image = site.image
            let lat = site.lat, lon = site.lon
            let dir = simd_float3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))

            let flag = SCNNode()
            flag.name = "flag-\(code)"
            // Just inside the raised piece, so the pole grows out of the clay.
            flag.simdPosition = dir * 1.028
            flag.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: dir)

            let poleNode = SCNNode(geometry: pole)
            poleNode.position = SCNVector3(0, Float(poleHeight) / 2, 0)
            poleNode.castsShadow = false
            flag.addChildNode(poleNode)

            let knobNode = SCNNode(geometry: knob)
            knobNode.position = SCNVector3(0, Float(poleHeight) + 0.004, 0)
            knobNode.castsShadow = false
            flag.addChildNode(knobNode)

            // The cloth hangs off the pole and is turned toward the camera
            // about the POLE's own axis every frame (Coordinator.renderer). A
            // billboard constraint turns about the world's up axis instead,
            // which drags the hoist and its ties sideways off a leaning pole.
            let clothWidth: CGFloat = 0.09
            let clothHeight = clothWidth * image.size.height / max(1, image.size.width)
            let vane = SCNNode()
            vane.name = "vane"
            vane.position = SCNVector3(0, Float(poleHeight - clothHeight / 2) - 0.004, 0)
            vanes.append(vane)

            let hinge = SCNNode()
            // Subdivided so the cloth can actually deform. A plain SCNPlane is
            // two triangles: rotating it about the pole was the only motion
            // available, which reads as a rigid card swinging on a hinge.
            let cloth = SCNPlane(width: clothWidth, height: clothHeight)
            cloth.widthSegmentCount = 28
            cloth.heightSegmentCount = 12
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = image
            material.roughness.contents = NSNumber(value: 0.9)
            material.metalness.contents = NSNumber(value: 0)
            material.isDoubleSided = true
            // The wave runs on the GPU, driven by u_time, so every flag ripples
            // continuously without per-frame work on our side. The displacement
            // is scaled by `hoist` (0 at the pole, 1 at the fly), which is what
            // keeps the pole-side edge welded to the pole along its whole
            // length rather than the cloth pivoting off a single point.
            material.shaderModifiers = [.geometry: Self.clothWaveShader]
            material.setValue(NSNumber(value: Float(clothWidth)), forKey: "clothWidth")
            // Each flag on its own beat, so a continent of them does not pulse
            // in unison.
            material.setValue(NSNumber(value: Float(abs(code.hashValue % 628)) / 100),
                              forKey: "wavePhase")
            cloth.firstMaterial = material
            let clothNode = SCNNode(geometry: cloth)
            clothNode.position = SCNVector3(0.0045 + Float(clothWidth) / 2, 0, 0)
            clothNode.castsShadow = false
            hinge.addChildNode(clothNode)
            vane.addChildNode(hinge)

            // Two ties where the cloth meets the pole, at the top and bottom
            // of the hoist, so the attachment reads at a glance.
            let tieRing = SCNTorus(ringRadius: 0.0068, pipeRadius: 0.0022)
            tieRing.ringSegmentCount = 24
            tieRing.pipeSegmentCount = 8
            tieRing.firstMaterial = knob.firstMaterial
            for y in [clothHeight / 2, -clothHeight / 2] {
                let tie = SCNNode(geometry: tieRing)
                tie.position = SCNVector3(0, Float(y), 0)
                tie.castsShadow = false
                vane.addChildNode(tie)
            }
            flag.addChildNode(vane)

            if let i = tourIndex[code] {
                // Rises as the globe turns it to the front (see runTour).
                flag.scale = SCNVector3(0.01, 0.01, 0.01)
                let rise = SCNAction.scale(to: 1.12, duration: 0.15)
                rise.timingMode = .easeOut
                let settle = SCNAction.scale(to: 1, duration: 0.07)
                settle.timingMode = .easeInEaseOut
                flag.runAction(.sequence([.wait(duration: tourStart + Double(i) * tourStep), rise, settle]))
            }
            root.addChildNode(flag)
        }
        globe.addChildNode(root)
        if !tour.isEmpty {
            runTour(on: globe, stops: tour.map { (lat: $0.lat, lon: $0.lon) }, front: front,
                    start: tourStart, step: tourStep, turn: tourTurn, tour: schedule)
        }
        return vanes
    }

    /// Schedules the globe's tour: each flag's stop comes to the front of the
    /// ball, a little above centre so the cloth is seen face-on rather than
    /// down its pole; when the last one is in, the equator is levelled and the
    /// world gets a flourish spin along it before settling into its idle
    /// turn. The motion itself is evaluated against the render clock in
    /// Coordinator.renderer (see `Tour`), which keeps it in step with the
    /// flags' rise actions.
    private static func runTour(on globe: SCNNode, stops: [(lat: Float, lon: Float)],
                                front: simd_float3, start: Double, step: Double, turn: Double,
                                tour: Tour) {
        globe.removeAction(forKey: "spin")
        // Where the camera is, as yaw and pitch, so the tour faces whoever is
        // looking even after the globe has been orbited.
        let cam = simd_length(front) > 0.001 ? simd_normalize(front) : simd_float3(0, 0, 1)
        let camYaw = atan2(cam.x, cam.z)
        let camPitch = asin(max(-1, min(1, cam.y)))
        // Apparent height above the ball's centre line, as it reads ON SCREEN:
        // 30 degrees up, i.e. the pole base at half the globe's screen radius.
        // The front of the ball is nearer the camera than its rim, so a point
        // at sphere elevation e projects to d*sin(e)/(d - cos(e)) of the rim's
        // radius; solve that for the sphere elevation that lands at sin(30).
        let apparent: Float = 0.52
        let distance = max(1.2, simd_length(front))
        let wanted = sin(apparent)
        var lo: Float = 0, hi: Float = apparent
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let projected = distance * sin(mid) / (distance - cos(mid))
            if projected < wanted { lo = mid } else { hi = mid }
        }
        let elevation = (lo + hi) / 2
        let up = simd_float3(0, 1, 0), right = simd_float3(1, 0, 0)

        let scheduled = stops.enumerated().map { i, stop in
            // Pitch: after the yaw brings the stop to the front meridian it
            // sits at its own latitude; a rotation about x by (lat - elevation)
            // brings it down to `elevation` above the camera's line of sight
            // (rotating by +a about x moves a front-meridian point DOWN by a).
            // The tilt is capped at 54 degrees: a far-southern stop would
            // otherwise flip the globe past the pole to lift it, which reads as
            // the world turning upside down rather than turning to face you.
            let tilt = max(-0.95, min(0.95, stop.lat - camPitch - elevation))
            return Tour.Stop(arrive: start + Double(i) * step,
                             orientation: simd_quatf(angle: camYaw, axis: up)
                                 * simd_quatf(angle: tilt, axis: right)
                                 * simd_quatf(angle: -stop.lon, axis: up))
        }
        // Settle with the last stop still in front and the globe tipped so
        // 30 degrees north faces the viewer; the spin then runs about the
        // globe's own axis at that tilt.
        let restingTilt = 0.52 + camPitch     // 30 degrees north comes down to centre
        tour.begin(stops: scheduled, turn: turn,
                   restOuter: simd_quatf(angle: camYaw, axis: up) * simd_quatf(angle: restingTilt, axis: right),
                   restYaw: -stops[stops.count - 1].lon)
    }

    /// The globe's scripted turn, evaluated per frame on the render thread.
    /// Written on the main thread when flags are planted, read every frame.
    nonisolated final class Tour: @unchecked Sendable {
        struct Stop {
            let arrive: Double
            let orientation: simd_quatf
        }
        private let lock = NSLock()
        private var stops: [Stop] = []
        /// Resting pose = restOuter * Ry(restYaw + spin): the outer part holds
        /// the camera yaw and the 30-degrees-north tilt, the inner yaw is what
        /// the flourish and idle spin turn, so the globe spins about its own
        /// tilted axis rather than wobbling about the world's.
        private var restOuter = simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        private var restYaw: Float = 0
        private var turn = 0.2
        private var levelAt = 0.0
        private var flourishAt = 0.0
        private let flourishLength = 3.4
        private let idleLap = 60.0
        private var startTime: TimeInterval?
        private var initial: simd_quatf?
        private var active = false

        func begin(stops: [Stop], turn: Double, restOuter: simd_quatf, restYaw: Float) {
            lock.lock(); defer { lock.unlock() }
            self.stops = stops
            self.turn = turn
            self.restOuter = restOuter
            self.restYaw = restYaw
            let last = stops.last?.arrive ?? 0
            levelAt = last + 0.4
            flourishAt = levelAt + 0.5
            startTime = nil
            initial = nil
            active = !stops.isEmpty
        }

        /// Stops driving the globe (the user grabbed it).
        func cancel() { lock.lock(); active = false; lock.unlock() }

        /// The orientation for render time `time`, or nil when not touring.
        func orientation(at time: TimeInterval, current: simd_quatf) -> simd_quatf? {
            lock.lock(); defer { lock.unlock() }
            guard active else { return nil }
            if startTime == nil { startTime = time; initial = current }
            guard let startTime, let initial else { return nil }
            let t = time - startTime
            // Smootherstep: zero velocity AND acceleration at both ends, so
            // each turn starts and stops without a kick.
            func ease(_ x: Double) -> Float {
                let c = Float(min(1, max(0, x)))
                return c * c * c * (c * (c * 6 - 15) + 10)
            }
            let up = simd_float3(0, 1, 0)
            if t >= flourishAt {
                // One eased lap about the globe's own axis, then the slow idle turn.
                let u = t - flourishAt
                let spin: Float
                if u < flourishLength {
                    let x = Float(u / flourishLength)
                    spin = 2 * .pi * (1 - (1 - x) * (1 - x) * (1 - x))
                } else {
                    spin = 2 * .pi + Float((u - flourishLength) / idleLap) * 2 * .pi
                }
                return restOuter * simd_quatf(angle: restYaw + spin, axis: up)
            }
            if t >= levelAt, let last = stops.last {
                let rest = restOuter * simd_quatf(angle: restYaw, axis: up)
                return simd_slerp(last.orientation, rest, ease((t - levelAt) / 0.5))
            }
            var from = initial
            for stop in stops {
                if t < stop.arrive - turn { return from }
                if t < stop.arrive {
                    return simd_slerp(from, stop.orientation, ease((t - (stop.arrive - turn)) / turn))
                }
                from = stop.orientation
            }
            return from
        }
    }

    /// Warps the cloth into a travelling wave.
    ///
    /// Time comes from `scn_frame.time`, not `u_time`: the latter is the GLSL
    /// name and does not exist on the Metal path, so the modifier fails to
    /// compile and SceneKit falls back to flat magenta.
    ///
    /// `hoist` is 0 at the pole edge and 1 at the free edge, and every
    /// displacement is multiplied by it, so the whole pole-side edge stays
    /// pinned, so the flag reads as attached along the pole rather than hinged at
    /// a point. The z ripple is the wave itself; the small y sag and the slight
    /// x pull-in stop it looking like a flat sheet being wobbled.
    private static let clothWaveShader = """
    #pragma arguments
    float clothWidth;
    float wavePhase;
    #pragma body
    float hoist = clamp((_geometry.position.x + clothWidth * 0.5) / max(clothWidth, 0.0001), 0.0, 1.0);
    float t = scn_frame.time * 2.1 + wavePhase;
    float ripple = sin(hoist * 7.5 - t) * 0.012 + sin(hoist * 3.1 - t * 0.7) * 0.006;
    _geometry.position.z += ripple * hoist;
    _geometry.position.y += sin(hoist * 4.2 - t * 1.15) * 0.004 * hoist;
    _geometry.position.x -= hoist * hoist * 0.004;
    // Tilt the normal with the slope of the ripple so the light catches the
    // folds; without this the cloth moves but stays lit like a flat card.
    // Slope of z along the cloth per unit of width, tilting the normal in x
    // (tilting z alone would normalize straight back to flat).
    float slope = cos(hoist * 7.5 - t) * 7.5 * 0.012 * hoist / max(clothWidth, 0.0001);
    _geometry.normal = normalize(float3(-slope, 0.0, 1.0));
    """

    // MARK: - Lighting

    /// Warm key from the upper left with soft shadows (so clouds and the
    /// plane throw shadows onto the map), a cool fill from the lower right,
    /// and a rim from behind so the silhouette catches an edge of light.
    private static func makeLightRig() -> SCNNode {
        let rig = SCNNode()
        rig.name = "lightRig"

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 1450
        key.light?.color = UIColor(red: 1.0, green: 0.95, blue: 0.86, alpha: 1)
        key.light?.castsShadow = true
        key.light?.shadowMode = .forward
        key.light?.shadowColor = UIColor(white: 0.05, alpha: 0.42)
        key.light?.shadowRadius = 9
        key.light?.shadowSampleCount = 16
        key.light?.shadowMapSize = CGSize(width: 2048, height: 2048)
        key.position = SCNVector3(-1.6, 1.9, 0.9)
        key.look(at: SCNVector3(0, 0, -cameraDistance))
        rig.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .directional
        fill.light?.intensity = 320
        fill.light?.color = UIColor(red: 0.74, green: 0.82, blue: 1.0, alpha: 1)
        fill.position = SCNVector3(1.8, -1.2, 0.6)
        fill.look(at: SCNVector3(0, 0, -cameraDistance))
        rig.addChildNode(fill)

        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 420
        rim.light?.color = UIColor(red: 0.85, green: 0.92, blue: 1.0, alpha: 1)
        rim.position = SCNVector3(1.4, 1.1, -cameraDistance - 2.2)
        rim.look(at: SCNVector3(0, 0, -cameraDistance))
        rig.addChildNode(rim)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 150
        ambient.light?.color = UIColor(red: 0.62, green: 0.66, blue: 0.86, alpha: 1)
        rig.addChildNode(ambient)

        return rig
    }

    /// A 2:1 gradient panorama for image-based lighting: sky above, a warm
    /// band at the horizon, dusty bounce below. Tiny, since it's only ever
    /// sampled as blurred light.
    private static func environmentImage() -> UIImage {
        let size = CGSize(width: 256, height: 128)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let colors = [
                UIColor(red: 0.70, green: 0.80, blue: 0.98, alpha: 1).cgColor,
                UIColor(red: 0.88, green: 0.90, blue: 0.97, alpha: 1).cgColor,
                UIColor(red: 0.98, green: 0.90, blue: 0.80, alpha: 1).cgColor,
                UIColor(red: 0.42, green: 0.38, blue: 0.52, alpha: 1).cgColor,
            ]
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                            colors: colors as CFArray,
                                            locations: [0, 0.42, 0.56, 1]) else { return }
            ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                             end: CGPoint(x: 0, y: size.height), options: [])
        }
    }

    // MARK: - Clay props

    /// Matte clay in one colour.
    private static func clayMaterial(_ color: UIColor, roughness: Double = 0.9) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = NSNumber(value: roughness)
        m.metalness.contents = NSNumber(value: 0)
        return m
    }

    /// Five puffy clouds on three tilted orbits, each hovering just off the
    /// surface and drifting at its own pace.
    private static func makeClouds() -> SCNNode {
        let root = SCNNode()
        root.name = "clouds"
        let material = clayMaterial(UIColor(red: 0.99, green: 0.98, blue: 0.96, alpha: 1), roughness: 0.95)

        // (orbit tilt x, tilt z, seconds per lap, [(latitude°, longitude°, scale)])
        let orbits: [(Float, Float, Double, [(Float, Float, Float)])] = [
            (0.35, 0.15, 150, [(28, 20, 1.0), (-18, 200, 0.85)]),
            (-0.25, -0.4, -190, [(48, 110, 0.8), (-38, 300, 1.05)]),
            (0.1, 0.55, 230, [(8, 250, 0.9)]),
        ]
        for (tiltX, tiltZ, seconds, clouds) in orbits {
            let orbit = SCNNode()
            orbit.eulerAngles = SCNVector3(tiltX, 0, tiltZ)
            for (lat, lon, scale) in clouds {
                let cloud = makeCloud(material: material)
                let radius: Float = 1.11
                let latR = lat * .pi / 180, lonR = lon * .pi / 180
                let dir = simd_float3(cos(latR) * sin(lonR), sin(latR), cos(latR) * cos(lonR))
                cloud.simdPosition = dir * radius
                // Local +Y points away from the ball so the puffs sit flat on it.
                cloud.simdOrientation = simd_quatf(from: simd_float3(0, 1, 0), to: simd_normalize(dir))
                cloud.scale = SCNVector3(scale, scale * 0.7, scale)
                // A slow bob, so the clouds feel like they hover.
                let bob = SCNAction.sequence([
                    SCNAction.moveBy(x: CGFloat(dir.x) * 0.015, y: CGFloat(dir.y) * 0.015,
                                     z: CGFloat(dir.z) * 0.015, duration: 2.6),
                    SCNAction.moveBy(x: CGFloat(-dir.x) * 0.015, y: CGFloat(-dir.y) * 0.015,
                                     z: CGFloat(-dir.z) * 0.015, duration: 2.6),
                ])
                bob.timingMode = .easeInEaseOut
                cloud.runAction(.repeatForever(bob))
                orbit.addChildNode(cloud)
            }
            let lap = SCNAction.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: abs(seconds))
            orbit.runAction(.repeatForever(seconds < 0 ? lap.reversed() : lap))
            root.addChildNode(orbit)
        }
        return root
    }

    /// One cloud: a few overlapping clay balls.
    private static func makeCloud(material: SCNMaterial) -> SCNNode {
        let cloud = SCNNode()
        let puffs: [(Float, Float, Float, CGFloat)] = [
            (0, 0, 0, 0.078), (0.075, -0.012, 0.01, 0.058), (-0.07, -0.01, -0.005, 0.054),
            (0.03, 0.03, -0.035, 0.05), (-0.025, 0.028, 0.04, 0.046), (0.0, -0.02, 0.06, 0.044),
        ]
        for (x, y, z, r) in puffs {
            let sphere = SCNSphere(radius: r)
            sphere.segmentCount = 28
            sphere.firstMaterial = material
            let puff = SCNNode(geometry: sphere)
            puff.position = SCNVector3(x, y, z)
            cloud.addChildNode(puff)
        }
        return cloud
    }

    /// A chubby clay airplane on a tilted orbit, nose into the wind, banking
    /// a touch, circling the world once every half minute.
    private static func makePlaneOrbit() -> SCNNode {
        let orbit = SCNNode()
        orbit.name = "planeOrbit"
        orbit.eulerAngles = SCNVector3(0.42, 0, -0.55)

        let plane = SCNNode()
        plane.name = "plane"
        let white = clayMaterial(UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1))
        let orange = clayMaterial(CountryAtlas.Clay.visited)
        let blue = clayMaterial(UIColor(red: 0.36, green: 0.62, blue: 0.95, alpha: 1))

        // Fuselage along +X (the direction of travel), wings spanning local Y
        // (tangent to the ball), fin sticking out along +Z (away from the ball).
        let body = SCNCapsule(capRadius: 0.026, height: 0.16)
        body.firstMaterial = white
        let bodyNode = SCNNode(geometry: body)
        bodyNode.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
        plane.addChildNode(bodyNode)

        let nose = SCNSphere(radius: 0.027)
        nose.firstMaterial = blue
        let noseNode = SCNNode(geometry: nose)
        noseNode.position = SCNVector3(0.068, 0, 0)
        plane.addChildNode(noseNode)

        let wing = SCNBox(width: 0.055, height: 0.21, length: 0.014, chamferRadius: 0.007)
        wing.chamferSegmentCount = 8
        wing.firstMaterial = orange
        let wingNode = SCNNode(geometry: wing)
        wingNode.position = SCNVector3(0.008, 0, -0.004)
        // Swept back a touch.
        wingNode.eulerAngles = SCNVector3(0, 0, 0)
        plane.addChildNode(wingNode)

        let tail = SCNBox(width: 0.04, height: 0.095, length: 0.012, chamferRadius: 0.006)
        tail.chamferSegmentCount = 8
        tail.firstMaterial = orange
        let tailNode = SCNNode(geometry: tail)
        tailNode.position = SCNVector3(-0.066, 0, 0)
        plane.addChildNode(tailNode)

        let fin = SCNBox(width: 0.046, height: 0.012, length: 0.05, chamferRadius: 0.006)
        fin.chamferSegmentCount = 8
        fin.firstMaterial = orange
        let finNode = SCNNode(geometry: fin)
        finNode.position = SCNVector3(-0.064, 0, 0.03)
        plane.addChildNode(finNode)

        plane.position = SCNVector3(0, 0, 1.32)
        // A slight bank into the turn.
        plane.eulerAngles = SCNVector3(0.18, 0, 0)
        // And a gentle bob, so it flies rather than slides.
        let bob = SCNAction.sequence([
            SCNAction.moveBy(x: 0, y: 0, z: 0.03, duration: 1.7),
            SCNAction.moveBy(x: 0, y: 0, z: -0.03, duration: 1.7),
        ])
        bob.timingMode = .easeInEaseOut
        plane.runAction(.repeatForever(bob))
        orbit.addChildNode(plane)
        orbit.runAction(.repeatForever(.rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 32)))
        return orbit
    }

    // MARK: - Entrance

    /// The world's entrance: grows from nothing to full size over a second
    /// on an ease-out-back curve, one soft overshoot of about ten percent
    /// that settles without a second bounce.
    private static func growIn() -> SCNAction {
        let length = 1.1
        return SCNAction.customAction(duration: length) { node, elapsed in
            let x = Float(min(1, max(0, Double(elapsed) / length)))
            let k: Float = 1.4                       // overshoot strength
            let u = x - 1
            let s = max(0.001, 1 + (k + 1) * u * u * u + k * u * u)
            node.scale = SCNVector3(s, s, s)
        }
    }

    // MARK: - Squish

    /// The jelly wobble when the ball is tapped: it squashes wide, springs
    /// tall, and settles, like poking a lump of dough.
    fileprivate static func squish(_ globe: SCNNode) {
        globe.removeAction(forKey: "squish")
        let wobble = SCNAction.customAction(duration: 0.9) { node, elapsed in
            let t = Float(elapsed) / 0.9
            let a = 0.11 * exp(-4.2 * t) * sin(t * .pi * 2 * 2.4)
            node.scale = SCNVector3(1 + a, 1 - a * 1.15, 1 + a)
        }
        globe.runAction(SCNAction.sequence([wobble, SCNAction.scale(to: 1, duration: 0.05)]),
                        forKey: "squish")
    }

    // MARK: - Texture

    /// Renders the colour texture and the relief maps off the main thread,
    /// then swaps them in. A generation counter drops stale renders from rapid
    /// visited changes.
    /// Flags are planted from here too, once the map is actually on the ball,
    /// never into a bare placeholder.
    private func applyTexture(to node: SCNNode, coordinator: Coordinator,
                              newCodes: Set<String>, tourAll: Bool) {
        let snapshot = visited
        let statesSnapshot = visitedStates
        let styleSnapshot = style
        coordinator.textureGeneration += 1
        let generation = coordinator.textureGeneration
        coordinator.renderTicket.bump(to: generation)
        let ticket = coordinator.renderTicket
        Task.detached(priority: .userInitiated) {
            let atlas = CountryAtlas.shared
            #if DEBUG
            let started = Date()
            #endif
            let texture = atlas.globeTexture(visited: snapshot, visitedStates: statesSnapshot,
                                             style: styleSnapshot)
            // A newer visited set arrived mid-render: don't spend the relief
            // pass on a texture that's already stale.
            guard ticket.isCurrent(generation) else { return }
            let relief = atlas.reliefMaps(visited: snapshot, visitedStates: statesSnapshot)
            #if DEBUG
            print("[ClayGlobe] textures rendered in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            #endif
            await MainActor.run {
                guard coordinator.textureGeneration == generation else { return }
                let material = SCNMaterial()
                // Matte plasticine: rough, not a hint of metal, so highlights
                // spread into a soft sheen instead of a wet hotspot.
                material.lightingModel = .physicallyBased
                material.roughness.contents = NSNumber(value: 0.86)
                material.metalness.contents = NSNumber(value: 0)

                material.diffuse.contents = texture
                // Trilinear mips + anisotropy: the 4K texture minifies onto the
                // sphere, and without these it shimmers and aliases while spinning.
                material.diffuse.mipFilter = .linear
                material.diffuse.magnificationFilter = .linear
                material.diffuse.maxAnisotropy = 8
                // Equirectangular texture wraps around the sphere: sampling
                // must wrap horizontally too, or filtering shows a seam at the
                // antimeridian (SceneKit defaults to clamp).
                material.diffuse.wrapS = .repeat
                material.diffuse.wrapT = .clamp

                // Raised clay: land stands off the ball, visited pieces higher.
                material.displacement.contents = relief.displacement
                material.displacement.intensity = 0.036
                material.displacement.wrapS = .repeat
                material.displacement.wrapT = .clamp
                material.displacement.mipFilter = .linear

                // Bevelled edges, pressed seams and thumbprint grain.
                material.normal.contents = relief.normal
                material.normal.intensity = 1
                material.normal.wrapS = .repeat
                material.normal.wrapT = .clamp
                material.normal.mipFilter = .linear
                material.normal.maxAnisotropy = 8

                material.shaderModifiers = [.surface: Self.rimModifier]
                node.geometry?.materials = [material]

                // The world is textured: grow it in with a bounce, then plant
                // the flags into it.
                if let world = node.parent, world.name == "world", world.opacity < 1 {
                    world.opacity = 1
                    world.scale = SCNVector3(0.001, 0.001, 0.001)
                    world.runAction(Self.growIn(), forKey: "grow")
                }
                let front = coordinator.view?.pointOfView?.simdWorldPosition
                    ?? simd_float3(0, 0, Self.cameraDistance)
                coordinator.vanes.replace(
                    Self.plantFlags(on: node, style: styleSnapshot, codes: snapshot,
                                    newCodes: newCodes, tourAll: tourAll,
                                    tourDisabled: self.configuration.holdsStill,
                                    front: front,
                                    schedule: coordinator.tour))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Flag cloth pivots: written on the main thread when flags are planted,
    /// read on the render thread every frame.
    nonisolated final class VaneList: @unchecked Sendable {
        private let lock = NSLock()
        private var nodes: [SCNNode] = []
        func replace(_ new: [SCNNode]) { lock.lock(); nodes = new; lock.unlock() }
        func snapshot() -> [SCNNode] { lock.lock(); defer { lock.unlock() }; return nodes }
    }

    /// The latest texture generation, readable off the main thread.
    nonisolated final class RenderTicket: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        func bump(to generation: Int) { lock.lock(); current = generation; lock.unlock() }
        func isCurrent(_ generation: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return current == generation
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate, SCNSceneRendererDelegate {
        var lastVisited: Set<String> = []
        var lastVisitedStates: Set<String> = []
        var lastStyle: GlobeStyle = .clay
        var textureGeneration = 0
        /// Thread-safe mirror of `textureGeneration` for the render task.
        let renderTicket = RenderTicket()
        /// Read on SceneKit's render thread (see `renderer(_:updateAtTime:)`).
        nonisolated(unsafe) weak var globeNode: SCNNode?
        nonisolated(unsafe) weak var lightRig: SCNNode?
        /// The planted flags' cloth pivots, turned toward the camera each frame.
        let vanes = VaneList()
        /// The globe's scripted presentation of newly planted flags.
        let tour = Tour()
        weak var view: SCNView?

        @objc func userGrabbedGlobe(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .began {
                // Only the turning actions: a squish mid-way must run to
                // completion or the ball stays squashed.
                globeNode?.removeAction(forKey: "spin")
                tour.cancel()
            }
        }

        @objc func userTappedGlobe(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view, let globe = globeNode else { return }
            let point = gesture.location(in: view)
            let hits = view.hitTest(point, options: nil)
            guard hits.contains(where: { $0.node === globe }) else { return }
            // The package carries its own tap haptic rather than the host
            // app's helper; hosts that dislike it can intercept the gesture.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            ClayGlobeSceneView.squish(globe)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Keeps the light rig on whatever camera is live, every frame. Runs
        /// on SceneKit's render thread, hence nonisolated.
        nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let pov = renderer.pointOfView else { return }
            if let rig = lightRig {
                rig.simdWorldTransform = pov.simdWorldTransform
            }
            if let globe = globeNode,
               let turned = tour.orientation(at: time, current: globe.simdOrientation) {
                globe.simdOrientation = turned
            }
            // Each flag's cloth turns about its own pole to face the camera:
            // the camera position in the pole's frame, flattened onto the
            // plane the cloth swings in, gives the yaw directly.
            let camera = pov.simdWorldPosition
            for vane in vanes.snapshot() {
                guard let pole = vane.parent else { continue }
                let local = pole.simdConvertPosition(camera, from: nil)
                vane.simdOrientation = simd_quatf(angle: atan2(local.x, local.z), axis: simd_float3(0, 1, 0))
            }
        }
    }
}
