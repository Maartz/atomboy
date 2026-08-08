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
// What is here today is scaffolding on purpose: a flat gray slab with a
// recessed plate where the screen goes. The molded buttons, the D-pad, the
// speaker grill and the four real silhouettes come next — the frame arrives
// before the flesh.

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
    // and a length on a body is read across it).
    let corner: CGFloat
    let bezelCorner: CGFloat

    // The recessed plate the screen is sunk into, and the cutout itself.
    let bezel: CGRect
    let screen: CGRect

    // The controls. Nothing draws them yet; the numbers are measured off the
    // real object so the art has somewhere to land.
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
            bezelCorner: 4 / width,
            bezel: rect(7, 14, 76, 62),
            screen: rect((width - viewport) / 2, 27, viewport, viewport * 9 / 10),
            dpad: rect(11, 84, 24, 24),
            buttonA: rect(66.25, 85.25, 11.5, 11.5),
            buttonB: rect(54.75, 92.25, 11.5, 11.5),
            select: rect(34, 117.75, 12, 4.5),
            start: rect(47, 117.75, 12, 4.5),
            speaker: rect(60, 122, 26, 20),
            led: rect(8.5, 55, 4, 4))
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
            ConsoleView(engine: engine, layout: shell.layout)
        } else {
            Screen(engine: engine)
        }
    }
}

struct ConsoleView: View {
    let engine: Engine
    let layout: BodyLayout

    var body: some View {
        GeometryReader { geo in
            let size = layout.fit(in: geo.size)

            ConsoleBodyArt(engine: engine, layout: layout)
                .frame(width: size.width, height: size.height)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
    }
}

// The placeholder body: a flat slab with a recessed plate around the hole
// the game shows through. Deliberately crude — it exists to prove that the
// geometry, the window ratio and the Metal layer agree, before any art has
// an opinion about it.
struct ConsoleBodyArt: View {
    let engine: Engine
    let layout: BodyLayout

    var body: some View {
        GeometryReader { geo in
            let size = geo.size

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: layout.corner * size.width, style: .continuous)
                    .fill(Color(white: 0.74))

                RoundedRectangle(cornerRadius: layout.bezelCorner * size.width, style: .continuous)
                    .fill(Color(white: 0.26))
                    .place(layout.bezel, in: size)

                Screen(engine: engine)
                    .place(layout.screen, in: size)
            }
        }
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
