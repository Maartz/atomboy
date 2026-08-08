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

// A body's real millimetres, and the only arithmetic anyone does with them.
// Every table below — the layout and the ornament alike — is written as
// measurements off the actual object and divided by the case, so the numbers
// stay checkable against a ruler and the fractions come out for free.
struct Ruler {
    let width: Double
    let height: Double

    init(_ width: Double, _ height: Double) {
        self.width = width
        self.height = height
    }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: x / width, y: y / height, width: w / width, height: h / height)
    }

    // A length read across the body — a corner radius, a stroke.
    func across(_ mm: Double) -> CGFloat { CGFloat(mm / width) }

    // Millimetres into points, at whatever size the window gave the body.
    func pt(_ mm: Double, in size: CGSize) -> CGFloat { size.width * mm / width }

    var aspect: CGFloat { CGFloat(width / height) }
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

    // The DMG-01, measured: 90 × 148 mm of gray plastic.
    static let dmg: BodyLayout = {
        let mm = Ruler(90, 148)

        // The visible LCD is 47 mm across, and 10:9 like the 160 × 144 it
        // shows. Deriving the height from the width is what guarantees the
        // Metal layer gets its own ratio inside the body's.
        let viewport = 47.0

        return BodyLayout(
            aspect: mm.aspect,
            corner: mm.across(6),
            cornerBottomRight: mm.across(24),
            bezelCorner: mm.across(5),
            bezel: mm.rect(7, 14, 76, 62),
            screen: mm.rect((mm.width - viewport) / 2, 27, viewport, viewport * 9 / 10),
            dpad: mm.rect(11, 88, 24, 24),
            buttonA: mm.rect(66.25, 89.25, 11.5, 11.5),
            buttonB: mm.rect(54.75, 96.25, 11.5, 11.5),
            select: mm.rect(28, 119.7, 13, 4.6),
            start: mm.rect(41.5, 116.7, 13, 4.6),
            speaker: mm.rect(58, 118, 20, 20),
            led: mm.rect(9.4, 45.5, 4.2, 4.2))
    }()

    // The MGB-001, the Pocket: 77.6 × 127.6 mm. Two centimetres shorter than
    // its parent and a bigger picture on it — the whole point of the model.
    // Everything below the glass moved down and in: the cross and the pair
    // sit lower, the pills lie flat instead of on the diagonal, and the
    // corner grill traded slots for holes.
    static let pocket: BodyLayout = {
        let mm = Ruler(77.6, 127.6)
        let viewport = 48.0

        return BodyLayout(
            aspect: mm.aspect,
            corner: mm.across(7),
            // The Pocket is the even-tempered one: four corners within a
            // millimetre and a half of each other, where the DMG has a sweep.
            cornerBottomRight: mm.across(8.5),
            bezelCorner: mm.across(3),
            bezel: mm.rect(6.3, 10.5, 65, 58),
            screen: mm.rect((mm.width - viewport) / 2, 16.5, viewport, viewport * 9 / 10),
            dpad: mm.rect(9, 81, 22, 22),
            buttonA: mm.rect(57.5, 82.5, 10.5, 10.5),
            buttonB: mm.rect(45.5, 88.5, 10.5, 10.5),
            select: mm.rect(24.3, 109, 13, 4.4),
            start: mm.rect(40.3, 109, 13, 4.4),
            speaker: mm.rect(54, 102, 17, 17),
            // Above the bezel, not beside it: the Pocket's one light sits out
            // on the silver, under the switch and clear of it.
            led: mm.rect(7.2, 6.6, 3.2, 3.2))
    }()

    // The CGB-001: 75 × 133.5 mm, narrower than a Pocket and taller than
    // one, with the weight low. The flare below the waist is approximated
    // where a Path can afford it — two generous bottom radii against two
    // modest top ones read as the same swelling silhouette.
    static let cgb: BodyLayout = {
        let mm = Ruler(75, 133.5)
        let viewport = 44.0

        return BodyLayout(
            aspect: mm.aspect,
            corner: mm.across(7),
            cornerBottomRight: mm.across(19),
            bezelCorner: mm.across(3.5),
            // The asymmetry that dates the machine: four millimetres of black
            // above the picture and ten below it, because the name has to go
            // somewhere and the Color put it on the chin.
            bezel: mm.rect(8, 16.5, 59, 54),
            screen: mm.rect((mm.width - viewport) / 2, 21, viewport, viewport * 9 / 10),
            dpad: mm.rect(7, 83, 22, 22),
            buttonA: mm.rect(55.5, 82, 11, 11),
            buttonB: mm.rect(44, 91.5, 11, 11),
            select: mm.rect(21.5, 115, 12.5, 4.2),
            start: mm.rect(37, 115, 12.5, 4.2),
            speaker: mm.rect(52, 106, 17, 17),
            // Inside the black, in the margin left of the glass — the Color
            // keeps its light on the bezel rather than the plastic.
            led: mm.rect(10.5, 22, 3.2, 3.2))
    }()

    // The set in the corner of the living room: a twelve-inch portable from
    // around 1980, near enough 320 × 256 mm seen head-on. The one landscape
    // body — and the window turns with it, because the ratio has always come
    // from here rather than from the mode.
    //
    // The bounds are not all cabinet. The top 52 mm are the air the aerial
    // rises into: the ears are folded INSIDE the silhouette so everything
    // drawn still lives in the rectangle the window was told about, and
    // nothing waits outside the frame to be clipped.
    static let tv: BodyLayout = {
        let mm = Ruler(320, 256)

        // The picture stays the Game Boy's 10:9 — a television only changes
        // what is around the panel, never the panel. 168 mm across the tube
        // leaves a 16 mm surround on all four sides of the opening.
        let viewport = 168.0
        let picture = viewport * 9 / 10

        return BodyLayout(
            aspect: mm.aspect,
            corner: mm.across(12),
            cornerBottomRight: mm.across(12),
            bezelCorner: mm.across(16),
            bezel: mm.rect(24, 64, 200, 174),
            screen: mm.rect(40, 64 + (174 - picture) / 2, viewport, picture),
            // A television has no thumbs on it. These rects exist because
            // every body shares one struct; the TV simply never asks for
            // them, and no view reads a zero rect.
            dpad: .zero,
            buttonA: .zero,
            buttonB: .zero,
            select: .zero,
            start: .zero,
            // Not a corner grill this time: a column of flat slots in the
            // fascia, beside the tube where the sound came out.
            speaker: mm.rect(240, 88, 52, 62),
            // The pilot lamp under the channel dial — this body's whole
            // reactive surface, and the same LED contract as the handhelds.
            led: mm.rect(262, 220, 8, 8))
    }()

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

    // Whether the game window has taken the whole display. It matters to the
    // drawing: a console in a window floats on the desktop with nothing
    // behind it, while a console in fullscreen is staged on black.
    @Published private(set) var fullscreen = false {
        didSet { relockGameWindows() }
    }

    private var fullscreenWatch: [Any] = []

    private init() {
        let defaults = UserDefaults.standard
        // Absent means on: the console is what the app looks like out of the
        // box, and ⌘B is one keystroke away from today's plain window.
        enabled = defaults.object(forKey: Self.modeKey) as? Bool ?? true
        console = ConsoleBody.forPanel(defaults.object(forKey: Self.panelKey) as? Int ?? 0)
        watchFullScreen()
    }

    // Fullscreen arrives from macOS, never from us — a green button, a menu
    // item, a swipe — so the only way to hear about it is to listen. Only the
    // game windows count; a Settings window going fullscreen is not our
    // business.
    private func watchFullScreen() {
        let centre = NotificationCenter.default
        let transitions: [(Notification.Name, Bool)] = [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false),
        ]

        fullscreenWatch = transitions.map { name, entering in
            centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self,
                    let window = note.object as? NSWindow,
                    let content = window.contentView,
                    ScreenView.hosted(in: content)
                else { return }
                if self.fullscreen != entering { self.fullscreen = entering }
            }
        }
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
        dress(window)

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

    // What the window is made of. A rectangle of plastic is not a rectangle:
    // every corner the body rounds off, every millimetre of margin, and the
    // whole band of air the television's aerial rises through, are places
    // where the window has no console in it — and an opaque window paints
    // them black. So in shell mode the window stops being a surface and
    // becomes a frame around the drawing: the desktop shows through the
    // corners and the ears cross real air.
    //
    // Both other cases keep exactly the opaque window this app has always
    // had. Plain mode has a picture edge to edge and nothing to see through;
    // fullscreen deliberately stages the console on black, and a transparent
    // window there would only hand macOS a chance to show something else.
    //
    // The shadow goes with the opacity, and on purpose. A transparent window
    // has macOS derive its shadow from whatever the content leaves opaque —
    // which here already includes the soft drop shadow caseShell draws under
    // the body, so the system would blur a blur and then hold the result
    // stale until someone remembered to invalidate it after every resize. One
    // shadow, drawn by the thing casting it, is both truer and cheaper.
    private func dress(_ window: NSWindow) {
        let floating = enabled && !window.styleMask.contains(.fullScreen)

        window.isOpaque = !floating
        window.backgroundColor = floating ? .clear : .windowBackgroundColor
        window.hasShadow = !floating

        // Transparency is not a hole: AppKit still hit-tests the window's
        // whole rectangle, so the plastic — and the air beside it — stays
        // grabbable and the console drags as one object.
        window.isMovableByWindowBackground = true
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
            ConsoleView(
                engine: engine, console: shell.console, layout: shell.layout,
                letterboxed: shell.fullscreen)
        } else {
            Screen(engine: engine)
        }
    }
}

struct ConsoleView: View {
    let engine: Engine
    let console: ConsoleBody
    let layout: BodyLayout

    // Whether there is a stage under the console. In fullscreen the display
    // is ours and the console sits centred on black; in a window there is no
    // ground at all, and what the margins show is the desk.
    let letterboxed: Bool

    var body: some View {
        GeometryReader { geo in
            let size = layout.fit(in: geo.size)

            ConsoleBodyArt(engine: engine, console: console, layout: layout)
                .frame(width: size.width, height: size.height)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        // Color.clear is not "no view": it takes the same space and the same
        // clicks, which is what keeps the transparent air beside the body
        // draggable.
        .background(letterboxed ? Color.black : Color.clear)
    }
}

// Which case the panel preset put us in. Three handhelds and a television,
// and the television is the reason this switch cannot assume a portrait
// window.
struct ConsoleBodyArt: View {
    let engine: Engine
    let console: ConsoleBody
    let layout: BodyLayout

    var body: some View {
        switch console {
        case .dmg:
            DMGBody(engine: engine, layout: layout)
        case .pocket:
            PocketBody(engine: engine, layout: layout)
        case .cgb:
            CGBBody(engine: engine, layout: layout)
        case .tv:
            TVBody(engine: engine, layout: layout)
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

    // The Pocket's four: cold silver where the DMG was warm gray, and then
    // black for everything a thumb touches. One case colour, one button
    // colour — the model's whole idea.
    static let pocketShell = Plastic(0xE9EAEE, 0xC9CBD2, 0x94969E)
    static let pocketCross = Plastic(0x4A4A4F, 0x272729, 0x0E0E10)
    static let pocketFace = Plastic(0x55555C, 0x2C2C31, 0x111114)
    static let pocketPill = Plastic(0x4E4E55, 0x2A2A2F, 0x101013)
    static let pocketBezel = Plastic(0x35353A, 0x1F1F23, 0x0A0A0C)
    static let pocketGrill = Plastic(0xF2F3F6, 0x6E7076, 0x3E4045)

    // The Color, in the teal it is remembered in. The face buttons are cast
    // from the case here — the Color put its contrast in the cross and the
    // pills and left the pair to match the shell.
    static let cgbShell = Plastic(0x4FD9D1, 0x00B5AD, 0x00706A)
    static let cgbFace = Plastic(0x36C2BA, 0x009189, 0x00443F)
    static let cgbCross = Plastic(0x4B4B51, 0x252529, 0x0C0C0E)
    static let cgbPill = Plastic(0x55555C, 0x2E2E33, 0x121215)
    static let cgbBezel = Plastic(0x2C2C31, 0x141416, 0x050506)
    static let cgbGrill = Plastic(0x7DE6E0, 0x00837D, 0x004E4A)

    // The television, which is not plastic at all above the fascia: walnut
    // veneer, the warm ground the grain is drawn onto. Then the dark board
    // the controls are set into, the tube's surround, the knob, the collar
    // of the aerial, and the lip of the speaker slots on a dark panel.
    static let tvCabinet = Plastic(0x8A5A33, 0x6A4123, 0x3C2312)
    static let tvFascia = Plastic(0x3A2B22, 0x241A14, 0x120C09)
    static let tvBezel = Plastic(0x33302D, 0x1B1917, 0x090808)
    static let tvKnob = Plastic(0x6B6660, 0x3B3733, 0x161413)
    static let tvChrome = Plastic(0xE4E1D8, 0x9C9890, 0x3E3B36)
    static let tvGrill = Plastic(0x6B5340, 0x1E1611, 0x0B0806)
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

// Six bands on the diagonal, stacked along the corner they live in. The DMG
// leaves them as long slots; the Pocket and the Color drill the same bands
// into rows of round holes, which is the only difference between the three
// grills on the real cases. The television runs the same bands flat and
// wider — a grill is a grill, and this one only had to learn which way it
// lies. The pale capsule under each opening is the lip of the moulding
// catching the light — the cheapest possible inner shadow, and the only one
// that reads at this size.
struct SpeakerGrill: View {
    enum Style {
        case slots, holes
    }

    let plastic: Plastic
    var slots = 6
    var style: Style = .slots

    // Which way the bands run, and how far across their box they reach. The
    // handhelds keep the corner diagonal they were moulded with; the set in
    // the living room lays them flat and lets them nearly touch the sides.
    var angle: Angle = .degrees(-45)
    var span: CGFloat = 0.56

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let step = s * 0.115
            let thickness = s * 0.062
            // Bands stack along their own perpendicular, whatever angle they
            // were laid at — which at -45° is the corner drift they always had.
            let drift = CGSize(
                width: CGFloat(-sin(angle.radians)), height: CGFloat(cos(angle.radians)))

            ZStack {
                ForEach(0..<slots, id: \.self) { i in
                    let k = CGFloat(i) - CGFloat(slots - 1) / 2
                    band(length: s * (span - 0.04 * abs(k) / 2.5), thickness: thickness, step: step)
                        .position(
                            x: geo.size.width / 2 + k * step * drift.width,
                            y: geo.size.height / 2 + k * step * drift.height)
                }
            }
        }
    }

    @ViewBuilder private func band(length: CGFloat, thickness: CGFloat, step: CGFloat) -> some View {
        switch style {
        case .slots:
            opening(Capsule(), lip: thickness * 0.28)
                .frame(width: length, height: thickness)
                .rotationEffect(angle)
        case .holes:
            // The same band, perforated: as many holes as fit at the pitch
            // the bands themselves are stacked at, so the lattice comes out
            // square and lands on the diagonal like everything else here.
            let count = max(1, Int((length / step).rounded()))
            let d = thickness * 1.5
            HStack(spacing: step - d) {
                ForEach(0..<count, id: \.self) { _ in
                    opening(Circle(), lip: d * 0.16).frame(width: d, height: d)
                }
            }
            .rotationEffect(angle)
        }
    }

    private func opening<S: Shape>(_ shape: S, lip: CGFloat) -> some View {
        ZStack {
            shape.fill(plastic.light.opacity(0.75)).offset(y: lip)
            shape.fill(
                LinearGradient(
                    colors: [plastic.dark, plastic.base],
                    startPoint: .top, endPoint: .bottom))
        }
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

// The case itself: a moulded slab lit from above, a hairline of white where
// the light wraps around its edge, and its own shadow underneath so it sits
// on the black rather than in it. The silhouette is the only thing that
// changes between bodies, which is why it comes in as a shape.
func caseShell(_ outline: BodyShape, _ plastic: Plastic, in size: CGSize) -> some View {
    outline
        .fill(
            LinearGradient(
                colors: [plastic.light, plastic.base, plastic.dark],
                startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            outline.stroke(Color.white.opacity(0.35), lineWidth: max(0.5, size.width * 0.003))
                .blur(radius: size.width * 0.002)
        )
        .shadow(color: .black.opacity(0.55), radius: size.width * 0.05, x: 0, y: size.width * 0.02)
}

// The power switch on the top edge, seen head-on: a groove sunk into the
// case and the nub riding in it. All three handhelds wear one — only its
// size, and whether the case bothers to label it, changes.
func caseSwitch(_ groove: CGRect, _ nub: CGRect, _ plastic: Plastic, in size: CGSize)
    -> some View
{
    ZStack(alignment: .topLeading) {
        Capsule()
            .fill(
                LinearGradient(
                    colors: [plastic.dark, plastic.base],
                    startPoint: .top, endPoint: .bottom)
            )
            .place(groove, in: size)

        Capsule()
            .fill(
                LinearGradient(
                    colors: [plastic.light, plastic.base],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(Capsule().stroke(Color.black.opacity(0.2), lineWidth: 0.5))
            .place(nub, in: size)
    }
}

// A depression in the case: darker than the plastic around it, with the
// light lip along its bottom edge that says the surface went in and not out.
// Every body has these — the dish the cross rocks in, the trough the face
// buttons sit along — so they are drawn once and tilted to taste.
func caseWell<S: Shape>(_ shape: S, _ rect: CGRect, in size: CGSize, tilt: Double = 0)
    -> some View
{
    let hairline = max(0.4, size.width * 0.0018)
    return shape
        .fill(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.16), Color.black.opacity(0.05),
                    Color.white.opacity(0.10),
                ],
                startPoint: .top, endPoint: .bottom)
        )
        .overlay(
            shape.stroke(Color.white.opacity(0.22), lineWidth: hairline)
                .offset(y: hairline)
                .mask(shape.fill())
        )
        .rotationEffect(.degrees(tilt))
        .place(rect, in: size)
}

// A word printed on the case. Pad-printed lettering is never crisp and never
// black; every body passes its own ink and its own point size, measured off
// the same ruler as the rect it lands in.
func casePrint(
    _ text: String, _ rect: CGRect, in size: CGSize, pt: CGFloat, ink: Color,
    weight: Font.Weight = .bold, tilt: Double = 0
) -> some View {
    Text(text)
        .font(.system(size: pt, weight: weight))
        .foregroundStyle(ink)
        .lineLimit(1)
        .minimumScaleFactor(0.3)
        .rotationEffect(.degrees(tilt))
        .place(rect, in: size)
}

// ── The DMG ──────────────────────────────────────────────────────────────────

// The ornament: everything printed or moulded on this case that no other
// case shares. It stays out of BodyLayout on purpose — that struct holds
// what every body has and what the screen placement needs, and a power
// switch groove is neither. Same millimetres as BodyLayout.dmg, same ruler.
private enum DMGTrim {
    static let mm = Ruler(90, 148)

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        mm.rect(x, y, w, h)
    }

    static func pt(_ length: Double, in size: CGSize) -> CGFloat {
        mm.pt(length, in: size)
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
        caseShell(silhouette(size), .dmgShell, in: size)
    }

    // Everything the case wears without being a control: the switch on the
    // top edge seen from the front — a groove, a nub in it, the two words
    // beside it — and the name under the bezel where the other one goes.
    private func printing(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            caseSwitch(DMGTrim.powerGroove, DMGTrim.powerNub, .dmgShell, in: size)

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
            caseWell(Circle(), DMGTrim.dpadWell, in: size)
            caseWell(Capsule(), DMGTrim.faceWell, in: size, tilt: DMGTrim.faceWellTilt)

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

    // The DMG's ink for its own lettering: the burgundy of the face buttons,
    // thinned, which is what the real pad printing is.
    private func caption(_ text: String, _ rect: CGRect, _ size: CGSize, tilt: Double = 0)
        -> some View
    {
        casePrint(
            text, rect, in: size, pt: DMGTrim.pt(3.2, in: size),
            ink: Color(hex: 0x5A2340).opacity(0.85), tilt: tilt)
    }

    private func speaker(_ size: CGSize) -> some View {
        SpeakerGrill(plastic: .dmgGrill)
            .place(layout.speaker, in: size)
    }
}

// ── The Pocket ───────────────────────────────────────────────────────────────

// The Pocket's own ornament. There is markedly less of it than on the DMG:
// the model's whole argument was that the case should get out of the way,
// so the name moved onto the bezel and the silver was left blank.
private enum PocketTrim {
    static let mm = Ruler(77.6, 127.6)

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        mm.rect(x, y, w, h)
    }

    static func pt(_ length: Double, in size: CGSize) -> CGFloat {
        mm.pt(length, in: size)
    }

    // Pushed right of the light, which the Pocket keeps in the corner.
    static let powerGroove = rect(12, 3.4, 13, 2.2)
    static let powerNub = rect(12.5, 3, 4.6, 3)

    // The Pocket gives each face button its own round recess where the DMG
    // ran one trough under both — the pair sits shallower and further apart
    // on this case.
    static let dpadWell = rect(7, 79, 26, 26)
    static let wellA = rect(56, 81, 13.5, 13.5)
    static let wellB = rect(44, 87, 13.5, 13.5)

    static let labelA = rect(59.5, 94, 6, 3.4)
    static let labelB = rect(47.5, 100, 6, 3.4)
    static let selectLabel = rect(24.3, 114, 13, 3)
    static let startLabel = rect(40.3, 114, 13, 3)
}

// The MGB-001, drawn. Silver case, black everything else, the pills laid
// flat and centred, and a corner of round holes instead of the DMG's slots.
struct PocketBody: View {
    let engine: Engine
    let layout: BodyLayout
    @ObservedObject private var console = ConsoleState.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                shell(size)
                caseSwitch(PocketTrim.powerGroove, PocketTrim.powerNub, .pocketShell, in: size)
                glass(size)
                PowerLED(glow: console.glow).place(layout.led, in: size)
                controls(size)
                SpeakerGrill(plastic: .pocketGrill, slots: 5, style: .holes)
                    .place(layout.speaker, in: size)
            }
        }
    }

    private func shell(_ size: CGSize) -> some View {
        caseShell(
            BodyShape(
                topLeft: layout.corner * size.width,
                topRight: layout.corner * size.width,
                bottomRight: layout.cornerBottomRight * size.width,
                bottomLeft: layout.cornerBottomRight * size.width),
            .pocketShell, in: size)
    }

    private func glass(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // No stripes: the Pocket dropped the red and blue hairlines and
            // put its own name under the glass instead.
            ScreenBezel(
                plastic: .pocketBezel,
                corner: layout.bezelCorner * size.width,
                script: "ATOMBOY pocket"
            )
            .place(layout.bezel, in: size)

            Rectangle()
                .fill(Color(hex: 0x0B0B0D))
                .place(layout.screen.insetBy(dx: -0.010, dy: -0.007), in: size)

            Screen(engine: engine)
                .place(layout.screen, in: size)
        }
    }

    private func controls(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            caseWell(Circle(), PocketTrim.dpadWell, in: size)
            caseWell(Circle(), PocketTrim.wellA, in: size)
            caseWell(Circle(), PocketTrim.wellB, in: size)

            DPad(
                plastic: .pocketCross,
                up: console.up, down: console.down,
                left: console.left, right: console.right
            )
            .place(layout.dpad, in: size)

            MoldedButton(plastic: .pocketFace, pressed: console.a)
                .place(layout.buttonA, in: size)
            MoldedButton(plastic: .pocketFace, pressed: console.b)
                .place(layout.buttonB, in: size)

            caption("A", PocketTrim.labelA, size)
            caption("B", PocketTrim.labelB, size)

            // Flat, side by side, straddling the centre line: the Pocket
            // gave up the DMG's diagonal along with its logo.
            PillButton(plastic: .pocketPill, pressed: console.select)
                .place(layout.select, in: size)
            PillButton(plastic: .pocketPill, pressed: console.start)
                .place(layout.start, in: size)

            caption("SELECT", PocketTrim.selectLabel, size)
            caption("START", PocketTrim.startLabel, size)
        }
    }

    // Dark gray on silver, the way the Pocket prints.
    private func caption(_ text: String, _ rect: CGRect, _ size: CGSize) -> some View {
        casePrint(
            text, rect, in: size, pt: PocketTrim.pt(2.8, in: size),
            ink: Color(hex: 0x3A3A40).opacity(0.85), weight: .semibold)
    }
}

// ── The Color ────────────────────────────────────────────────────────────────

private enum CGBTrim {
    static let mm = Ruler(75, 133.5)

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        mm.rect(x, y, w, h)
    }

    static func pt(_ length: Double, in size: CGSize) -> CGFloat {
        mm.pt(length, in: size)
    }

    static let powerGroove = rect(8.5, 3.6, 12, 2.2)
    static let powerNub = rect(9, 3.2, 4.4, 3)

    // The infrared window in the top edge: the one thing on this case that
    // looks at another console. Dark red glass, nearly black until the light
    // catches it.
    static let infrared = rect(30, 3.4, 15, 2.8)

    static let dpadWell = rect(5, 81, 26, 26)
    // The pair is steeper here than on the DMG — very nearly forty degrees,
    // and the trough under it follows.
    static let faceWell = rect(40.75, 85.25, 29, 14)
    static let faceWellTilt = -39.6

    static let labelA = rect(58, 94.5, 6, 3.4)
    static let labelB = rect(46.5, 104, 6, 3.4)
    static let selectLabel = rect(21.5, 120, 12.5, 3)
    static let startLabel = rect(37, 120, 12.5, 3)
}

// The CGB-001, drawn. Teal case, teal pair, a black cross, and a bezel with
// its weight in the chin where the name is printed.
struct CGBBody: View {
    let engine: Engine
    let layout: BodyLayout
    @ObservedObject private var console = ConsoleState.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                shell(size)
                caseSwitch(CGBTrim.powerGroove, CGBTrim.powerNub, .cgbShell, in: size)
                infrared(size)
                glass(size)
                PowerLED(glow: console.glow).place(layout.led, in: size)
                controls(size)
                SpeakerGrill(plastic: .cgbGrill, slots: 5, style: .holes)
                    .place(layout.speaker, in: size)
            }
        }
    }

    // Two modest radii at the top and two generous ones at the bottom: as
    // close as four corners get to the Color's low, swollen waist.
    private func shell(_ size: CGSize) -> some View {
        caseShell(
            BodyShape(
                topLeft: layout.corner * size.width,
                topRight: layout.corner * size.width,
                bottomRight: layout.cornerBottomRight * size.width,
                bottomLeft: layout.cornerBottomRight * size.width),
            .cgbShell, in: size)
    }

    private func infrared(_ size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: CGBTrim.pt(1.2, in: size), style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(hex: 0x120504), Color(hex: 0x2A0908)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: CGBTrim.pt(1.2, in: size), style: .continuous)
                    .stroke(Color.black.opacity(0.45), lineWidth: max(0.4, size.width * 0.002))
            )
            .place(CGBTrim.infrared, in: size)
    }

    private func glass(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            ScreenBezel(
                plastic: .cgbBezel,
                corner: layout.bezelCorner * size.width,
                script: "ATOMBOY COLOR"
            )
            .place(layout.bezel, in: size)

            Rectangle()
                .fill(Color(hex: 0x08080A))
                .place(layout.screen.insetBy(dx: -0.010, dy: -0.007), in: size)

            Screen(engine: engine)
                .place(layout.screen, in: size)
        }
    }

    private func controls(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            caseWell(Circle(), CGBTrim.dpadWell, in: size)
            caseWell(Capsule(), CGBTrim.faceWell, in: size, tilt: CGBTrim.faceWellTilt)

            DPad(
                plastic: .cgbCross,
                up: console.up, down: console.down,
                left: console.left, right: console.right
            )
            .place(layout.dpad, in: size)

            MoldedButton(plastic: .cgbFace, pressed: console.a)
                .place(layout.buttonA, in: size)
            MoldedButton(plastic: .cgbFace, pressed: console.b)
                .place(layout.buttonB, in: size)

            caption("A", CGBTrim.labelA, size)
            caption("B", CGBTrim.labelB, size)

            PillButton(plastic: .cgbPill, pressed: console.select)
                .place(layout.select, in: size)
            PillButton(plastic: .cgbPill, pressed: console.start)
                .place(layout.start, in: size)

            caption("SELECT", CGBTrim.selectLabel, size)
            caption("START", CGBTrim.startLabel, size)
        }
    }

    // Ink on teal is the case's own colour taken down to nearly black —
    // printing on a coloured shell never reads as a separate hue.
    private func caption(_ text: String, _ rect: CGRect, _ size: CGSize) -> some View {
        casePrint(
            text, rect, in: size, pt: CGBTrim.pt(2.8, in: size),
            ink: Color(hex: 0x0B3B38).opacity(0.85), weight: .semibold)
    }
}

// ── The living room ──────────────────────────────────────────────────────────

// The set's ornament, in the same millimetres as BodyLayout.tv. There is no
// D-pad table here and no button trough: what a television wears instead is
// a cabinet that does not fill its own bounds, an aerial standing in the
// space left over, and one dark column of controls beside the tube.
private enum TVTrim {
    static let mm = Ruler(320, 256)

    static func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        mm.rect(x, y, w, h)
    }

    static func pt(_ length: Double, in size: CGSize) -> CGFloat {
        mm.pt(length, in: size)
    }

    // A millimetre coordinate as a point in the drawn body. The aerial is
    // strokes and fills rather than placed frames, and paths want points.
    static func point(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * p.x / mm.width, y: size.height * p.y / mm.height)
    }

    // The cabinet, sitting on the floor of the bounds with the top 52 mm
    // left as air. Twelve millimetres of walnut all the way round the tube.
    static let cabinet = rect(12, 52, 296, 198)

    // The fascia: the dark board right of the picture where a set of this
    // age kept the badge, the sound, the dial and the lamp, in that order
    // down the column.
    static let fascia = rect(236, 64, 60, 174)
    static let wordmark = rect(238, 69, 56, 12)
    static let speakerWell = rect(238, 84, 56, 70)
    static let dialWell = rect(239, 158, 54, 54)
    static let dialKnob = rect(248, 167, 36, 36)
    static let ledRing = rect(259, 217, 14, 14)

    // Which channel the dial was left on: the eighth mark of twelve across
    // the ring's 270°, which puts the pointer up and to the right.
    static let dialChannels = 12
    static let dialPointer = -135.0 + 270.0 * 7 / 11

    // The aerial, in raw millimetres because it is drawn as geometry: one
    // pod straddling the cabinet's top edge and two rods off it. The tips
    // stop 5 mm inside the bounds — that clearance is what keeps the ears
    // out of the letterbox.
    static let pod = CGRect(x: 147, y: 40, width: 26, height: 14)
    static let rodBase = CGPoint(x: 160, y: 43)
    static let rodTips = [CGPoint(x: 74, y: 5), CGPoint(x: 246, y: 5)]
    static let rodHalfAtBase = 1.3
    static let rodHalfAtTip = 0.55
    static let rodTipBall = 1.7
}

// A repeatable dice for the wood. The same seed draws the same grain on
// every redraw, because a cabinet that reshuffles itself when the window
// resizes is not a cabinet.
private struct GrainDice {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 33) & 0xFF_FFFF) / Double(0xFF_FFFF)
    }
}

// The ring of channel marks around the dial, and the knurl on the knob's
// own rim — the same shape twice, at two radii. The travel stops short of
// the bottom, which is where a dial's dead zone always is.
private struct DialTicks: Shape {
    var count = 12
    var inner: CGFloat = 0.84
    var outer: CGFloat = 0.99
    var sweep: Double = 270

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()

        for i in 0..<count {
            let t = count > 1 ? Double(i) / Double(count - 1) : 0.5
            let angle = (-sweep / 2 + sweep * t) * .pi / 180
            let direction = CGPoint(x: CGFloat(sin(angle)), y: CGFloat(-cos(angle)))
            path.move(
                to: CGPoint(
                    x: centre.x + direction.x * radius * inner,
                    y: centre.y + direction.y * radius * inner))
            path.addLine(
                to: CGPoint(
                    x: centre.x + direction.x * radius * outer,
                    y: centre.y + direction.y * radius * outer))
        }
        return path
    }
}

// The front of the tube: one plate with a hole in it, filled even-odd, so
// the glass's rounded corners are cut out of the surround and laid over the
// picture rather than clipped out of it. The Metal layer keeps its honest
// rectangle underneath and never learns that its corners are covered.
private struct TubeFace: Shape {
    let plate: CGRect
    let hole: CGRect
    let plateCorner: CGFloat
    let holeCorner: CGFloat
    var plateOnly = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if !plateOnly {
            path.addRoundedRect(
                in: plate.scaled(in: rect.size),
                cornerSize: CGSize(
                    width: plateCorner * rect.width, height: plateCorner * rect.width),
                style: .continuous)
        }
        path.addRoundedRect(
            in: hole.scaled(in: rect.size),
            cornerSize: CGSize(width: holeCorner * rect.width, height: holeCorner * rect.width),
            style: .continuous)
        return path
    }
}

// The portable television, drawn. A walnut box on the floor of its own
// bounds, two ears in the air above it, the tube's dark surround with the
// picture's corners eaten by the glass, and a column of controls that do
// nothing — except the lamp, which is the only thing on this body with a
// pulse.
struct TVBody: View {
    let engine: Engine
    let layout: BodyLayout
    @ObservedObject private var console = ConsoleState.shared

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                cabinet(size)
                aerial(size)
                tube(size)
                fascia(size)
            }
        }
    }

    // ── The cabinet ──────────────────────────────────────────────────────────

    private func silhouette(_ size: CGSize) -> BodyShape {
        let radius = layout.corner * size.width
        return BodyShape(
            topLeft: radius, topRight: radius,
            bottomRight: layout.cornerBottomRight * size.width, bottomLeft: radius)
    }

    private func cabinet(_ size: CGSize) -> some View {
        ZStack {
            caseShell(silhouette(size), .tvCabinet, in: size)
            grain(size).clipShape(silhouette(size))

            // The room's light lands on the top of the box and the floor
            // takes the rest: a veneer is flat, and only the lighting says
            // which way up the thing stands.
            silhouette(size)
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.10), .clear, .clear, .black.opacity(0.26),
                        ],
                        startPoint: .top, endPoint: .bottom))
        }
        .place(TVTrim.cabinet, in: size)
    }

    // Walnut, drawn rather than photographed: a hundred-odd streaks running
    // the height of the cabinet, some darker than the ground and some
    // lighter, each with a little sway in it. Blurred by a hair at the end,
    // because sharp grain looks like pinstripes.
    private func grain(_ size: CGSize) -> some View {
        Canvas { context, area in
            var dice = GrainDice(seed: 0x5EED_1978)
            let streaks = max(24, Int(area.width / 3))

            for _ in 0..<streaks {
                let x = dice.next() * area.width
                let width = area.width * (0.0010 + dice.next() * 0.0070)
                let dark = dice.next() < 0.66
                let alpha = (dark ? 0.14 : 0.075) * (0.25 + dice.next() * 0.75)
                let sway = area.width * 0.005 * (dice.next() - 0.5)

                var streak = Path()
                streak.move(to: CGPoint(x: x, y: 0))
                streak.addQuadCurve(
                    to: CGPoint(x: x + sway, y: area.height),
                    control: CGPoint(x: x - sway * 2, y: area.height * 0.5))

                context.stroke(
                    streak,
                    with: .color(
                        dark
                            ? Color(hex: 0x21130A).opacity(alpha)
                            : Color(hex: 0xCFA168).opacity(alpha)),
                    lineWidth: width)
            }
        }
        .blur(radius: max(0.25, size.width * 0.0008))
    }

    // ── The aerial ───────────────────────────────────────────────────────────

    // Two rods off one pod, tapering to a ball, drawn straight onto the body
    // in its own millimetres. They rise into the 52 mm the cabinet gave up
    // for them and stop short of the top edge — which is why the ears never
    // meet the letterbox: there is nothing outside the silhouette to clip.
    private func aerial(_ size: CGSize) -> some View {
        Canvas { context, area in
            let chrome = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [
                    Color(hex: 0xE8E5DD), Color(hex: 0x9A958C), Color(hex: 0x4A4640),
                ]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: area.height))

            let base = TVTrim.point(TVTrim.rodBase, in: area)

            for tip in TVTrim.rodTips {
                let end = TVTrim.point(tip, in: area)
                let along = CGPoint(x: end.x - base.x, y: end.y - base.y)
                let length = max(1, sqrt(along.x * along.x + along.y * along.y))
                // The rod's own perpendicular, so it keeps its thickness
                // whichever way it leans.
                let normal = CGPoint(x: -along.y / length, y: along.x / length)
                let atBase = TVTrim.pt(TVTrim.rodHalfAtBase, in: area)
                let atTip = TVTrim.pt(TVTrim.rodHalfAtTip, in: area)

                var rod = Path()
                rod.move(to: CGPoint(x: base.x + normal.x * atBase, y: base.y + normal.y * atBase))
                rod.addLine(to: CGPoint(x: end.x + normal.x * atTip, y: end.y + normal.y * atTip))
                rod.addLine(to: CGPoint(x: end.x - normal.x * atTip, y: end.y - normal.y * atTip))
                rod.addLine(to: CGPoint(x: base.x - normal.x * atBase, y: base.y - normal.y * atBase))
                rod.closeSubpath()
                context.fill(rod, with: chrome)

                let ball = TVTrim.pt(TVTrim.rodTipBall, in: area)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: end.x - ball, y: end.y - ball, width: ball * 2, height: ball * 2)),
                    with: chrome)
            }

            // The pod the rods swivel in, straddling the cabinet's top edge
            // so the aerial looks bolted to the set rather than balanced on it.
            let pod = CGRect(
                origin: TVTrim.point(
                    CGPoint(x: TVTrim.pod.minX, y: TVTrim.pod.minY), in: area),
                size: CGSize(
                    width: TVTrim.pt(TVTrim.pod.width, in: area),
                    height: TVTrim.pt(TVTrim.pod.height, in: area)))
            let shell = Path(roundedRect: pod, cornerRadius: pod.height * 0.42)

            context.fill(
                shell,
                with: .linearGradient(
                    Gradient(colors: [
                        Color(hex: 0x4C4640), Color(hex: 0x241F1B), Color(hex: 0x100D0B),
                    ]),
                    startPoint: CGPoint(x: pod.minX, y: pod.minY),
                    endPoint: CGPoint(x: pod.minX, y: pod.maxY)))
            context.stroke(shell, with: .color(.black.opacity(0.5)), lineWidth: max(0.4, atHair(area)))
        }
    }

    private func atHair(_ size: CGSize) -> CGFloat { size.width * 0.0015 }

    // ── The tube ─────────────────────────────────────────────────────────────

    private func tube(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // Black behind the picture, a hair wider than it, so no seam of
            // wood shows through where the plate meets the glass.
            Rectangle()
                .fill(Color(hex: 0x07070A))
                .place(layout.screen.insetBy(dx: -0.006, dy: -0.0075), in: size)

            Screen(engine: engine)
                .place(layout.screen, in: size)

            surround(size)
        }
    }

    // The surround, laid over the picture instead of around it: a dark plate
    // with a generously rounded hole, the tube's own falloff darkening the
    // edge of the image, a corner vignette and one diagonal sheen. Nothing
    // here is the handhelds' ScreenBezel — a television has no script under
    // the glass and no stripe over it, and the shape of its opening is the
    // whole point.
    private func surround(_ size: CGSize) -> some View {
        let plateCorner = layout.bezelCorner
        let holeCorner = layout.screen.width * 0.11

        return ZStack(alignment: .topLeading) {
            TubeFace(
                plate: layout.bezel, hole: layout.screen,
                plateCorner: plateCorner, holeCorner: holeCorner
            )
            .fill(
                // Dark at the top and lighter at the chin: the plate is sunk
                // into the wood, and the lip above it is what shades it.
                LinearGradient(
                    colors: [
                        Plastic.tvBezel.dark, Plastic.tvBezel.base, Plastic.tvBezel.base,
                        Plastic.tvBezel.light,
                    ],
                    startPoint: .top, endPoint: .bottom),
                style: FillStyle(eoFill: true))
            .shadow(
                color: .black.opacity(0.45), radius: TVTrim.pt(2.4, in: size), x: 0,
                y: TVTrim.pt(1, in: size))

            // The glass sits proud of the plate: dark where the tube curves
            // away at the opening, and one bright lip along the top where
            // the room is reflected in the last millimetre of it.
            TubeFace(
                plate: .zero, hole: layout.screen,
                plateCorner: 0, holeCorner: holeCorner, plateOnly: true
            )
            .stroke(Color.black.opacity(0.42), lineWidth: TVTrim.pt(2.6, in: size))
            .blur(radius: TVTrim.pt(2.0, in: size))

            TubeFace(
                plate: .zero, hole: layout.screen,
                plateCorner: 0, holeCorner: holeCorner, plateOnly: true
            )
            .stroke(Color.white.opacity(0.14), lineWidth: max(0.4, TVTrim.pt(0.7, in: size)))
            .offset(y: -TVTrim.pt(0.5, in: size))

            // The corners of a tube are always further from the gun than the
            // middle, and always darker for it.
            RadialGradient(
                colors: [.clear, .clear, .black.opacity(0.20)],
                center: .center, startRadius: 0,
                endRadius: layout.screen.width * size.width * 0.68
            )
            .place(layout.screen, in: size)

            // The one thing a curved front does that a flat one cannot: it
            // catches the window behind you across its top-left quarter.
            Ellipse()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .white.opacity(0.01)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .rotationEffect(.degrees(-24))
                .blur(radius: TVTrim.pt(4, in: size))
                .frame(
                    width: layout.screen.width * size.width * 0.78,
                    height: layout.screen.height * size.height * 0.34)
                .place(layout.screen, in: size)
                .offset(
                    x: -layout.screen.width * size.width * 0.10,
                    y: -layout.screen.height * size.height * 0.22)
        }
    }

    // ── The fascia ───────────────────────────────────────────────────────────

    private func fascia(_ size: CGSize) -> some View {
        let board = RoundedRectangle(cornerRadius: TVTrim.pt(5, in: size), style: .continuous)

        return ZStack(alignment: .topLeading) {
            board
                .fill(
                    LinearGradient(
                        colors: [
                            Plastic.tvFascia.light, Plastic.tvFascia.base, Plastic.tvFascia.dark,
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(
                    // Set into the wood: the cabinet's shadow falls across
                    // its top edge, and its bottom lip catches the light.
                    board.stroke(Color.black.opacity(0.65), lineWidth: TVTrim.pt(2.4, in: size))
                        .blur(radius: TVTrim.pt(1.2, in: size))
                        .mask(board.fill())
                )
                .overlay(
                    board.stroke(Color.white.opacity(0.10), lineWidth: max(0.4, atHair(size)))
                        .offset(y: max(0.4, atHair(size)))
                        .mask(board.fill())
                )
                .place(TVTrim.fascia, in: size)

            wordmark(size)

            caseWell(
                RoundedRectangle(cornerRadius: TVTrim.pt(3, in: size), style: .continuous),
                TVTrim.speakerWell, in: size)

            // The handhelds' grill, laid flat and stretched: nine slots
            // across the board instead of six on a corner's diagonal.
            SpeakerGrill(plastic: .tvGrill, slots: 9, angle: .zero, span: 0.95)
                .place(layout.speaker, in: size)

            dial(size)
            pilot(size)
        }
    }

    // The badge. Chrome on a dark board, spaced out the way a nameplate is,
    // with a black shadow under it so it stands off the fascia.
    private func wordmark(_ size: CGSize) -> some View {
        Text("ATOMBOY")
            .font(.system(size: TVTrim.pt(7, in: size), weight: .semibold))
            .tracking(TVTrim.pt(1.6, in: size))
            .foregroundStyle(
                LinearGradient(
                    colors: [Plastic.tvChrome.light, Plastic.tvChrome.base, Plastic.tvChrome.dark],
                    startPoint: .top, endPoint: .bottom)
            )
            .shadow(color: .black.opacity(0.75), radius: 0, x: 0, y: max(0.4, atHair(size)))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .place(TVTrim.wordmark, in: size)
    }

    // The channel dial: a ring of marks printed on the board, a knurled knob
    // sunk in the middle of them, and a pointer left on the eighth channel.
    // It is the one control on this body, and like every drawn control in
    // this file it does not move — nobody has turned it since 1983.
    private func dial(_ size: CGSize) -> some View {
        let knob = CGSize(
            width: TVTrim.dialKnob.width * size.width,
            height: TVTrim.dialKnob.height * size.height)

        return ZStack(alignment: .topLeading) {
            caseWell(Circle(), TVTrim.dialWell, in: size)

            DialTicks(count: TVTrim.dialChannels)
                .stroke(
                    Color(hex: 0xE8DAB8).opacity(0.45),
                    lineWidth: max(0.4, TVTrim.pt(0.6, in: size))
                )
                .place(TVTrim.dialWell, in: size)

            MoldedButton(plastic: .tvKnob)
                .place(TVTrim.dialKnob, in: size)

            // The knurl: the same marks again, finer and tighter, right on
            // the knob's rim where a thumb would find them.
            DialTicks(count: 28, inner: 0.80, outer: 0.98, sweep: 348)
                .stroke(Color.black.opacity(0.32), lineWidth: max(0.3, TVTrim.pt(0.4, in: size)))
                .place(TVTrim.dialKnob, in: size)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [Plastic.tvChrome.light, Plastic.tvChrome.base],
                        startPoint: .top, endPoint: .bottom)
                )
                .frame(width: TVTrim.pt(1.8, in: size), height: knob.height * 0.36)
                .offset(y: -knob.height * 0.19)
                .rotationEffect(.degrees(TVTrim.dialPointer))
                .place(TVTrim.dialKnob, in: size)
        }
    }

    // The pilot lamp in its chrome collar, under the dial. Lit while the
    // engine runs, an ember while it is paused, a dead lens once it has
    // gone — the same three states the handhelds' light has, because it is
    // the same light.
    private func pilot(_ size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(hex: 0x2A2622), Color(hex: 0x0C0A09)],
                        center: .center, startRadius: 0,
                        endRadius: TVTrim.ledRing.width * size.width * 0.6)
                )
                .overlay(
                    Circle().stroke(
                        LinearGradient(
                            colors: [Plastic.tvChrome.base, Plastic.tvChrome.dark],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: max(0.5, TVTrim.pt(0.9, in: size)))
                )
                .place(TVTrim.ledRing, in: size)

            PowerLED(glow: console.glow)
                .place(layout.led, in: size)
        }
    }
}

extension CGRect {
    // The same fractions `place` uses, as a rect in points — for the paths
    // that are drawn across the whole body instead of into a placed frame.
    fileprivate func scaled(in size: CGSize) -> CGRect {
        CGRect(
            x: minX * size.width, y: minY * size.height,
            width: width * size.width, height: height * size.height)
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
