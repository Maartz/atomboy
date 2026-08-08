// The console shell: the plastic the screen lives in.
//
// Atomboy.swift draws the picture; this file draws the object holding it.
// In shell mode the window's content is a console — body, bezel, buttons —
// with the Metal layer sitting exactly in the screen cutout. ⌘B takes the
// body away and leaves the bare panel, which is the window this app has
// always had.
//
// Everything a body needs to know about itself lives in one BodyLayout:
// its silhouette's ratio and every rect on it, written as FRACTIONS of the
// body's size. The drawing and the screen placement read the same numbers,
// so the picture cannot drift out of its hole, and the console scales
// uniformly at any window size.
//
// Nothing here is an image. Every dome, groove and slot is a Path with a
// gradient on it, so the console is as crisp at 3× as it is in a corner of
// the display. And nothing here is clickable: the drawn controls are a
// mirror, not an input. They move because the player's hands moved
// somewhere real — a key, a gamepad — and the same event that reaches the
// engine reaches ConsoleState on its way past.

import SwiftUI
import AppKit

// ── The bodies ───────────────────────────────────────────────────────────────

// Four consoles, chosen by the panel preset — the screen and the plastic
// around it are one decision, not two.
enum ConsoleBody: String {
    case dmg, pocket, cgb, tv

    // The panel presets, by index: raw, dmg, pocket, cgb, crt. `raw` (the
    // default) wears the DMG body — a bare panel in a gray shell is still a
    // Game Boy, and first launch ought to show a console.
    static func forPanel(_ preset: Int) -> ConsoleBody {
        switch preset {
        case 2: return .pocket
        case 3: return .cgb
        case 4: return .tv
        default: return .dmg
        }
    }

    var layout: BodyLayout {
        switch self {
        case .dmg: return .dmg
        case .pocket: return .pocket
        case .cgb: return .cgb
        case .tv: return .tv
        }
    }
}

// The geometry of one console. Every rect is a fraction of the body's own
// size, origin top-left like SwiftUI's: multiply by the drawn size and you
// have points, whatever the window does.
struct BodyLayout {
    // Width ÷ height of the whole silhouette. This is the window's content
    // ratio in shell mode — per body, never per mode: the TV is landscape
    // and the window has to know it.
    let aspect: CGFloat

    // Corner radii, as fractions of the body's WIDTH (a radius is a length,
    // and a length on a body is read across it). The bottom right is its own
    // number because on a DMG it is the shape's signature: three tight
    // corners and one long sweep where the hand sits.
    let corner: CGFloat
    let cornerBottomRight: CGFloat
    let bezelCorner: CGFloat

    // The recessed plate the screen is sunk into, and the cutout itself.
    let bezel: CGRect
    let screen: CGRect

    // The controls. Measured off the real object, and now drawn from these
    // same numbers — the picture and the geometry have one source.
    let dpad: CGRect
    let buttonA: CGRect
    let buttonB: CGRect
    let select: CGRect
    let start: CGRect
    let speaker: CGRect
    let led: CGRect

    // The DMG-01, measured: 90 × 148 mm of gray plastic. Writing the numbers
    // in millimetres and dividing by the case keeps them checkable against a
    // ruler — and makes the fractions consistent for free.
    static let dmg: BodyLayout = {
        let width = 90.0, height = 148.0

        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x / width, y: y / height, width: w / width, height: h / height)
        }

        // The visible LCD is 47 mm across, and 10:9 like the 160 × 144 it
        // shows. Deriving the height from the width is what guarantees the
        // Metal layer gets its own ratio inside the body's.
        let viewport = 47.0

        return BodyLayout(
            aspect: width / height,
            corner: 6 / width,
            cornerBottomRight: 24 / width,
            bezelCorner: 5 / width,
            bezel: rect(7, 14, 76, 62),
            screen: rect((width - viewport) / 2, 27, viewport, viewport * 9 / 10),
            dpad: rect(11, 88, 24, 24),
            buttonA: rect(66.25, 89.25, 11.5, 11.5),
            buttonB: rect(54.75, 96.25, 11.5, 11.5),
            select: rect(28, 119.7, 13, 4.6),
            start: rect(41.5, 116.7, 13, 4.6),
            speaker: rect(58, 118, 20, 20),
            led: rect(9.4, 45.5, 4.2, 4.2))
    }()

    // TODO(Task 6): the Pocket's own silhouette — silver, slimmer, smaller.
    static let pocket = BodyLayout.dmg

    // TODO(Task 6): the CGB — teal, and its button pair rotated southeast.
    static let cgb = BodyLayout.dmg

    // TODO(Task 7): the living-room TV — landscape, its own aspect, wood and
    // curved glass. The window ratio already comes from here, so the day this
    // stops aliasing the DMG the window turns on its side by itself.
    static let tv = BodyLayout.dmg

    // The largest body that fits, ratio kept. The window normally already has
    // this exact shape, so this only bites in fullscreen — where it centres
    // the console on black.
    func fit(in size: CGSize) -> CGSize {
        let wide = CGSize(width: size.width, height: size.width / aspect)
        return wide.height <= size.height
            ? wide
            : CGSize(width: size.height * aspect, height: size.height)
    }
}

// ── The mode, and what the window makes of it ────────────────────────────────

// One observable for the whole shell: whether the body is worn, and which
// one. The window's aspect ratio and the content both read from here.
final class ShellState: ObservableObject {
    static let shared = ShellState()

    // Legacy French UserDefaults key, like every other "reglages.*" name in
    // this app — these strings address data already on disk.
    private static let modeKey = "reglages.shell"
    private static let panelKey = "reglages.panneau"

    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.modeKey)
            relockGameWindows()
        }
    }

    @Published private(set) var console: ConsoleBody {
        didSet { relockGameWindows() }
    }

    private init() {
        let defaults = UserDefaults.standard
        // Absent means on: the console is what the app looks like out of the
        // box, and ⌘B is one keystroke away from today's plain window.
        enabled = defaults.object(forKey: Self.modeKey) as? Bool ?? true
        console = ConsoleBody.forPanel(defaults.object(forKey: Self.panelKey) as? Int ?? 0)
    }

    var layout: BodyLayout { console.layout }

    // The panel preset moved — from the settings picker on its way out, or
    // from the engine's 'P' on its way back. Either way the body follows,
    // live, while the game runs.
    func follow(panel index: Int) {
        let body = ConsoleBody.forPanel(index)
        if body != console { console = body }
    }

    // The window's content ratio: the body's silhouette when it is worn, the
    // panel's own 10:9 when it is not.
    var aspect: CGFloat {
        enabled ? layout.aspect : CGFloat(WIDTH) / CGFloat(HEIGHT)
    }

    // How much of the content's height the picture itself takes. On a DMG the
    // screen is barely a quarter of the body — which is the whole reason a
    // toggle has to think before it resizes.
    private var screenFraction: CGFloat { enabled ? layout.screen.height : 1 }

    // What the last lock left on screen: the memory that lets ⌘B keep the
    // GAME the same size instead of the window.
    private var appliedFraction: CGFloat = 1

    // The window learns its shape here — called when the screen view lands in
    // a window, and again whenever the mode or the body changes.
    func lockAspect(of window: NSWindow?) {
        guard let window else { return }

        window.contentAspectRatio = NSSize(width: aspect, height: 1)

        // Fullscreen has no ratio to give: the shell letterboxes itself on
        // black there, and resizing the window under macOS would be rude.
        guard !window.styleMask.contains(.fullScreen) else { return }

        let content = window.contentRect(forFrameRect: window.frame).size
        let fraction = screenFraction
        guard content.height > 0 else { return }
        guard abs(fraction - appliedFraction) > 0.0001 else {
            // Same mode as last time (a view remounting, a second window):
            // the ratio is set, nothing to resize.
            return
        }

        // The picture keeps its size and the plastic grows around it —
        // clamped to the display, because a DMG built around a 3× screen is
        // most of a metre of console.
        let room = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var height = content.height * appliedFraction / fraction
        if room.height > 0 { height = min(height, room.height * 0.9) }

        window.setContentSize(
            NSSize(width: (height * aspect).rounded(), height: height.rounded()))
        appliedFraction = fraction

        // setContentSize grows downward from the title bar's corner; a body
        // that tall walks off the bottom of the display. Bring it home.
        if room.height > 0, !room.contains(window.frame) { window.center() }
    }

    // The scale presets (⌘⌥1…5) mean the same thing in both modes: the
    // PICTURE at an exact multiple. In shell mode the body is sized so its
    // cutout comes out at that multiple.
    func contentSize(forScale n: Int) -> NSSize {
        let picture = NSSize(width: WIDTH * n, height: HEIGHT * n)
        guard enabled else { return picture }

        let body = layout
        return NSSize(
            width: (picture.width / body.screen.width).rounded(),
            height: (picture.height / body.screen.height).rounded())
    }

    private func relockGameWindows() {
        for window in NSApp.windows {
            guard let content = window.contentView, ScreenView.hosted(in: content) else { continue }
            lockAspect(of: window)
        }
    }
}

// ── The pulse ────────────────────────────────────────────────────────────────

// What the drawn console feels. Eight buttons and a power light, held here
// and nowhere else: the two real input paths (the keyboard handler and the
// GameController callbacks) set these on their way to the engine's stdin,
// and the art reads them. Nothing in this file ever writes them — a drawn
// button is a mirror, and a mirror does not push back.
final class ConsoleState: ObservableObject {
    static let shared = ConsoleState()

    @Published private(set) var up = false
    @Published private(set) var down = false
    @Published private(set) var left = false
    @Published private(set) var right = false
    @Published private(set) var a = false
    @Published private(set) var b = false
    @Published private(set) var start = false
    @Published private(set) var select = false

    // The engine's life, as the LED shows it: lit while it runs, an ember
    // while it is paused, dark once it is gone.
    @Published private(set) var powered = false
    @Published private(set) var paused = false

    private init() {}

    var glow: PowerLED.Glow {
        guard powered else { return .dark }
        return paused ? .ember : .lit
    }

    // The protocol letter is the common tongue: the keyboard resolves it
    // through Keybind (so a remapped key still moves the right plastic) and
    // the gamepad names it directly. Anything else — turbo, rewind, the
    // menu — has no button drawn on the case, and falls through.
    func apply(_ letter: Character, pressed: Bool) {
        switch letter {
        case "U": set(\.up, pressed)
        case "D": set(\.down, pressed)
        case "L": set(\.left, pressed)
        case "R": set(\.right, pressed)
        case "A": set(\.a, pressed)
        case "B": set(\.b, pressed)
        case "S": set(\.start, pressed)
        case "E": set(\.select, pressed)
        default: break
        }
    }

    // A gamepad walking away, or an engine dying with fingers still down:
    // no button stays held on a console nobody is touching.
    func releaseAll() {
        for path in [\ConsoleState.up, \.down, \.left, \.right, \.a, \.b, \.start, \.select] {
            set(path, false)
        }
    }

    func power(_ on: Bool) {
        set(\.powered, on)
        if !on { set(\.paused, false) }
    }

    func pause(_ on: Bool) { set(\.paused, on) }

    func togglePause() { set(\.paused, !paused) }

    // @Published is a main-thread promise. The keyboard path is already on
    // it and the gamepad handlers hop to it before they call, but the guard
    // is one line and the alternative is a SwiftUI crash nobody can
    // reproduce. Unchanged values are dropped: key repeat should not redraw
    // a console that has not moved.
    private func set(_ path: ReferenceWritableKeyPath<ConsoleState, Bool>, _ value: Bool) {
        if Thread.isMainThread {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        } else {
            DispatchQueue.main.async { self.set(path, value) }
        }
    }
}

// ── The menu item ────────────────────────────────────────────────────────────

// ⌘B, next to the scale presets in the View menu. A Toggle in a command
// group is the Mac idiom: a checkmark that says whether the body is on.
struct ShellToggle: View {
    @ObservedObject private var shell = ShellState.shared

    var body: some View {
        Toggle("Console Body", isOn: $shell.enabled)
            .keyboardShortcut("b")
    }
}

// ── The content: the body, or the bare screen ────────────────────────────────

// What MainScene puts under the HUD. Plain mode is exactly the window this
// app has always had — the Screen, edge to edge, nothing wrapped around it.
struct ShellContent: View {
    let engine: Engine
    @ObservedObject private var shell = ShellState.shared

    var body: some View {
        if shell.enabled {
            ConsoleView(engine: engine, console: shell.console, layout: shell.layout)
        } else {
            Screen(engine: engine)
        }
    }
}

struct ConsoleView: View {
    let engine: Engine
    let console: ConsoleBody
    let layout: BodyLayout

    var body: some View {
        GeometryReader { geo in
            let size = layout.fit(in: geo.size)

            ConsoleBodyArt(engine: engine, console: console, layout: layout)
                .frame(width: size.width, height: size.height)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
    }
}

// Which case the panel preset put us in. Three of the four are still the
// DMG on purpose — Tasks 6 and 7 fill them, and until they do a player who
// picks the Pocket palette gets a working console rather than a hole.
struct ConsoleBodyArt: View {
    let engine: Engine
    let console: ConsoleBody
    let layout: BodyLayout

    var body: some View {
        switch console {
        case .dmg, .pocket, .cgb, .tv:
            DMGBody(engine: engine, layout: layout)
        }
    }
}

// ── The plastics ─────────────────────────────────────────────────────────────

extension Color {
    // Written the way a paint chip is: the values below were read off
    // photographs of the real cases.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

// One moulded colour in three tones: the lit crown of the dome, the body of
// the colour, and the shaded skirt where it meets the shell. Every primitive
// in this file takes one of these and nothing else — which is how a Pocket
// or a CGB will reuse the same buttons in another palette.
struct Plastic {
    let light: Color
    let base: Color
    let dark: Color

    init(_ light: UInt32, _ base: UInt32, _ dark: UInt32) {
        self.light = Color(hex: light)
        self.base = Color(hex: base)
        self.dark = Color(hex: dark)
    }

    // The DMG's five materials: the warm gray case, the near-black cross,
    // the burgundy face buttons, the gray pills and the sunken bezel.
    static let dmgShell = Plastic(0xD9D5CD, 0xC4C0B8, 0x9B978F)
    static let dmgCross = Plastic(0x4C4C51, 0x2C2C2E, 0x121214)
    static let dmgFace = Plastic(0xB24A76, 0x8E2A55, 0x521232)
    static let dmgPill = Plastic(0x8C8C94, 0x63636B, 0x35353B)
    static let dmgBezel = Plastic(0x54545A, 0x35353A, 0x18181C)
    // The grill is the case with holes in it: the same plastic for the lip
    // that catches the light, and the shadow of the cabinet underneath.
    static let dmgGrill = Plastic(0xE4E0D8, 0x6B6760, 0x403D38)
}

// ── The primitives ───────────────────────────────────────────────────────────

// A rounded rectangle that does not have to be rounded evenly. The DMG's
// silhouette is three tight corners and one long sweep; nothing in SwiftUI
// draws that, so we walk the four sides and let each vertex name its own
// radius.
struct BodyShape: Shape {
    var topLeft: CGFloat
    var topRight: CGFloat
    var bottomRight: CGFloat
    var bottomLeft: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: topRight)
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: bottomRight)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: bottomLeft)
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: topLeft)
        path.closeSubpath()
        return path
    }
}

// The D-pad's plus, with every corner — outer and inner — filleted the way
// moulded plastic always is.
struct CrossShape: Shape {
    // The bar's thickness, as a fraction of the whole cross.
    var arm: CGFloat = 0.35
    var fillet: CGFloat = 0.055

    func path(in rect: CGRect) -> Path {
        let bar = CGSize(width: rect.width * arm, height: rect.height * arm)
        let xs = [rect.minX, rect.midX - bar.width / 2, rect.midX + bar.width / 2, rect.maxX]
        let ys = [rect.minY, rect.midY - bar.height / 2, rect.midY + bar.height / 2, rect.maxY]

        // The twelve vertices of a plus, clockwise from the top-left of the
        // upper arm.
        let corners = [
            CGPoint(x: xs[1], y: ys[0]), CGPoint(x: xs[2], y: ys[0]),
            CGPoint(x: xs[2], y: ys[1]), CGPoint(x: xs[3], y: ys[1]),
            CGPoint(x: xs[3], y: ys[2]), CGPoint(x: xs[2], y: ys[2]),
            CGPoint(x: xs[2], y: ys[3]), CGPoint(x: xs[1], y: ys[3]),
            CGPoint(x: xs[1], y: ys[2]), CGPoint(x: xs[0], y: ys[2]),
            CGPoint(x: xs[0], y: ys[1]), CGPoint(x: xs[1], y: ys[1]),
        ]

        let radius = min(rect.width, rect.height) * fillet
        var path = Path()
        let last = corners[corners.count - 1]
        path.move(to: CGPoint(x: (last.x + corners[0].x) / 2, y: (last.y + corners[0].y) / 2))
        for i in corners.indices {
            let next = corners[(i + 1) % corners.count]
            path.addArc(tangent1End: corners[i], tangent2End: next, radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

// A button you can feel through the glass: a dome lit from above, a sheen
// on its crown, a rim where the moulding ends, and a shadow underneath.
// Pressed, the shadow collapses, the face darkens and the whole thing
// travels — the three things a finger actually does to plastic.
struct MoldedButton: View {
    let plastic: Plastic
    var shape: AnyShape = AnyShape(Circle())
    var pressed = false

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)

            dome(d)
                .overlay(sheen(d))
                .overlay(shape.fill(Color.black.opacity(pressed ? 0.26 : 0)))
                .clipShape(shape)
                .overlay(shape.stroke(Color.black.opacity(0.28), lineWidth: max(0.4, d * 0.02)))
                .shadow(
                    color: .black.opacity(pressed ? 0.20 : 0.42),
                    radius: pressed ? d * 0.025 : d * 0.08,
                    x: 0, y: pressed ? d * 0.012 : d * 0.06)
                .offset(y: pressed ? d * 0.045 : 0)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func dome(_ d: CGFloat) -> some View {
        shape.fill(
            RadialGradient(
                gradient: Gradient(colors: [plastic.light, plastic.base, plastic.dark]),
                center: UnitPoint(x: 0.38, y: 0.30),
                startRadius: 0, endRadius: d * 0.82))
    }

    private func sheen(_ d: CGFloat) -> some View {
        Ellipse()
            .fill(
                LinearGradient(
                    colors: [.white.opacity(pressed ? 0.16 : 0.40), .white.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom)
            )
            .frame(width: d * 0.56, height: d * 0.30)
            .offset(y: -d * 0.22)
            .blur(radius: d * 0.05)
    }
}

// SELECT and START: the same dome, stretched into a capsule and laid on the
// diagonal the face buttons already follow.
struct PillButton: View {
    let plastic: Plastic
    var tilt: Angle = .zero
    var pressed = false

    var body: some View {
        MoldedButton(plastic: plastic, shape: AnyShape(Capsule()), pressed: pressed)
            .rotationEffect(tilt)
    }
}

// The cross. It cannot travel like a button — it rocks, on the ball under
// its middle — so the pressed direction sinks in perspective and takes the
// light with it. The shading is the honest half: a tilt of nine degrees is
// easy to miss, a darkened arm is not.
struct DPad: View {
    let plastic: Plastic
    let up: Bool
    let down: Bool
    let left: Bool
    let right: Bool

    private var held: Bool { up || down || left || right }
    private var pitch: Double { up ? 9 : (down ? -9 : 0) }
    private var yaw: Double { right ? 9 : (left ? -9 : 0) }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)

            cross
                .overlay(shading)
                .overlay(dimple(d))
                .shadow(
                    color: .black.opacity(held ? 0.24 : 0.45),
                    radius: held ? d * 0.02 : d * 0.05,
                    x: 0, y: held ? d * 0.01 : d * 0.035)
                .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
                .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private var cross: some View {
        CrossShape()
            .fill(
                LinearGradient(
                    colors: [plastic.light, plastic.base, plastic.dark],
                    startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var shading: some View {
        ZStack {
            if up { edge(.top) }
            if down { edge(.bottom) }
            if left { edge(.leading) }
            if right { edge(.trailing) }
        }
    }

    private func edge(_ from: UnitPoint) -> some View {
        CrossShape().fill(
            LinearGradient(
                colors: [.black.opacity(0.40), .clear],
                startPoint: from, endPoint: .center))
    }

    // The dish in the middle, where the thumb sits between directions.
    private func dimple(_ d: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    gradient: Gradient(colors: [plastic.dark, plastic.base]),
                    center: UnitPoint(x: 0.5, y: 0.62),
                    startRadius: 0, endRadius: d * 0.16))
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: max(0.3, d * 0.008)))
            .frame(width: d * 0.30, height: d * 0.30)
    }
}

// Six slots on the diagonal, stacked along the corner they live in. The
// pale capsule under each one is the lip of the moulding catching the light
// — the cheapest possible inner shadow, and the only one that reads at this
// size.
struct SpeakerGrill: View {
    let plastic: Plastic
    var slots = 6

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let step = s * 0.115
            let thickness = s * 0.062

            ZStack {
                ForEach(0..<slots, id: \.self) { i in
                    let k = CGFloat(i) - CGFloat(slots - 1) / 2
                    let drift = k * step * 0.7071
                    slot(length: s * (0.56 - 0.04 * abs(k) / 2.5), thickness: thickness)
                        .position(
                            x: geo.size.width / 2 + drift,
                            y: geo.size.height / 2 + drift)
                }
            }
        }
    }

    private func slot(length: CGFloat, thickness: CGFloat) -> some View {
        ZStack {
            Capsule().fill(plastic.light.opacity(0.75)).offset(y: thickness * 0.28)
            Capsule().fill(
                LinearGradient(
                    colors: [plastic.dark, plastic.base],
                    startPoint: .top, endPoint: .bottom))
        }
        .frame(width: length, height: thickness)
        .rotationEffect(.degrees(-45))
    }
}

// The plate the screen is sunk into: dark, recessed, and printed. The two
// hairlines under its top edge and the script under the glass are the
// DMG's, and both are optional — the Pocket says something else there and
// the Color says nothing at all.
struct ScreenBezel: View {
    let plastic: Plastic
    let corner: CGFloat
    var stripes = false
    var script: String?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let plate = RoundedRectangle(cornerRadius: corner, style: .continuous)

            plate
                .fill(
                    LinearGradient(
                        colors: [plastic.dark, plastic.base, plastic.light],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(innerShadow(plate, size))
                .overlay(printing(size), alignment: .top)
        }
    }

    // A recess is a shadow cast by its own lip: a thick stroke, blurred,
    // nudged down, and faded out before it reaches the bottom.
    private func innerShadow(_ plate: RoundedRectangle, _ size: CGSize) -> some View {
        plate
            .stroke(Color.black.opacity(0.75), lineWidth: size.height * 0.06)
            .blur(radius: size.height * 0.025)
            .offset(y: size.height * 0.015)
            .mask(
                plate.fill(
                    LinearGradient(
                        colors: [.black, .black.opacity(0.15)],
                        startPoint: .top, endPoint: .bottom)))
    }

    @ViewBuilder private func printing(_ size: CGSize) -> some View {
        ZStack(alignment: .top) {
            if stripes {
                VStack(spacing: size.height * 0.016) {
                    Rectangle().fill(Color(hex: 0x8E2A46))
                    Rectangle().fill(Color(hex: 0x2E3192))
                }
                .frame(width: size.width * 0.90, height: size.height * 0.056)
                .offset(y: size.height * 0.055)
            }

            if let script {
                Text(script)
                    .font(.system(size: size.height * 0.046, weight: .medium, design: .serif))
                    .foregroundStyle(Color.white.opacity(0.70))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(width: size.width * 0.92)
                    .offset(y: size.height * 0.925)
            }
        }
    }
}

// The one light on the case. Lit while the engine runs, an ember while it
// is paused, and a dead lens once it has gone — a red dot with nothing
// behind it is exactly what a console with no batteries looks like.
struct PowerLED: View {
    enum Glow {
        case lit, ember, dark
    }

    let glow: Glow

    private var core: Color {
        switch glow {
        case .lit: return Color(hex: 0xFF3B30)
        case .ember: return Color(hex: 0x8E2018)
        case .dark: return Color(hex: 0x4A2420)
        }
    }

    private var rim: Color {
        switch glow {
        case .lit: return Color(hex: 0x8E0F10)
        case .ember: return Color(hex: 0x3E0E0C)
        case .dark: return Color(hex: 0x2A1412)
        }
    }

    private var bloom: Double {
        switch glow {
        case .lit: return 0.85
        case .ember: return 0.30
        case .dark: return 0
        }
    }

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)

            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [core, rim]),
                        center: UnitPoint(x: 0.42, y: 0.36),
                        startRadius: 0, endRadius: d * 0.62)
                )
                .overlay(
                    Circle()
                        .fill(Color.white.opacity(glow == .dark ? 0.18 : 0.45))
                        .frame(width: d * 0.22, height: d * 0.22)
                        .offset(x: -d * 0.14, y: -d * 0.16)
                )
                .overlay(Circle().stroke(Color.black.opacity(0.55), lineWidth: max(0.3, d * 0.09)))
                .shadow(color: core.opacity(bloom), radius: d * 0.30)
                .shadow(color: core.opacity(bloom * 0.45), radius: d * 0.85)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

// ── The DMG ──────────────────────────────────────────────────────────────────

// The ornament: everything printed or moulded on this case that no other
// case shares. It stays out of BodyLayout on purpose — that struct holds
// what every body has and what the screen placement needs, and a power
// switch groove is neither. Same millimetres as BodyLayout.dmg, same ruler.
private enum DMGTrim {
    static let width = 90.0
    static let height = 148.0

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x / width, y: y / height, width: w / width, height: h / height)
    }

    // Millimetres into points, at whatever size the window gave the body.
    static func pt(_ mm: Double, in size: CGSize) -> CGFloat {
        size.width * mm / width
    }

    static let powerGroove = rect(11, 4.6, 17, 2.8)
    static let powerNub = rect(11.6, 4.1, 6, 3.8)
    static let powerPrint = rect(29.5, 3.6, 14, 4)

    static let ledLabel = rect(5.5, 39.5, 12, 4)
    static let branding = rect(9, 76.3, 44, 8)

    // The shallow dish the cross rocks in, and the trough the face buttons
    // sit along — both are real depressions on the case, and both catch
    // enough light to be worth drawing.
    static let dpadWell = rect(8, 85, 30, 30)
    static let faceWell = rect(52.25, 91.25, 28, 14.5)
    static let faceWellTilt = -31.3

    static let labelA = rect(68, 102, 8, 5)
    static let labelB = rect(56.5, 109, 8, 5)
    static let pillTilt = -25.0
    static let selectLabel = rect(28.5, 126.2, 14, 3.6)
    static let startLabel = rect(42, 123.2, 14, 3.6)
}

// The DMG-01, drawn. Gray case, burgundy pair on the diagonal, the cross in
// its dish, two pills, the grill in the corner that the body's long radius
// sweeps around, and one red light that says whether any of it is running.
struct DMGBody: View {
    let engine: Engine
    let layout: BodyLayout
    @ObservedObject private var console = ConsoleState.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                shell(size)
                printing(size)
                glass(size)
                lamp(size)
                controls(size)
                speaker(size)
            }
        }
    }

    // ── The case ─────────────────────────────────────────────────────────────

    private func silhouette(_ size: CGSize) -> BodyShape {
        BodyShape(
            topLeft: layout.corner * size.width,
            topRight: layout.corner * size.width,
            bottomRight: layout.cornerBottomRight * size.width,
            bottomLeft: layout.corner * size.width)
    }

    private func shell(_ size: CGSize) -> some View {
        let outline = silhouette(size)
        return outline
            .fill(
                LinearGradient(
                    colors: [
                        Plastic.dmgShell.light, Plastic.dmgShell.base, Plastic.dmgShell.dark,
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                outline.stroke(Color.white.opacity(0.35), lineWidth: max(0.5, size.width * 0.003))
                    .blur(radius: size.width * 0.002)
            )
            .shadow(color: .black.opacity(0.55), radius: size.width * 0.05, x: 0, y: size.width * 0.02)
    }

    // Everything the case wears without being a control: the switch on the
    // top edge seen from the front — a groove, a nub in it, the two words
    // beside it — and the name under the bezel where the other one goes.
    private func printing(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Plastic.dmgShell.dark, Plastic.dmgShell.base],
                        startPoint: .top, endPoint: .bottom)
                )
                .place(DMGTrim.powerGroove, in: size)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Plastic.dmgShell.light, Plastic.dmgShell.base],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(Capsule().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
                .place(DMGTrim.powerNub, in: size)

            Text("OFF ◂ ▸ ON")
                .font(.system(size: DMGTrim.pt(1.8, in: size), weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.34))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .place(DMGTrim.powerPrint, in: size)

            // Where the real one says whose console it is. We ship no
            // trademarks, so it says ours.
            Text("ATOMBOY")
                .font(.system(size: DMGTrim.pt(7, in: size), weight: .black, design: .rounded))
                .italic()
                .foregroundStyle(Color(hex: 0x2D2D46))
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .place(DMGTrim.branding, in: size)
        }
    }

    // ── The screen, and the plate it is sunk into ────────────────────────────

    private func glass(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ScreenBezel(
                plastic: .dmgBezel,
                corner: layout.bezelCorner * size.width,
                stripes: true,
                script: "DOT MATRIX WITH STEREO SOUND"
            )
            .place(layout.bezel, in: size)

            // A hair of black around the cutout, so the picture's edge looks
            // seated rather than pasted on.
            Rectangle()
                .fill(Color(hex: 0x101012))
                .place(layout.screen.insetBy(dx: -0.010, dy: -0.007), in: size)

            Screen(engine: engine)
                .place(layout.screen, in: size)
        }
    }

    private func lamp(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Text("POWER")
                .font(.system(size: DMGTrim.pt(2.4, in: size), weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .place(DMGTrim.ledLabel, in: size)

            PowerLED(glow: console.glow)
                .place(layout.led, in: size)
        }
    }

    // ── The controls ─────────────────────────────────────────────────────────

    private func controls(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            well(Circle(), DMGTrim.dpadWell, size, tilt: 0)
            well(Capsule(), DMGTrim.faceWell, size, tilt: DMGTrim.faceWellTilt)

            DPad(
                plastic: .dmgCross,
                up: console.up, down: console.down,
                left: console.left, right: console.right
            )
            .place(layout.dpad, in: size)

            MoldedButton(plastic: .dmgFace, pressed: console.a)
                .place(layout.buttonA, in: size)
            MoldedButton(plastic: .dmgFace, pressed: console.b)
                .place(layout.buttonB, in: size)

            caption("A", DMGTrim.labelA, size)
            caption("B", DMGTrim.labelB, size)

            PillButton(
                plastic: .dmgPill, tilt: .degrees(DMGTrim.pillTilt), pressed: console.select
            )
            .place(layout.select, in: size)

            PillButton(
                plastic: .dmgPill, tilt: .degrees(DMGTrim.pillTilt), pressed: console.start
            )
            .place(layout.start, in: size)

            caption("SELECT", DMGTrim.selectLabel, size, tilt: DMGTrim.pillTilt)
            caption("START", DMGTrim.startLabel, size, tilt: DMGTrim.pillTilt)
        }
    }

    // A depression in the case: darker than the plastic around it, with the
    // light lip along its bottom edge that says the surface went in and not
    // out.
    private func well<S: Shape>(_ shape: S, _ rect: CGRect, _ size: CGSize, tilt: Double)
        -> some View
    {
        shape
            .fill(
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.16), Color.black.opacity(0.05),
                        Color.white.opacity(0.10),
                    ],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                shape.stroke(Color.white.opacity(0.22), lineWidth: max(0.4, size.width * 0.0018))
                    .offset(y: max(0.4, size.width * 0.0018))
                    .mask(shape.fill())
            )
            .rotationEffect(.degrees(tilt))
            .place(rect, in: size)
    }

    private func caption(_ text: String, _ rect: CGRect, _ size: CGSize, tilt: Double = 0)
        -> some View
    {
        Text(text)
            .font(.system(size: DMGTrim.pt(3.2, in: size), weight: .bold))
            .foregroundStyle(Color(hex: 0x5A2340).opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .rotationEffect(.degrees(tilt))
            .place(rect, in: size)
    }

    private func speaker(_ size: CGSize) -> some View {
        SpeakerGrill(plastic: .dmgGrill)
            .place(layout.speaker, in: size)
    }
}

extension View {
    // A fraction of the body turned into a frame. Inside a top-leading ZStack
    // this puts a view exactly where the layout says it lives — the drawing
    // and the screen cutout come from the same rects, so they cannot drift
    // apart.
    func place(_ rect: CGRect, in size: CGSize) -> some View {
        frame(width: rect.width * size.width, height: rect.height * size.height)
            .offset(x: rect.minX * size.width, y: rect.minY * size.height)
    }
}
