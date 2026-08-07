// atomboy's macOS shell: SwiftUI up front, the BEAM behind.
//
// The engine is the Burrito binary embedded in the bundle, launched with
// `--serveur`: it pushes RGB24 frames (<<'F', 69120 bytes>>), stereo
// s16le PCM at 32,768 Hz (<<'A', 2-byte length, data>>) and the panel
// preset (<<'P', index>>) on stdout; the shell writes keys back as
// two-byte records (op '+'/'-', key) on stdin. All of the emulation —
// menu, save states, mixer, link cable — lives on the BEAM side.
//
// Here we draw, and drawing has two floors. The engine's frames arrive
// with the panel's *colours* already applied but nothing else: the
// temporal and spatial life of the screen belongs to this side, because
// only the display knows its own resolution and its own clock. A Metal
// layer runs two passes per frame — the response curve (each RGB channel
// slides towards its target, fast when darkening, slow when brightening:
// the ghosting of a real panel, per channel, so colour games get it too),
// then the dot structure (integer-scaled pixels with the reflector
// showing through the gaps, each dot shadowing its gap, paper grain, a
// breath of vignette). The 'P' message picks the parameters; preset 0
// (raw) degenerates to a plain nearest-neighbour blit through the same
// pipeline. If Metal fails to wake, the old CALayer path still draws —
// sharp, ghost-free, but alive.
//
// Sound is AVAudioEngine (no more ffplay); the keyboard is relayed.
//
// Compiled by swiftc directly (see bin/build --app): no Xcode project,
// a single file.

import SwiftUI
import AVFoundation
import GameController
import Metal
import QuartzCore

let WIDTH = 160
let HEIGHT = 144
let FRAME_BYTES = WIDTH * HEIGHT * 3

// ── The panel on the GPU ─────────────────────────────────────────────────────

// The uniforms as four float4s: a layout Swift and MSL can agree on
// without a shared header.
//   a = (alphaFall, alphaRise, seed, gapFraction)
//   b = (shadow, grain, vignette, crt flag)
//   reflector = the colour in the gaps, rgb + unused
//   geometry = (offset.x, offset.y, drawable width, drawable height)
//              — scale rides in a separate slot computed per frame
struct PanelUniforms {
    var a: SIMD4<Float>
    var b: SIMD4<Float>
    var c: SIMD4<Float>  // stn, crosstalk, subpixel, age
    var reflector: SIMD4<Float>
    var geometry: SIMD4<Float>
    var scale: SIMD4<Float>
}

// One preset per '?P' index — the mirror of Atomboy.LCD's profiles. The
// alphas are 1 - e^(-16.742/τ) for the same τs as the Elixir side; raw is
// the absence of a panel: instant response, no grid, no grain.
struct PanelPreset {
    let alphaFall: Float
    let alphaRise: Float
    let gap: Float
    let shadow: Float
    let grain: Float
    let vignette: Float
    let reflector: SIMD4<Float>
    var crt: Bool = false
    var stn: Float = 0
    var crosstalk: Float = 0
    var subpixel: Float = 0

    static let all: [PanelPreset] = [
        // 0 raw
        PanelPreset(alphaFall: 1.0, alphaRise: 1.0, gap: 0, shadow: 0, grain: 0,
                    vignette: 0, reflector: SIMD4(0, 0, 0, 0)),
        // 1 dmg — τ 21/61 ms, the STN smear; the crosstalk of a passive matrix
        PanelPreset(alphaFall: 0.549, alphaRise: 0.240, gap: 0.14, shadow: 0.25, grain: 0.03,
                    vignette: 0.06, reflector: SIMD4(0xD2 / 255.0, 0xDC / 255.0, 0xB0 / 255.0, 0),
                    stn: 0.12, crosstalk: 0.07),
        // 2 pocket — τ 16/44 ms, FSTN answers faster and bleeds less
        PanelPreset(alphaFall: 0.649, alphaRise: 0.317, gap: 0.12, shadow: 0.20, grain: 0.025,
                    vignette: 0.05, reflector: SIMD4(0xED / 255.0, 0xE9 / 255.0, 0xDC / 255.0, 0),
                    stn: 0.08, crosstalk: 0.05),
        // 3 cgb — τ 13/31 ms; the one panel whose dots split into strips
        PanelPreset(alphaFall: 0.724, alphaRise: 0.417, gap: 0.12, shadow: 0.15, grain: 0.02,
                    vignette: 0.05, reflector: SIMD4(0xF4 / 255.0, 0xF4 / 255.0, 0xEC / 255.0, 0),
                    stn: 0.06, crosstalk: 0.04, subpixel: 0.30),
        // 4 crt — the Super Game Boy's television: phosphor answers in
        // ~2 ms, so the response pass is effectively instant; the look is
        // all scanlines, grille and vignette.
        PanelPreset(alphaFall: 1.0, alphaRise: 1.0, gap: 0, shadow: 0, grain: 0.015,
                    vignette: 0.14, reflector: SIMD4(0, 0, 0, 0), crt: true),
    ]
}

// The whole shader, compiled at launch: with no Xcode project there is no
// .metallib, and a source string keeps the single-file build.
let PANEL_SHADER = """
#include <metal_stdlib>
using namespace metal;

struct Params {
    float4 a;          // alphaFall, alphaRise, seed, gapFraction
    float4 b;          // shadow, grain, vignette, crt flag
    float4 c;          // stn, crosstalk, subpixel, age
    float4 reflector;
    float4 geometry;   // offset.x, offset.y, drawable w, drawable h
    float4 scale;      // integer scale in x
};

struct VOut { float4 pos [[position]]; float2 uv; };

// One triangle over the whole target — three vertices, no buffer.
vertex VOut fullscreen(uint id [[vertex_id]]) {
    float2 v = float2((id << 1) & 2, id & 2);
    VOut out;
    out.pos = float4(v * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(v.x, 1.0 - v.y);
    return out;
}

constexpr sampler nn(coord::normalized, filter::nearest);

// Pass 1, at 160×144: every channel slides towards its target. Darkening
// — the value falling — is the driven, fast direction; brightening only
// relaxes. seed > 0.5 snaps to the target: the first frame of a game (or
// of a new panel) arrives ghost-free.
fragment float4 respond(VOut in [[stage_in]],
                        texture2d<float> frame [[texture(0)]],
                        texture2d<float> state [[texture(1)]],
                        constant Params& p [[buffer(0)]]) {
    float3 t = frame.sample(nn, in.uv).rgb;
    float3 s = state.sample(nn, in.uv).rgb;
    float3 a = float3(t.r < s.r ? p.a.x : p.a.y,
                      t.g < s.g ? p.a.x : p.a.y,
                      t.b < s.b ? p.a.x : p.a.y);
    float3 next = mix(s, t, a);
    return float4(p.a.z > 0.5 ? t : next, 1.0);
}

// The column pass, at 160×1: each fragment averages its column of the
// response state — the aggregate the crosstalk needs, 144 samples of
// work the GPU does not feel.
fragment float4 columns(VOut in [[stage_in]],
                        texture2d<float> state [[texture(0)]]) {
    float sum = 0.0;
    for (int y = 0; y < 144; y++) {
        float3 px = state.sample(nn, float2(in.uv.x, (float(y) + 0.5) / 144.0)).rgb;
        sum += dot(px, float3(0.299, 0.587, 0.114));
    }
    return float4(sum / 144.0, 0.0, 0.0, 1.0);
}

// Static hash noise in [-1, 1] — time-varying grain would flicker.
float grain_hash(float2 v) {
    return fract(sin(dot(v, float2(12.9898, 78.233))) * 43758.5453) * 2.0 - 1.0;
}

// Pass 2, at display resolution: the dot structure. The frame sits at an
// integer scale, centred; outside it, the bezel. Inside, each game pixel
// is a dot whose right and bottom edges give way to the reflector, held
// under a ceiling: the grid may modulate a light shade by ~1.2% and a
// dark one by ~31.4% — the measured numbers — and no more. (Geometry
// alone was tried first: a near-white reflector against dark ink flooded
// every dark scene.) Each dot shadows its own gap; paper grain and a
// breath of vignette close the pass.
fragment float4 dots(VOut in [[stage_in]],
                     texture2d<float> state [[texture(0)]],
                     texture2d<float> columnLuma [[texture(1)]],
                     constant Params& p [[buffer(0)]]) {
    float scale = p.scale.x;
    float2 px = in.pos.xy - p.geometry.xy;
    float2 game = floor(px / scale);

    if (game.x < 0.0 || game.x >= 160.0 || game.y < 0.0 || game.y >= 144.0)
        return float4(0.02, 0.02, 0.02, 1.0);

    float3 ink = state.sample(nn, (game + 0.5) / float2(160.0, 144.0)).rgb;

    // STN row drive: each dot borrows a little from the one above it —
    // the vertical softness of the multiplexed scheme. Row 0 has nobody
    // above and keeps to itself.
    if (p.c.x > 0.0) {
        float2 up = float2(game.x + 0.5, max(game.y - 0.5, 0.5)) / float2(160.0, 144.0);
        ink = mix(ink, state.sample(nn, up).rgb, p.c.x);
    }

    // Passive-matrix crosstalk: a column is dimmed by its own dark
    // content — the streak a dark sprite drags down the screen — plus a
    // fixed per-column gain the factory never trimmed. Static, both.
    if (p.c.y > 0.0) {
        float column = columnLuma.sample(nn, float2((game.x + 0.5) / 160.0, 0.5)).r;
        ink *= 1.0 - p.c.y * (1.0 - column) + 0.01 * grain_hash(float2(game.x, 7.0));
    }

    float3 color = ink;

    // The CGB's dots really are three strips. Full amplitude while a
    // strip spans four device pixels or fewer, gone by eight — the moiré
    // guard, which also keeps 8× from turning into coloured bars.
    if (p.c.z > 0.0 && scale >= 3.0) {
        float stripW = scale / 3.0;
        float amp = p.c.z * clamp((8.0 - stripW) / 4.0, 0.0, 1.0);

        if (amp > 0.0) {
            int strip = clamp(int((px.x - game.x * scale) / stripW), 0, 2);
            float3 mask = strip == 0 ? float3(1.0 + amp, 1.0 - amp * 0.4, 1.0 - amp * 0.4)
                        : strip == 1 ? float3(1.0 - amp * 0.4, 1.0 + amp, 1.0 - amp * 0.4)
                                     : float3(1.0 - amp * 0.4, 1.0 - amp * 0.4, 1.0 + amp);
            color *= mask;
        }
    }

    if (p.b.w > 0.5) {
        // The tube: the beam paints each game row as a bright core falling
        // off vertically — bright lines swell, dark ones thin — and an
        // aperture grille stripes the device pixels in R, G, B.
        float2 cell = (px - game * scale) / scale;
        float luma = dot(ink, float3(0.299, 0.587, 0.114));
        float beam = mix(0.55, 1.0, luma);
        float d = fabs(cell.y - 0.5) * 2.0;
        float line = smoothstep(beam + 0.2, beam - 0.2, d);
        color = ink * (0.30 + 0.80 * line);

        int strip = int(px.x) % 3;
        float3 grille = strip == 0 ? float3(1.05, 0.85, 0.85)
                      : strip == 1 ? float3(0.85, 1.05, 0.85)
                                   : float3(0.85, 0.85, 1.05);
        color *= grille;
    }

    float gapPx = (p.a.w > 0.0 && scale >= 3.0) ? max(1.0, round(scale * p.a.w)) : 0.0;
    if (gapPx > 0.0) {
        float2 cell = px - game * scale;
        if (cell.x >= scale - gapPx || cell.y >= scale - gapPx) {
            float darkness = 1.0 - dot(ink, float3(0.299, 0.587, 0.114));
            // The reflector shows through the gap, shadowed by its dot —
            // but never brighter than the measured grid modulation: 1.2%
            // over a light shade, 31.4% over a dark one, plus a whisper on
            // true black so the grid does not vanish there. Without this
            // ceiling a bright reflector floods every dark scene and the
            // picture washes out.
            float3 through = p.reflector.rgb * (1.0 - p.b.x * darkness);
            float lift = mix(0.012, 0.314, darkness);
            color = min(through, ink * (1.0 + lift) + lift * 0.08);
        }
    }

    // Aging: hashed columns die first at the edges — reflector-tinted,
    // partial length, softly banded, and static: the panel's biography,
    // not its mood. The 2.2 curve makes the slider's first tenth one
    // dead line and its end most of the glass.
    if (p.c.w > 0.002) {
        float density = pow(p.c.w, 2.2);
        float edge = 1.0 + 1.5 * pow(fabs(game.x - 79.5) / 79.5, 3.0);
        float h = grain_hash(float2(game.x, 3.0)) * 0.5 + 0.5;

        if (h < density * edge) {
            float reach = (0.4 + 0.6 * fract(h * 37.7)) * 144.0;
            float fade = smoothstep(reach + 8.0, reach - 8.0, game.y);
            float band = 0.85 + 0.15 * sin(game.y * 1.26);
            float3 dead = max(p.reflector.rgb, float3(0.72));
            color = mix(color, dead * band, (1.0 - fade) * 0.9);
        }
    }

    color *= 1.0 + p.b.y * grain_hash(floor(in.pos.xy));

    float2 c = in.pos.xy / p.geometry.zw - 0.5;
    color *= 1.0 - p.b.z * dot(c, c) * 4.0;

    return float4(color, 1.0);
}
"""

// The Metal path: a CAMetalLayer fed two passes per engine frame. `nil`
// from init means no device or a shader that refused to compile — the
// caller falls back to the CALayer and loses only the panel's life, not
// the game.
final class MetalScreen {
    let layer = CAMetalLayer()
    private let queue: MTLCommandQueue
    private let respond: MTLRenderPipelineState
    private let dots: MTLRenderPipelineState
    private let columns: MTLRenderPipelineState
    private let frameTex: MTLTexture
    private let columnsTex: MTLTexture
    private var states: [MTLTexture]
    private var ping = 0
    private var rgba = [UInt8](repeating: 255, count: WIDTH * HEIGHT * 4)

    // Rendering lives on its own queue: `nextDrawable()` can block for up
    // to a second when the window is occluded or mid-resize, and on the
    // main thread that block is the beachball — with the engine's frames
    // piling up behind it until the pipe freezes the game too. Here the
    // stall lands on a thread nobody is watching, `pending` collapses the
    // backlog to the newest frame, and the semaphore keeps the CPU off
    // textures the GPU is still reading.
    private let renderQueue = DispatchQueue(label: "atomboy.panel", qos: .userInteractive)
    private let inflight = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var pending: Data?
    private var size = CGSize.zero
    private var seed = true
    private var preset = PanelPreset.all[0]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: PANEL_SHADER, options: nil)
        else { return nil }

        func pipeline(_ fragment: String, format: MTLPixelFormat) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fullscreen")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try? device.makeRenderPipelineState(descriptor: d)
        }

        // The state lives in float16 — the article is blunt that 8-bit
        // intermediates stall the decay into visible steps.
        func texture(_ format: MTLPixelFormat, renderable: Bool) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: WIDTH, height: HEIGHT, mipmapped: false)
            d.usage = renderable ? [.renderTarget, .shaderRead] : [.shaderRead]
            return device.makeTexture(descriptor: d)
        }

        // The crosstalk aggregate: one row of texels, one per column.
        func columnTexture() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: WIDTH, height: 1, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return device.makeTexture(descriptor: d)
        }

        guard let respond = pipeline("respond", format: .rgba16Float),
              let dots = pipeline("dots", format: .bgra8Unorm),
              let columns = pipeline("columns", format: .rgba16Float),
              let frameTex = texture(.rgba8Unorm, renderable: false),
              let columnsTex = columnTexture(),
              let stateA = texture(.rgba16Float, renderable: true),
              let stateB = texture(.rgba16Float, renderable: true)
        else { return nil }

        self.queue = queue
        self.respond = respond
        self.dots = dots
        self.columns = columns
        self.frameTex = frameTex
        self.columnsTex = columnsTex
        self.states = [stateA, stateB]

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.backgroundColor = NSColor.black.cgColor
    }

    // The engine announced its panel: new parameters, and the state
    // re-seeded — the old floats lived on another panel's colours.
    func panel(_ index: Int) {
        lock.lock()
        preset = PanelPreset.all[min(max(index, 0), PanelPreset.all.count - 1)]
        seed = true
        lock.unlock()
    }

    // The view resized (or moved to another display): the drawable follows
    // the device pixels. The next frame repaints — at 60 Hz it is never
    // far away.
    func resize(_ size: CGSize, contentsScale: CGFloat) {
        layer.contentsScale = contentsScale
        let w = size.width * contentsScale
        let h = size.height * contentsScale
        guard w > 0 && h > 0 else { return }
        layer.drawableSize = CGSize(width: w, height: h)
        lock.lock()
        self.size = CGSize(width: w, height: h)
        lock.unlock()
    }

    // Main thread: park the frame and return — never block. A frame that
    // arrives while another renders replaces it: the newest picture wins,
    // the backlog never grows.
    func submit(_ rgb: Data) {
        lock.lock()
        let idle = pending == nil
        pending = rgb
        lock.unlock()
        if idle { renderQueue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            let rgb = pending
            pending = nil
            lock.unlock()
            guard let rgb else { return }
            render(rgb)
        }
    }

    private func render(_ rgb: Data) {
        lock.lock()
        let size = self.size
        let preset = self.preset
        let seeding = self.seed
        lock.unlock()

        guard size.width >= CGFloat(WIDTH), size.height >= CGFloat(HEIGHT) else { return }

        // RGB24 through an alpha channel: Metal has no 3-byte format.
        rgb.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let src = raw.bindMemory(to: UInt8.self)
            for i in 0..<(WIDTH * HEIGHT) {
                rgba[4 * i] = src[3 * i]
                rgba[4 * i + 1] = src[3 * i + 1]
                rgba[4 * i + 2] = src[3 * i + 2]
            }
        }

        // The block, if it comes, lands here — off the main thread.
        guard let drawable = layer.nextDrawable() else { return }

        // One frame in flight: the GPU signals on completion, and only
        // then does the CPU touch the textures again.
        inflight.wait()

        frameTex.replace(
            region: MTLRegionMake2D(0, 0, WIDTH, HEIGHT), mipmapLevel: 0,
            withBytes: rgba, bytesPerRow: WIDTH * 4)

        // Integer scale, centred: a fractional scale would moiré the grid.
        // The drawable's own dimensions are the truth mid-resize.
        let dw = drawable.texture.width
        let dh = drawable.texture.height
        let scale = max(1, min(dw / WIDTH, dh / HEIGHT))
        let ox = (Float(dw) - Float(WIDTH * scale)) / 2
        let oy = (Float(dh) - Float(HEIGHT * scale)) / 2

        // Aging is a preference the uniform reads directly — dead columns
        // are an LCD's biography, so raw and the CRT stay untouched.
        let age = preset.gap > 0 ? Float(UserDefaults.standard.double(forKey: "reglages.usure")) : 0

        var uniforms = PanelUniforms(
            a: SIMD4(preset.alphaFall, preset.alphaRise, seeding ? 1 : 0, preset.gap),
            b: SIMD4(preset.shadow, preset.grain, preset.vignette, preset.crt ? 1 : 0),
            c: SIMD4(preset.stn, preset.crosstalk, preset.subpixel, age),
            reflector: preset.reflector,
            geometry: SIMD4(ox, oy, Float(dw), Float(dh)),
            scale: SIMD4(Float(scale), 0, 0, 0))

        guard let commands = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }

        // The seed is spent only once a frame actually renders with it.
        if seeding {
            lock.lock()
            seed = false
            lock.unlock()
        }

        // Pass 1: the response curve, ping → pong.
        let source = states[ping]
        let target = states[1 - ping]
        ping = 1 - ping

        let respondPass = MTLRenderPassDescriptor()
        respondPass.colorAttachments[0].texture = target
        respondPass.colorAttachments[0].loadAction = .dontCare
        respondPass.colorAttachments[0].storeAction = .store

        if let encoder = commands.makeRenderCommandEncoder(descriptor: respondPass) {
            encoder.setRenderPipelineState(respond)
            encoder.setFragmentTexture(frameTex, index: 0)
            encoder.setFragmentTexture(source, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PanelUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // Pass 1½: the column aggregate the crosstalk reads.
        let columnsPass = MTLRenderPassDescriptor()
        columnsPass.colorAttachments[0].texture = columnsTex
        columnsPass.colorAttachments[0].loadAction = .dontCare
        columnsPass.colorAttachments[0].storeAction = .store

        if let encoder = commands.makeRenderCommandEncoder(descriptor: columnsPass) {
            encoder.setRenderPipelineState(columns)
            encoder.setFragmentTexture(target, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // Pass 2: the dot structure, into the drawable.
        let presentPass = MTLRenderPassDescriptor()
        presentPass.colorAttachments[0].texture = drawable.texture
        presentPass.colorAttachments[0].loadAction = .dontCare
        presentPass.colorAttachments[0].storeAction = .store

        if let encoder = commands.makeRenderCommandEncoder(descriptor: presentPass) {
            encoder.setRenderPipelineState(dots)
            encoder.setFragmentTexture(target, index: 0)
            encoder.setFragmentTexture(columnsTex, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PanelUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        commands.addCompletedHandler { [inflight] _ in inflight.signal() }
        commands.present(drawable)
        commands.commit()
    }
}

// ── The engine ────────────────────────────────────────────────────────────────

// A GameShark code as the settings window keeps it: the hex text, and its
// switch — persisted per game in UserDefaults.
struct GSCode: Codable, Identifiable, Equatable {
    var id: String { text }
    var text: String
    var enabled: Bool
}

// ── The library, decoded ─────────────────────────────────────────────────────

// One named state as the engine reports it: name, ISO 8601 timestamp, and
// the screenshot's path on disk — the shell reads the thumbnail itself.
struct SavedState: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let at: String
    let png: String?

    var date: Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: at) { return date }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: at)
    }
}

struct LibraryInfo: Codable, Equatable {
    let game: String
    let profile: String
    let profiles: [String]
    let states: [SavedState]
}

// ── The keyboard, rebindable ─────────────────────────────────────────────────

// One row per action: the id is the UserDefaults key (French, like every
// persisted name), the letter the protocol byte, the default the key the
// shell has always used. Escape is not here — it stays reserved.
struct Keybind: Identifiable {
    let id: String
    let label: String
    let letter: Character
    let defaultCode: UInt16
    let defaultKey: String

    static let all: [Keybind] = [
        Keybind(id: "haut", label: "Up", letter: "U", defaultCode: 126, defaultKey: "↑"),
        Keybind(id: "bas", label: "Down", letter: "D", defaultCode: 125, defaultKey: "↓"),
        Keybind(id: "gauche", label: "Left", letter: "L", defaultCode: 123, defaultKey: "←"),
        Keybind(id: "droite", label: "Right", letter: "R", defaultCode: 124, defaultKey: "→"),
        Keybind(id: "a", label: "A", letter: "A", defaultCode: 7, defaultKey: "X"),
        Keybind(id: "b", label: "B", letter: "B", defaultCode: 8, defaultKey: "C"),
        Keybind(id: "start", label: "Start", letter: "S", defaultCode: 36, defaultKey: "Return"),
        Keybind(id: "select", label: "Select", letter: "E", defaultCode: 49, defaultKey: "Space"),
        Keybind(id: "turbo", label: "Turbo", letter: "T", defaultCode: 48, defaultKey: "Tab"),
        Keybind(id: "rembobiner", label: "Rewind", letter: "W", defaultCode: 51, defaultKey: "Delete"),
        Keybind(id: "pause", label: "Pause", letter: "P", defaultCode: 35, defaultKey: "P"),
        Keybind(id: "menu", label: "Settings", letter: "M", defaultCode: 46, defaultKey: "M"),
    ]

    // A stolen key leaves its old action on this sentinel — bound to
    // nothing, shown as an em dash until the player rebinds it.
    static let unbound: UInt16 = 0xFFFF

    static var stored: [String: [String: Any]] {
        get {
            UserDefaults.standard.dictionary(forKey: "reglages.touches")
                as? [String: [String: Any]] ?? [:]
        }
        set { UserDefaults.standard.set(newValue, forKey: "reglages.touches") }
    }

    static func code(of bind: Keybind) -> UInt16 {
        guard let raw = stored[bind.id]?["code"] as? Int, raw >= 0, raw <= 0xFFFF else {
            return bind.defaultCode
        }
        return UInt16(raw)
    }

    static func keyLabel(of bind: Keybind) -> String {
        stored[bind.id]?["label"] as? String ?? bind.defaultKey
    }

    static func rebind(_ bind: Keybind, to code: UInt16, label: String) {
        var map = stored
        for other in all where other.id != bind.id && Keybind.code(of: other) == code {
            map[other.id] = ["code": Int(unbound), "label": ""]
        }
        map[bind.id] = ["code": Int(code), "label": label]
        stored = map
    }

    static func reset() { UserDefaults.standard.removeObject(forKey: "reglages.touches") }

    static func letter(for keyCode: UInt16) -> Character? {
        all.first(where: { code(of: $0) == keyCode })?.letter
    }
}

final class Engine: ObservableObject {
    // The Metal path when the device wakes, the CALayer otherwise — one
    // `layer` either way, and the view never knows which it got.
    let metal = MetalScreen()
    let layer: CALayer
    @Published var settingsRequested = false
    @Published var savesRequested = false
    @Published var library: LibraryInfo?
    @Published var game: String?
    @Published var recentROMs: [URL] = Engine.loadRecents()
    var runningProcess: Process? { process }
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    private let audio = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 32768, channels: 2, interleaved: false)!
    private var audioStarted = false

    init() {
        if let metal {
            layer = metal.layer
        } else {
            let fallback = CALayer()
            fallback.magnificationFilter = .nearest
            fallback.contentsGravity = .resizeAspect
            fallback.backgroundColor = NSColor.black.cgColor
            layer = fallback
        }

        attachGamepads()
    }

    // A button held or released — the gamepad and the keyboard speak the
    // same protocol, press and release kept separate.
    func button(_ key: Character, pressed: Bool) {
        let op: UInt8 = pressed ? UInt8(ascii: "+") : UInt8(ascii: "-")
        try? input?.write(contentsOf: Data([op, UInt8(key.asciiValue ?? 0)]))
    }

    // ── The gamepad: GameController, edges only ──────────────────────────────

    // The held state, per gamepad: only emit CHANGES — GameController's
    // handlers fire on every twitch of a stick, and the pipe has no need for
    // ten thousand identical presses.
    private var heldButtons: [ObjectIdentifier: Set<Character>] = [:]

    private func attachGamepads() {
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            if let gamepad = note.object as? GCController { self?.configure(gamepad) }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let gamepad = note.object as? GCController else { return }
            // Release everything it was holding — no phantom buttons.
            for key in heldButtons[ObjectIdentifier(gamepad)] ?? [] {
                button(key, pressed: false)
            }
            heldButtons[ObjectIdentifier(gamepad)] = nil
        }

        GCController.controllers().forEach(configure)
    }

    private func configure(_ gamepad: GCController) {
        guard let pad = gamepad.extendedGamepad else { return }
        let id = ObjectIdentifier(gamepad)
        heldButtons[id] = []

        pad.valueChangedHandler = { [weak self] pad, _ in
            DispatchQueue.main.async { self?.readPad(pad, id: id) }
        }
    }

    // The wanted state is recomputed whole on every event (dpad OR stick per
    // direction, threshold ±0.5), then diffed against the held one: only the
    // edges go down the pipe.
    private func readPad(_ pad: GCExtendedGamepad, id: ObjectIdentifier) {
        var wanted: Set<Character> = []

        if pad.dpad.up.isPressed || pad.leftThumbstick.yAxis.value > 0.5 { wanted.insert("U") }
        if pad.dpad.down.isPressed || pad.leftThumbstick.yAxis.value < -0.5 { wanted.insert("D") }
        if pad.dpad.left.isPressed || pad.leftThumbstick.xAxis.value < -0.5 { wanted.insert("L") }
        if pad.dpad.right.isPressed || pad.leftThumbstick.xAxis.value > 0.5 { wanted.insert("R") }
        if pad.buttonA.isPressed { wanted.insert("A") }
        if pad.buttonB.isPressed { wanted.insert("B") }
        if pad.buttonMenu.isPressed { wanted.insert("S") }
        if pad.buttonOptions?.isPressed == true { wanted.insert("E") }
        if pad.leftShoulder.isPressed { wanted.insert("W") }

        let held = heldButtons[id] ?? []
        for key in wanted.subtracting(held) { button(key, pressed: true) }
        for key in held.subtracting(wanted) { button(key, pressed: false) }
        heldButtons[id] = wanted

        // Turbo is a toggle on the engine side: rising edge only.
        let turbo = pad.rightShoulder.isPressed || pad.rightTrigger.isPressed
        if turbo && !turboHeld { press("T") }
        turboHeld = turbo

        // X saves, Y reloads — the console reflex, on the rising edge.
        if pad.buttonX.isPressed && !saveHeld { press("s") }
        saveHeld = pad.buttonX.isPressed
        if pad.buttonY.isPressed && !loadHeld { press("r") }
        loadHeld = pad.buttonY.isPressed
    }

    private var turboHeld = false
    private var saveHeld = false
    private var loadHeld = false

    // A short tap "from the menu bar": press, then release.
    func press(_ key: Character) {
        let byte = UInt8(key.asciiValue ?? 0)
        try? input?.write(contentsOf: Data([UInt8(ascii: "+"), byte]))
        try? input?.write(contentsOf: Data([UInt8(ascii: "-"), byte]))
    }

    // The native mixer: volume 0-100 ('V') and the four-voice mask ('X').
    func volume(_ v: Int) {
        try? input?.write(contentsOf: Data([UInt8(ascii: "V"), UInt8(max(0, min(100, v)))]))
    }

    func voices(_ enabled: [Bool]) {
        var mask: UInt8 = 0
        for (i, on) in enabled.enumerated() where on { mask |= 1 << UInt8(i) }
        try? input?.write(contentsOf: Data([UInt8(ascii: "X"), mask]))
    }

    // The native panel picker: 'N' carries the preset index down the pipe;
    // the engine recompiles its tables and answers with 'P' — the shader
    // follows without a restart.
    func setPanel(_ index: Int) {
        try? input?.write(contentsOf: Data([UInt8(ascii: "N"), UInt8(max(0, min(4, index)))]))
    }

    // ── The save library: six ops out, one JSON record back ─────────────────

    private func libraryOp(_ letter: Character, _ name: String = "") {
        let bytes = Array(name.utf8.prefix(255))
        var data = Data([UInt8(letter.asciiValue ?? 0), UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        try? input?.write(contentsOf: data)
    }

    func requestLibrary() { libraryOp("L") }
    func saveNamed(_ name: String) { libraryOp("K", name) }
    func loadNamed(_ name: String) { libraryOp("O", name) }
    func deleteNamed(_ name: String) { libraryOp("D", name) }
    func setProfile(_ name: String) { libraryOp("F", name) }
    func exportSav() { libraryOp("E") }

    // The contrast dial: 0-100 down the pipe, anything else asks the
    // engine for the preset's own resting point.
    func setDial(_ value: Int) {
        let byte = UInt8(value >= 0 && value <= 100 ? value : 255)
        try? input?.write(contentsOf: Data([UInt8(ascii: "G"), byte]))
    }

    // ── Screenshots: the frame the engine last drew ──────────────────────────

    private(set) var lastFrame: Data?

    // The raw 160×144 pixels as a bitmap — the panel's colours are already
    // in them, the engine applied its tables before the pipe.
    private func bitmap() -> NSBitmapImageRep? {
        guard let frame = lastFrame,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: WIDTH, pixelsHigh: HEIGHT,
                  bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: WIDTH * 3, bitsPerPixel: 24),
              let bytes = rep.bitmapData
        else { return nil }

        frame.copyBytes(to: bytes, count: min(frame.count, FRAME_BYTES))
        return rep
    }

    // ⌘C: the screen onto the pasteboard at 3×, nearest neighbour —
    // paste-ready without squinting.
    func copyScreen() {
        guard let rep = bitmap() else { return }

        let size = NSSize(width: WIDTH * 3, height: HEIGHT * 3)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        rep.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()

        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    // ⌥⌘S: 1× native PNG into ~/Pictures/Atomboy — pure pixels, archival.
    func saveScreenshot() {
        guard let rep = bitmap(), let png = rep.representation(using: .png, properties: [:])
        else { return }

        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
        guard let folder = pictures.first?.appendingPathComponent("Atomboy") else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = "\(game ?? "atomboy") — \(stamp.string(from: Date())).png"
        try? png.write(to: folder.appendingPathComponent(name))
    }

    // ── Reset and the background ─────────────────────────────────────────────

    // The hardware button: a power cycle on the current battery. The
    // engine flushes the save first — nothing worth a confirmation dialog.
    func reset() {
        setProfile(library?.profile ?? "game")
    }

    // The background pause is the shell's own toggle-pair: nothing can
    // touch pause while the app has no keyboard focus, so P out and P back
    // stay symmetric. Off by preference; the flag keeps re-entry honest.
    private var backgroundPaused = false

    func enteredBackground() {
        let wants =
            UserDefaults.standard.object(forKey: "reglages.pauseFond") == nil
            || UserDefaults.standard.bool(forKey: "reglages.pauseFond")
        guard wants, !isIdle, !backgroundPaused else { return }
        press("P")
        backgroundPaused = true
    }

    func enteredForeground() {
        guard backgroundPaused else { return }
        press("P")
        backgroundPaused = false
    }

    func launch(rom: URL) {
        stop()

        // "atomboy-moteur", not "atomboy": APFS is case-insensitive, and
        // "atomboy" would clobber the "Atomboy" shell (learned the hard way).
        // The name is also baked into bin/build and into shipped bundles —
        // renaming it takes a coordinated change on both sides.
        let p = Process()
        p.executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/atomboy-moteur")
        // `--serveur` is the engine's own CLI flag: it stays as it is.
        p.arguments = [rom.path, "--serveur"]
        p.currentDirectoryURL = rom.deletingLastPathComponent()

        let fromEngine = Pipe()
        let toEngine = Pipe()
        p.standardOutput = fromEngine
        p.standardInput = toEngine
        p.standardError = FileHandle.standardError

        fromEngine.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            if data.isEmpty { return }
            DispatchQueue.main.async { self?.receive(data) }
        }

        p.terminationHandler = { _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }

        input = toEngine.fileHandleForWriting
        process = p
        game = rom.deletingPathExtension().lastPathComponent
        noteRecent(rom)
        try? p.run()

        // The persisted settings catch up with the freshly born engine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            volume(defaults.object(forKey: "reglages.volume") as? Int ?? 100)
            let mask = defaults.object(forKey: "reglages.voixMasque") as? Int ?? 15
            voices((0..<4).map { mask & (1 << $0) != 0 })
            setPanel(defaults.object(forKey: "reglages.panneau") as? Int ?? 0)
            sendActiveCodes()

            let dial = defaults.object(forKey: "reglages.contraste") as? Int ?? -1
            if dial >= 0 { setDial(dial) }

            requestLibrary()
        }
    }

    // ── The recent ROMs, persisted ───────────────────────────────────────────

    // NOTE: "recentes" — like every "reglages.*" and "codes.*" key in this
    // file — is a legacy French key name kept as-is: these strings address
    // data already written to users' UserDefaults, so renaming them would
    // silently drop everybody's settings, recent list and cheat codes.

    static func loadRecents() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: "recentes") ?? [])
            .map(URL.init(fileURLWithPath:))
    }

    private func noteRecent(_ rom: URL) {
        recentROMs.removeAll { $0.path == rom.path }
        recentROMs.insert(rom, at: 0)
        recentROMs = Array(recentROMs.prefix(8))
        UserDefaults.standard.set(recentROMs.map(\.path), forKey: "recentes")
    }

    func clearRecents() {
        recentROMs = []
        UserDefaults.standard.removeObject(forKey: "recentes")
    }

    // ── The GameShark codes, persisted per game ──────────────────────────────

    static func loadCodes(_ game: String) -> [GSCode] {
        guard let data = UserDefaults.standard.data(forKey: "codes." + game),
              let codes = try? JSONDecoder().decode([GSCode].self, from: data)
        else { return [] }
        return codes
    }

    static func saveCodes(_ codes: [GSCode], game: String) {
        if let data = try? JSONEncoder().encode(codes) {
            UserDefaults.standard.set(data, forKey: "codes." + game)
        }
    }

    // The active set, sent as a full replacement ('C' + length).
    func sendActiveCodes() {
        guard let game else { return }
        let payload = Engine.loadCodes(game).filter(\.enabled).map(\.text).joined(separator: ",")
        let bytes = Array(payload.utf8.prefix(255))
        var data = Data([UInt8(ascii: "C"), UInt8(bytes.count)])
        data.append(contentsOf: bytes)
        try? input?.write(contentsOf: data)
    }

    func stop() {
        process?.terminationHandler = nil
        try? input?.close()
        process?.terminate()
        process = nil
    }

    // ── The incoming stream: frames and PCM, sliced as they arrive ───────────

    private func receive(_ data: Data) {
        buffer.append(data)

        while true {
            guard let tag = buffer.first else { return }

            if tag == UInt8(ascii: "F") {
                guard buffer.count >= 1 + FRAME_BYTES else { return }
                draw(buffer.subdata(in: 1..<(1 + FRAME_BYTES)))
                buffer.removeSubrange(0..<(1 + FRAME_BYTES))
            } else if tag == UInt8(ascii: "A") {
                guard buffer.count >= 3 else { return }
                let n = Int(buffer[1]) << 8 | Int(buffer[2])
                guard buffer.count >= 3 + n else { return }
                play(buffer.subdata(in: 3..<(3 + n)))
                buffer.removeSubrange(0..<(3 + n))
            } else if tag == UInt8(ascii: "J") {
                guard buffer.count >= 5 else { return }
                let n =
                    Int(buffer[1]) << 24 | Int(buffer[2]) << 16 | Int(buffer[3]) << 8
                    | Int(buffer[4])
                guard buffer.count >= 5 + n else { return }
                let payload = buffer.subdata(in: 5..<(5 + n))
                if let info = try? JSONDecoder().decode(LibraryInfo.self, from: payload) {
                    library = info
                }
                buffer.removeSubrange(0..<(5 + n))
            } else if tag == UInt8(ascii: "P") {
                guard buffer.count >= 2 else { return }
                metal?.panel(Int(buffer[1]))
                buffer.removeSubrange(0..<2)
            } else {
                // Stream out of sync: drop the byte and catch up.
                buffer.removeFirst()
            }
        }
    }

    private func draw(_ rgb: Data) {
        lastFrame = rgb

        if let metal {
            metal.submit(rgb)
            return
        }

        guard let provider = CGDataProvider(data: rgb as CFData),
              let image = CGImage(
                  width: WIDTH, height: HEIGHT, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: WIDTH * 3, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false,
                  intent: .defaultIntent)
        else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    private func play(_ pcm: Data) {
        if !audioStarted {
            audio.attach(player)
            audio.connect(player, to: audio.mainMixerNode, format: format)
            try? audio.start()
            player.play()
            audioStarted = true
        }

        let frames = pcm.count / 4
        guard frames > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(frames)

        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let s16 = raw.bindMemory(to: Int16.self)
            let left = pcmBuffer.floatChannelData![0]
            let right = pcmBuffer.floatChannelData![1]
            for i in 0..<frames {
                left[i] = Float(Int16(littleEndian: s16[2 * i])) / 32768.0
                right[i] = Float(Int16(littleEndian: s16[2 * i + 1])) / 32768.0
            }
        }

        player.scheduleBuffer(pcmBuffer, completionHandler: nil)
    }

    // ── The keyboard, relayed ────────────────────────────────────────────────

    func handleKey(_ event: NSEvent, pressed: Bool) -> Bool {
        guard let key = Engine.key(event) else { return false }
        let op: UInt8 = pressed ? UInt8(ascii: "+") : UInt8(ascii: "-")
        try? input?.write(contentsOf: Data([op, key]))
        return true
    }

    // The bindings live in Keybind — the Controls tab rewrites them, this
    // simply asks. Esc is handled by the view before it ever gets here.
    private static func key(_ event: NSEvent) -> UInt8? {
        Keybind.letter(for: event.keyCode).flatMap(\.asciiValue)
    }
}

// ── The view: one scaled layer, the keyboard tapped directly ─────────────────

final class ScreenView: NSView {
    var engine: Engine?

    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        engine?.layer ?? CALayer()
    }

    // The window keeps the panel's aspect ratio: no black bars — and the
    // keyboard comes back to us as soon as the window exists, with no click
    // first. Without a title bar, the frame itself is what you grab to move
    // the window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.contentAspectRatio = NSSize(width: WIDTH, height: HEIGHT)
        window?.isMovableByWindowBackground = true
        window?.makeFirstResponder(self)

        // The traffic lights are born invisible — they only show up on
        // hover, like the HUD.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.alphaValue = 0
        }
    }

    // The Metal drawable tracks the view in device pixels — through
    // resizes and through moves to a display with another scale factor.
    override func layout() {
        super.layout()
        engine?.metal?.resize(bounds.size, contentsScale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        engine?.metal?.resize(bounds.size, contentsScale: window?.backingScaleFactor ?? 2)
    }

    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }

        // Esc (or m): the NATIVE panel, not the engine's pixel menu — in a
        // macOS app, settings speak SwiftUI.
        if event.keyCode == 53 || Keybind.letter(for: event.keyCode) == "M" {
            engine?.settingsRequested.toggle()
            return
        }

        if engine?.handleKey(event, pressed: true) != true { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        if engine?.handleKey(event, pressed: false) != true { super.keyUp(with: event) }
    }
}

struct Screen: NSViewRepresentable {
    let engine: Engine

    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView()
        view.engine = engine
        view.wantsLayer = true
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: ScreenView, context: Context) {}
}

// ── The glass HUD: the controls on hover, the screen otherwise ───────────────

struct HUDButton: View {
    let symbol: String
    let tooltip: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
    }
}

struct HUD: View {
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 2) {
            HUDButton(symbol: "forward.fill", tooltip: "Turbo (Tab)") { engine.press("T") }
            HUDButton(symbol: "square.and.arrow.down", tooltip: "Save State (⌘S)") { engine.press("s") }
            HUDButton(symbol: "arrow.counterclockwise", tooltip: "Load State (⌘R)") { engine.press("r") }
            HUDButton(symbol: "square.stack", tooltip: "Saves (⌘⇧S)") { engine.savesRequested = true }
            HUDButton(symbol: "slider.horizontal.3", tooltip: "Settings (Esc)") { engine.settingsRequested.toggle() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(Glass())
    }
}

// ── Settings (⌘,): the macOS convention, persisted ───────────────────────────

struct GeneralSettings: View {
    // Legacy French UserDefaults key — kept for data compatibility.
    @AppStorage("reglages.reprise") private var resume = true

    @AppStorage("reglages.pauseFond") private var pauseInBackground = true

    var body: some View {
        Form {
            Toggle("Resume the last game on launch", isOn: $resume)
            Text("Otherwise, the app asks you to pick a ROM.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Pause when in the background", isOn: $pauseInBackground)
            Text("The game holds its breath while another app has the stage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct ScreenSettings: View {
    let engine: Engine
    // French keys, like every persisted "reglages.*" name.
    @AppStorage("reglages.panneau") private var panel = 0
    @AppStorage("reglages.contraste") private var contrast = -1
    @AppStorage("reglages.usure") private var age = 0.0

    private static let names = [
        "Raw — the pixels, straight",
        "DMG — the 1989 green, ghosting and all",
        "Pocket — the FSTN gray, tighter",
        "Color — the CGB glass",
        "CRT — the Super Game Boy's television",
    ]

    var body: some View {
        Form {
            Picker("Panel", selection: $panel) {
                ForEach(0..<5, id: \.self) { i in
                    Text(Self.names[i]).tag(i)
                }
            }
            .pickerStyle(.radioGroup)
            .onChange(of: panel) { engine.setPanel(panel) }

            Text("The screen the game is seen through: colour, response curve and dot structure, live — no restart.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Section("Contrast") {
                HStack {
                    Slider(
                        value: Binding(
                            get: { Double(contrast < 0 ? 50 : contrast) },
                            set: {
                                contrast = Int($0)
                                engine.setDial(contrast)
                            }), in: 0...100, step: 5)
                    Button("Reset") {
                        contrast = -1
                        engine.setDial(-1)
                    }
                    .disabled(contrast < 0)
                }
                Text("The wheel under the DMG's thumb: up toward ink, down toward the bare reflector.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Age") {
                Slider(value: $age, in: 0...1)
                Text("A panel that lived a life: dead columns creep in from the edges. Zero is factory-fresh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }
}

// ── The save browser: the library, drawn ────────────────────────────────────

struct SavesSheet: View {
    @ObservedObject var engine: Engine
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var newProfile = false
    @State private var profileName = ""
    @State private var pendingProfile: String?

    init(engine: Engine) { self.engine = engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Saves").font(.title2.bold())
                Spacer()

                if let library = engine.library {
                    // Switching hands the console over — confirmed below,
                    // because the game restarts on the other battery.
                    Picker(
                        "Cartridge",
                        selection: Binding(
                            get: { library.profile },
                            set: { chosen in
                                if chosen != library.profile { pendingProfile = chosen }
                            })
                    ) {
                        ForEach(library.profiles, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 220)

                    Button("New Profile…") { newProfile = true }
                }
            }

            HStack {
                TextField("Name this moment…", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { save() }
                Button("Save Current") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(engine.library == nil)
            }

            if let states = engine.library?.states, !states.isEmpty {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12
                    ) {
                        ForEach(states) { state in
                            StateCard(engine: engine, state: state)
                        }
                    }
                }
                .frame(minHeight: 280)
            } else {
                Spacer()
                Text("Nothing saved yet — name a moment above.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }

            HStack {
                Button("Export .sav next to ROM") { engine.exportSav() }
                    .help("Copies the battery beside the ROM, for other emulators.")
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 660, height: 500)
        .onAppear { engine.requestLibrary() }
        .alert("New Profile", isPresented: $newProfile) {
            TextField("nolan", text: $profileName)
            Button("Switch") {
                if !profileName.isEmpty { engine.setProfile(profileName) }
                profileName = ""
            }
            Button("Cancel", role: .cancel) { profileName = "" }
        } message: {
            Text(
                "A profile is another player's cartridge. Switching restarts the game on their battery."
            )
        }
        .confirmationDialog(
            "Hand the console to \(pendingProfile ?? "")?",
            isPresented: Binding(
                get: { pendingProfile != nil },
                set: { if !$0 { pendingProfile = nil } })
        ) {
            Button("Switch — the game restarts") {
                if let profile = pendingProfile { engine.setProfile(profile) }
                pendingProfile = nil
            }
            Button("Cancel", role: .cancel) { pendingProfile = nil }
        }
    }

    private func save() {
        engine.saveNamed(name.isEmpty ? "state" : name)
        name = ""
    }
}

struct StateCard: View {
    let engine: Engine
    let state: SavedState
    @State private var confirmDelete = false

    init(engine: Engine, state: SavedState) {
        self.engine = engine
        self.state = state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let png = state.png, let image = NSImage(contentsOfFile: png) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(160.0 / 144.0, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                        .aspectRatio(160.0 / 144.0, contentMode: .fit)
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(state.name).font(.callout.weight(.medium)).lineLimit(1)

            HStack {
                Text(relative).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Load") { engine.loadNamed(state.name) }
                    .controlSize(.small)
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .accessibilityLabel("Delete \(state.name)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
        .confirmationDialog("Delete \(state.name)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { engine.deleteNamed(state.name) }
        }
    }

    private var relative: String {
        guard let date = state.date else { return "" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

struct ControlsSettings: View {
    @State private var recording: String?
    @State private var monitor: Any?
    // Bumped after every rebinding so the rows re-read UserDefaults.
    @State private var version = 0

    var body: some View {
        Form {
            ForEach(Keybind.all) { bind in
                HStack {
                    Text(bind.label)
                    Spacer()
                    Button(recording == bind.id ? "Press a key…" : display(bind)) {
                        record(bind)
                    }
                    .buttonStyle(.bordered)
                    .frame(minWidth: 90)
                }
            }
            .id(version)

            HStack {
                Button("Reset to Defaults") {
                    Keybind.reset()
                    version += 1
                }
                Spacer()
                Text("Escape stays reserved for settings; it also cancels a capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onDisappear { stop() }
    }

    private func display(_ bind: Keybind) -> String {
        let label = Keybind.keyLabel(of: bind)
        return label.isEmpty ? "—" : label
    }

    private func record(_ bind: Keybind) {
        stop()
        recording = bind.id

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { DispatchQueue.main.async { stop(); version += 1 } }
            if event.keyCode != 53 {
                Keybind.rebind(bind, to: event.keyCode, label: keyName(event))
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private func keyName(_ event: NSEvent) -> String {
        switch event.keyCode {
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        default: return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }
}

struct AudioSettings: View {
    let engine: Engine
    // Legacy French UserDefaults keys — kept for data compatibility.
    @AppStorage("reglages.volume") private var volume = 100
    @AppStorage("reglages.voixMasque") private var mask = 15

    init(engine: Engine) { self.engine = engine }

    private func voiceBinding(_ i: Int) -> Binding<Bool> {
        Binding(
            get: { mask & (1 << i) != 0 },
            set: { on in
                mask = on ? mask | (1 << i) : mask & ~(1 << i)
                engine.voices((0..<4).map { mask & (1 << $0) != 0 })
            }
        )
    }

    var body: some View {
        Form {
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { volume = Int($0); engine.volume(volume) }
                    ), in: 0...100, step: 10)
                Text("\(volume)").monospacedDigit().frame(width: 32, alignment: .trailing)
            }

            Section("Voices") {
                Toggle("Pulse 1", isOn: voiceBinding(0))
                Toggle("Pulse 2", isOn: voiceBinding(1))
                Toggle("Wave", isOn: voiceBinding(2))
                Toggle("Noise", isOn: voiceBinding(3))
            }
        }
        .padding(20)
    }
}

struct CodesSettings: View {
    @ObservedObject var engine: Engine
    @State private var codes: [GSCode] = []
    @State private var entry = ""

    init(engine: Engine) { self.engine = engine }

    private var entryIsValid: Bool {
        entry.count == 8 && entry.lowercased().hasPrefix("01")
            && entry.allSatisfy(\.isHexDigit)
    }

    private func commit() {
        guard let game = engine.game else { return }
        Engine.saveCodes(codes, game: game)
        engine.sendActiveCodes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let game = engine.game {
                Text(game).font(.headline)

                List {
                    ForEach($codes) { $code in
                        HStack {
                            Toggle("", isOn: $code.enabled)
                                .labelsHidden()
                                .onChange(of: code.enabled) { commit() }
                            Text(code.text.uppercased()).monospaced()
                            Spacer()
                            Button {
                                codes.removeAll { $0.id == code.id }
                                commit()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 140)

                HStack {
                    TextField("01FF16D1", text: $entry)
                        .textFieldStyle(.roundedBorder)
                        .monospaced()
                        .onSubmit { add() }
                    Button("Add") { add() }
                        .disabled(!entryIsValid)
                }

                Text("GameShark format: 01 + value + address (little-endian).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Start a game to attach codes to it.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .onAppear { load() }
        .onChange(of: engine.game) { load() }
    }

    private func load() {
        codes = engine.game.map(Engine.loadCodes) ?? []
    }

    private func add() {
        guard entryIsValid, let _ = engine.game else { return }
        let text = entry.uppercased()
        guard !codes.contains(where: { $0.text == text }) else { return }
        codes.append(GSCode(text: text, enabled: true))
        entry = ""
        commit()
    }
}

// Liquid Glass when the system speaks it, frosted glass otherwise.
struct Glass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// Named MainScene, not Scene: a type called Scene in this module would
// shadow SwiftUI's Scene protocol that AtomboyApp.body returns.
struct MainScene: View {
    @ObservedObject var engine: Engine
    @State private var hovering = false
    @Environment(\.openSettings) private var openSettings

    init(engine: Engine) { self.engine = engine }

    var body: some View {
        ZStack(alignment: .bottom) {
            Screen(engine: engine)
                .ignoresSafeArea()

            HUD(engine: engine)
                .padding(.bottom, 14)
                .opacity(hovering ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: hovering)
        }
        // Esc and the HUD's settings button both lead to THE Settings window
        // (⌘,) — the macOS convention, not a home-made panel.
        .onChange(of: engine.settingsRequested) {
            if engine.settingsRequested {
                openSettings()
                engine.settingsRequested = false
            }
        }
        .sheet(isPresented: $engine.savesRequested) {
            SavesSheet(engine: engine)
        }
        // A ROM dropped on the screen slots in like a cartridge.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first, provider.canLoadObject(ofClass: URL.self)
            else { return false }

            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ["gb", "gbc"].contains(url.pathExtension.lowercased())
                else { return }
                DispatchQueue.main.async { engine.launch(rom: url) }
            }

            return true
        }
        .onHover { inside in
            hovering = inside
            trafficLights(visible: inside)
        }
    }

    // The traffic lights follow the HUD's rule: visible on hover, wiped
    // during play — they used to bite into the battle UI.
    private func trafficLights(visible: Bool) {
        for window in NSApp.windows {
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }
}

// ── The application ──────────────────────────────────────────────────────────

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()

    func application(_ application: NSApplication, open urls: [URL]) {
        if let rom = urls.first { engine.launch(rom: rom) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without a document: resume the last game (can be turned
        // off in Settings) — otherwise, offer to pick a ROM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            guard engine.isIdle else { return }

            // Legacy French UserDefaults key — kept for data compatibility.
            let resume = UserDefaults.standard.object(forKey: "reglages.reprise") == nil
                || UserDefaults.standard.bool(forKey: "reglages.reprise")

            if resume, let latest = engine.recentROMs.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                engine.launch(rom: latest)
            } else {
                chooseROM()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // The background pause: the polite Mac neighbour neither burns a core
    // nor keeps chiptunes going from behind another window.
    func applicationDidResignActive(_ notification: Notification) {
        engine.enteredBackground()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        engine.enteredForeground()
    }

    // The scale presets: content sized to the exact multiple, which the
    // shader's integer scale then fills edge to edge — no letterbox.
    func setScale(_ n: Int) {
        let game = NSApp.windows.first(where: {
            $0.contentAspectRatio == NSSize(width: WIDTH, height: HEIGHT)
        })

        game?.setContentSize(NSSize(width: WIDTH * n, height: HEIGHT * n))
    }

    func chooseROM() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Game Boy ROM"
        panel.allowedFileTypes = ["gb", "gbc"]
        if panel.runModal() == .OK, let url = panel.url {
            engine.launch(rom: url)
        }
    }
}

extension Engine {
    // "Idle" = no engine running — not "no frame received yet": a
    // double-click on a ROM starts the engine before the first frame.
    var isIdle: Bool { runningProcess == nil }
}

// The File menu: open, and the recent ROMs — observed, so the menu updates
// itself when the list moves.
struct FileCommands: Commands {
    let delegate: AppDelegate
    @ObservedObject var engine: Engine

    init(delegate: AppDelegate) {
        self.delegate = delegate
        self.engine = delegate.engine
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open ROM…") { delegate.chooseROM() }
                .keyboardShortcut("o")

            Button("Saves…") { engine.savesRequested = true }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(engine.isIdle)

            Menu("Recent ROMs") {
                ForEach(engine.recentROMs, id: \.path) { rom in
                    Button(rom.deletingPathExtension().lastPathComponent) {
                        engine.launch(rom: rom)
                    }
                }

                if engine.recentROMs.isEmpty {
                    Button("(empty)") {}.disabled(true)
                } else {
                    Divider()
                    Button("Clear List") { engine.clearRecents() }
                }
            }
        }
    }
}

@main
struct AtomboyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("atomboy") {
            // Full frame: the picture runs all the way to the window's
            // rounded corners, the traffic lights float on top — the aspect
            // ratio is locked by the window itself (contentAspectRatio).
            MainScene(engine: delegate.engine)
                .frame(minWidth: CGFloat(WIDTH * 2), minHeight: CGFloat(HEIGHT * 2))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: CGFloat(WIDTH * 3), height: CGFloat(HEIGHT * 3))
        .commands {
            FileCommands(delegate: delegate)

            // ⌘C: nothing else in an emulator is copyable, so the standard
            // key does the natural thing — the screen, at 3×.
            CommandGroup(replacing: .pasteboard) {
                Button("Copy Screen") { delegate.engine.copyScreen() }
                    .keyboardShortcut("c")
            }

            // The View menu: the window at an exact multiple of the panel.
            CommandGroup(after: .toolbar) {
                ForEach(1...5, id: \.self) { n in
                    Button("Scale \(n)×") { delegate.setScale(n) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(n)")), modifiers: [.command, .option])
                }
            }

            // The native idiom: the game's actions live in the menu bar too
            // — the in-game menu (Esc) stays around for the style.
            CommandMenu("Game") {
                Button("Save State") { delegate.engine.press("s") }
                    .keyboardShortcut("s")
                Button("Load State") { delegate.engine.press("r") }
                    .keyboardShortcut("r")

                Menu("State Slot") {
                    ForEach(1...9, id: \.self) { n in
                        Button("Slot \(n)") { delegate.engine.press(Character("\(n)")) }
                            .keyboardShortcut(KeyEquivalent(Character("\(n)")))
                    }
                }

                Divider()

                Button("Turbo") { delegate.engine.press("T") }
                    .keyboardShortcut("t")
                Button("Save Screenshot") { delegate.engine.saveScreenshot() }
                    .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                Button("Reset") { delegate.engine.reset() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Button("Retro Menu (in game)") { delegate.engine.press("M") }
            }
        }

        // ⌘, and "Settings…" in the app menu — the convention, served by
        // SwiftUI: audio (mixer) and GameShark codes, both persisted.
        Settings {
            TabView {
                GeneralSettings()
                    .tabItem { Label("General", systemImage: "gearshape") }
                ScreenSettings(engine: delegate.engine)
                    .tabItem { Label("Screen", systemImage: "display") }
                ControlsSettings()
                    .tabItem { Label("Controls", systemImage: "keyboard") }
                AudioSettings(engine: delegate.engine)
                    .tabItem { Label("Audio", systemImage: "speaker.wave.2") }
                CodesSettings(engine: delegate.engine)
                    .tabItem { Label("GameShark Codes", systemImage: "wand.and.stars") }
            }
            .frame(width: 440)
        }
    }
}
