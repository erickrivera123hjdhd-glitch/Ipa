import UIKit
import CoreGraphics

// Same look as lyricreel.py: black screen, album cover in a circle with a thin neon ring,
// a ring of bars where only a lobe rises with each beat, floating dots. No text.

struct LookParams: Equatable {
    var thickness: Double = 0.85   // 0 = thin & many bars ... 1 = fat & few bars
    var length: Double = 1.0       // 0 = short ... 1 = long
    var dots: Bool = true
}

struct SeededRNG: RandomNumberGenerator {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / 9007199254740992.0 }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func normal(_ sd: Double) -> Double {
        let u1 = max(1e-9, unit()), u2 = unit()
        return sd * (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

private let kW = 720.0
private let kH = 1280.0
private let kImgR = 0.205 * 720.0
private let kRingGap = 9.0
private let kRingW = 3.4
private let kBarGap = 12.0
private let kR0 = kImgR + kRingGap + kBarGap
private let kTwoPi = 2 * Double.pi

private func voiceAngle(_ t: Double) -> Double {
    -0.75 + 0.55 * sin(0.43 * t) + 0.22 * sin(1.1 * t + 1.3)
}

private func angDiff(_ a: Double, _ b: Double) -> Double {
    var d = (a - b + Double.pi).truncatingRemainder(dividingBy: kTwoPi)
    if d < 0 { d += kTwoPi }
    return d - Double.pi
}

private func lowerBound(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) / 2; if a[m] < x { lo = m + 1 } else { hi = m } }
    return lo
}

private func upperBound(_ a: [Double], _ x: Double) -> Int {
    var lo = 0, hi = a.count
    while lo < hi { let m = (lo + hi) / 2; if a[m] <= x { lo = m + 1 } else { hi = m } }
    return lo
}

final class FrameRenderer: @unchecked Sendable {
    struct Lobe { let t0: Double; let theta: Double; let h: Double; let sigma: Double }
    struct Burst { let t0: Double; let x: Double; let y: Double; let vx: Double; let vy: Double; let life: Double; let r: Double }
    struct Dust { let x: Double; let y: Double; let vx: Double; let vy: Double; let r: Double; let base: Double; let tw: Double; let tp: Double }

    let analysis: Analysis
    let look: LookParams
    let center: CGImage?

    private let nBars: Int
    private let barW: Double
    private let barBase: Double
    private let barMaxPx: Double
    private let flutW: [Double]
    private let flutP: [Double]
    private let lobes: [Lobe]
    private let lobeT: [Double]
    private let bursts: [Burst]
    private let burstT: [Double]
    private let dust: [Dust]

    init(analysis: Analysis, look: LookParams, center: CGImage?) {
        self.analysis = analysis
        self.look = look
        self.center = center

        let n = Int((132.0 - 68.0 * look.thickness).rounded())
        let pitch = kTwoPi * kR0 / Double(n)
        let bmax = min((0.17 + 0.10 * look.length) * kW, kW / 2 - kR0 - 4)
        nBars = n
        barW = 0.86 * pitch
        barBase = 8 + 10 * look.thickness
        barMaxPx = bmax

        var rng = SeededRNG(7)
        var fw: [Double] = [], fp: [Double] = []
        for _ in 0..<n { fw.append(rng.range(7, 19)); fp.append(rng.range(0, kTwoPi)) }
        flutW = fw
        flutP = fp

        var lb: [Lobe] = []
        for b in analysis.beats {
            let th = voiceAngle(b.t) + rng.normal(0.30)
            let sig = 0.22 + (0.46 - 0.22) * b.s
            lb.append(Lobe(t0: b.t, theta: th, h: 0.5 + 0.5 * b.s, sigma: sig))
            if b.s >= 0.85 {
                lb.append(Lobe(t0: b.t, theta: th + Double.pi + rng.normal(0.35), h: 0.45 * b.s, sigma: sig * 0.8))
            }
        }
        lobes = lb
        lobeT = lb.map { $0.t0 }

        var bu: [Burst] = []
        if look.dots {
            for l in lb {
                let cnt = Int(2 + 12 * min(1.0, l.h))
                for _ in 0..<cnt {
                    let a = l.theta - Double.pi / 2 + rng.normal(l.sigma * 0.9)
                    let rr = kR0 + rng.range(0.25, 1.0) * l.h * bmax
                    let sp = rng.range(25, 120) * (0.5 + l.h)
                    bu.append(Burst(t0: l.t0,
                                    x: kW / 2 + rr * cos(a), y: kH / 2 + rr * sin(a),
                                    vx: sp * cos(a) + rng.normal(8), vy: sp * sin(a) + rng.normal(8),
                                    life: rng.range(0.9, 1.9),
                                    r: [1.0, 1.3, 1.7, 2.2].randomElement(using: &rng) ?? 1.3))
                }
            }
        }
        bursts = bu
        burstT = bu.map { $0.t0 }

        var du: [Dust] = []
        if look.dots {
            let radii = [0.9, 0.9, 1.1, 1.1, 1.4, 1.4, 1.8, 2.3]
            for _ in 0..<150 {
                du.append(Dust(x: rng.range(0, kW), y: rng.range(0, kH),
                               vx: rng.normal(7), vy: rng.normal(7) - 5,
                               r: radii.randomElement(using: &rng) ?? 1.1,
                               base: rng.range(0.25, 0.95),
                               tw: rng.range(0.8, 2.6), tp: rng.range(0, kTwoPi)))
            }
        }
        dust = du
    }

    // MARK: picture prepared once (square crop, grey, contrast stretched)

    static func prepareCenter(_ image: UIImage?) -> CGImage? {
        guard let img = image ?? UIImage(named: "DefaultCenter") else { return nil }
        let d = 600
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: d, height: d), format: fmt)
        let flat = renderer.image { c in
            UIColor.black.setFill()
            c.fill(CGRect(x: 0, y: 0, width: d, height: d))
            let s = max(CGFloat(d) / img.size.width, CGFloat(d) / img.size.height)
            let w = img.size.width * s, h = img.size.height * s
            img.draw(in: CGRect(x: (CGFloat(d) - w) / 2, y: (CGFloat(d) - h) / 2, width: w, height: h))
        }
        guard let cg = flat.cgImage,
              let g = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: d,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        g.draw(cg, in: CGRect(x: 0, y: 0, width: d, height: d))
        if let p = g.data?.assumingMemoryBound(to: UInt8.self) {
            var hist = [Int](repeating: 0, count: 256)
            for i in 0..<(d * d) { hist[Int(p[i])] += 1 }
            let cut = d * d / 100
            var lo = 0, acc = 0
            while lo < 255 { acc += hist[lo]; if acc > cut { break }; lo += 1 }
            var hi = 255
            acc = 0
            while hi > 0 { acc += hist[hi]; if acc > cut { break }; hi -= 1 }
            if hi > lo + 8 {
                let sc = 255.0 / Double(hi - lo)
                for i in 0..<(d * d) {
                    p[i] = UInt8(max(0, min(255, (Double(p[i]) - Double(lo)) * sc)))
                }
            }
        }
        return g.makeImage()
    }

    // MARK: drawing

    /// Draws one frame. `width` is the pixel width of the context; height must be width * 16 / 9.
    func draw(_ ctx: CGContext, width: Int, time t: Double, duration: Double) {
        let pw = Double(width), ph = pw * 16.0 / 9.0
        ctx.saveGState()
        ctx.setAlpha(1)
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.translateBy(x: 0, y: CGFloat(ph))        // y-down from here on
        ctx.scaleBy(x: 1, y: -1)
        let sc = CGFloat(pw / kW)
        ctx.scaleBy(x: sc, y: sc)                    // draw in a 720 x 1280 space
        ctx.setShouldAntialias(true)
        let fade = max(0.0, min(1.0, min(t / 0.5, (duration - t) / 0.6)))
        ctx.setAlpha(CGFloat(fade))

        let cx = kW / 2, cy = kH / 2
        let env = analysis.envAt(t)

        if look.dots {
            drawDust(ctx, t)
            drawBursts(ctx, t)
        }

        // --- bars
        let path = CGMutablePath()
        let i1 = upperBound(lobeT, t), i0 = lowerBound(lobeT, t - 0.9)
        let va = voiceAngle(t)
        for i in 0..<nBars {
            let theta = (Double(i) + 0.5) / Double(nBars) * kTwoPi
            let flut = 0.55 + 0.45 * sin(flutW[i] * t + flutP[i])
            let dv = angDiff(theta, va)
            var grow = 0.55 * pow(env, 1.3) * exp(-pow(dv / 0.30, 2)) * flut
            if i0 < i1 {
                for k in i0..<i1 {
                    let lb = lobes[k]
                    let age = t - lb.t0
                    let ke = min(1.0, age / 0.035) * exp(-age / 0.26)
                    let dd = angDiff(theta, lb.theta)
                    let g = lb.h * ke * exp(-pow(dd / lb.sigma, 2)) * (0.35 + 0.65 * flut)
                    grow = max(grow, g)
                }
            }
            let len = barBase + grow * (barMaxPx - barBase) + 1.2 * env * flut
            let a = theta - Double.pi / 2
            let c = cos(a), s = sin(a)
            path.move(to: CGPoint(x: cx + kR0 * c, y: cy + kR0 * s))
            path.addLine(to: CGPoint(x: cx + (kR0 + len) * c, y: cy + (kR0 + len) * s))
        }
        // glow passes (soft, wide) then the crisp bars
        let passes: [(Double, Double, CGLineCap)] = [(barW * 3.2, 0.07, .round), (barW * 1.9, 0.15, .round), (barW, 1.0, .butt)]
        ctx.beginPath()
        for (w, al, cap) in passes {
            ctx.addPath(path)
            ctx.setLineWidth(CGFloat(w))
            ctx.setLineCap(cap)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: CGFloat(al))
            ctx.strokePath()
        }

        // --- thin neon ring + halo behind the picture
        let ringR = kImgR + kRingGap
        for (w, al) in [(14.0, 0.10), (8.0, 0.18), (kRingW, 1.0)] {
            ctx.setLineWidth(CGFloat(w))
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: CGFloat(al))
            ctx.strokeEllipse(in: CGRect(x: cx - ringR, y: cy - ringR, width: ringR * 2, height: ringR * 2))
        }
        for (grow, al) in [(16.0, 0.05), (8.0, 0.07)] {
            let r = kImgR + grow
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: CGFloat(al))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
        }

        // --- the picture, cut to a circle
        let rect = CGRect(x: cx - kImgR, y: cy - kImgR, width: kImgR * 2, height: kImgR * 2)
        ctx.saveGState()
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fillEllipse(in: rect)
        ctx.addEllipse(in: rect)
        ctx.clip()
        if let img = center {
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        }
        ctx.restoreGState()

        ctx.restoreGState()
    }

    private func dot(_ ctx: CGContext, _ x: Double, _ y: Double, _ r: Double, _ a: Double) {
        if a <= 0.01 { return }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: CGFloat(a * 0.20))
        ctx.fillEllipse(in: CGRect(x: x - r * 3, y: y - r * 3, width: r * 6, height: r * 6))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: CGFloat(min(1, a)))
        ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    private func drawDust(_ ctx: CGContext, _ t: Double) {
        for d in dust {
            var x = (d.x + d.vx * t * 1.3).truncatingRemainder(dividingBy: kW)
            var y = (d.y + d.vy * t * 1.3).truncatingRemainder(dividingBy: kH)
            if x < 0 { x += kW }
            if y < 0 { y += kH }
            let tw = 0.55 + 0.45 * sin(d.tw * t + d.tp)
            dot(ctx, x, y, d.r, d.base * tw)
        }
    }

    private func drawBursts(_ ctx: CGContext, _ t: Double) {
        let i0 = lowerBound(burstT, t - 1.9), i1 = upperBound(burstT, t)
        if i0 >= i1 { return }
        let k = 0.453
        for i in i0..<i1 {
            let b = bursts[i]
            let age = t - b.t0
            if age < 0 || age > b.life { continue }
            let f = (1 - exp(-k * age)) / k
            let fade = pow(1 - age / b.life, 0.8)
            dot(ctx, b.x + b.vx * f, b.y + b.vy * f, b.r, fade)
        }
    }

    /// One frame as an image (used by the live preview).
    func image(width: Int, time: Double, duration: Double) -> CGImage? {
        let h = width * 16 / 9
        guard let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        draw(ctx, width: width, time: time, duration: duration)
        return ctx.makeImage()
    }
}
