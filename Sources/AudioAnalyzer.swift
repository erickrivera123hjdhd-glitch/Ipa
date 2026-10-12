import AVFoundation

enum AppError: LocalizedError {
    case noAudio, exportFailed, noPixelPool
    var errorDescription: String? {
        switch self {
        case .noAudio: return "Couldn't read any audio from that file."
        case .exportFailed: return "The video couldn't be exported."
        case .noPixelPool: return "The video encoder couldn't start."
        }
    }
}

struct Beat {
    var t: Double
    var s: Double   // strength 0...1
}

struct Analysis {
    var hop: Double = 0.01
    var env: [Float] = []
    var beats: [Beat] = []
    var duration: Double = 8

    func envAt(_ t: Double) -> Double {
        guard !env.isEmpty else { return 0 }
        let i = min(env.count - 1, max(0, Int(t / hop)))
        return Double(env[i])
    }

    /// A made-up 124 bpm loop, so the preview moves before any song is chosen.
    static func demo() -> Analysis {
        let dur = 8.0
        let step = 60.0 / 124.0
        var beats: [Beat] = []
        var t = 0.3
        var k = 0
        while t < dur {
            beats.append(Beat(t: t, s: k % 4 == 0 ? 1.0 : (k % 2 == 0 ? 0.8 : 0.6)))
            t += step
            k += 1
        }
        var env = [Float](repeating: 0, count: Int(dur / 0.01))
        for i in 0..<env.count {
            let time = Double(i) * 0.01
            var v = 0.25
            for b in beats where b.t <= time && time - b.t < 0.5 {
                v = max(v, 0.9 * exp(-(time - b.t) * 5) * b.s)
            }
            env[i] = Float(v)
        }
        return Analysis(hop: 0.01, env: env, beats: beats, duration: dur)
    }
}

enum AudioAnalyzer {
    static func analyze(url: URL) async throws -> Analysis {
        try await Task.detached(priority: .userInitiated) {
            try analyzeSync(url: url)
        }.value
    }

    private static func percentile(_ a: [Float], _ p: Double) -> Float {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    private static func analyzeSync(url: URL) throws -> Analysis {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw AppError.noAudio }

        let sr = 22050.0
        let hopN = 220                        // 10 ms
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(out) else { throw AppError.noAudio }
        reader.add(out)
        guard reader.startReading() else { throw reader.error ?? AppError.noAudio }

        var rms: [Float] = []
        var low: [Float] = []
        var accA = 0.0, accL = 0.0
        var n = 0
        var lp: Float = 0
        let alpha: Float = 0.04               // one-pole low-pass, roughly 150 Hz (kick drum)

        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let count = CMBlockBufferGetDataLength(bb) / 4
            if count == 0 { continue }
            var data = [Float](repeating: 0, count: count)
            let status = data.withUnsafeMutableBytes { raw -> OSStatus in
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: count * 4, destination: raw.baseAddress!)
            }
            if status != kCMBlockBufferNoErr { continue }
            for x in data {
                lp += alpha * (x - lp)
                accA += Double(x * x)
                accL += Double(lp * lp)
                n += 1
                if n == hopN {
                    rms.append(Float((accA / Double(hopN)).squareRoot()))
                    low.append(Float((accL / Double(hopN)).squareRoot()))
                    accA = 0; accL = 0; n = 0
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? AppError.noAudio }
        if rms.count < 50 { throw AppError.noAudio }

        let pr = max(percentile(rms, 0.95), 1e-6)
        let pl = max(percentile(low, 0.95), 1e-6)
        let rn = rms.map { min(1, $0 / pr) }
        let ln = low.map { min(1, $0 / pl) }

        // loudness envelope (what the always-on lobe follows)
        var env = [Float](repeating: 0, count: rn.count)
        for i in 0..<rn.count {
            var s: Float = 0, c: Float = 0
            for k in -2...2 {
                let j = i + k
                if j >= 0 && j < rn.count { s += rn[j]; c += 1 }
            }
            env[i] = pow(s / c, 0.8)
        }

        // onset curve: how much louder than the last 120 ms (mix of full band + bass)
        let comb = zip(rn, ln).map { 0.5 * $0 + 0.5 * $1 }
        var flux = [Float](repeating: 0, count: comb.count)
        for i in 0..<comb.count {
            let lo = max(0, i - 12)
            var m: Float = 0
            for j in lo..<i { m += comb[j] }
            m = i > lo ? m / Float(i - lo) : comb[i]
            flux[i] = max(0, comb[i] - m)
        }

        // pick peaks, at most one per 0.2 s
        let pf = max(percentile(flux, 0.95), 1e-6)
        let thr = max(0.35 * pf, 0.03)
        var peaks: [(Int, Float)] = []
        for i in 0..<flux.count {
            let v = flux[i]
            if v < thr { continue }
            let a0 = max(0, i - 6), b0 = min(flux.count - 1, i + 6)
            var isMax = true
            for j in a0...b0 where flux[j] > v { isMax = false; break }
            if !isMax { continue }
            if let last = peaks.last, i - last.0 < 20 {
                if v > last.1 { peaks[peaks.count - 1] = (i, v) }
                continue
            }
            peaks.append((i, v))
        }
        let raw = peaks.map { ($0.0, min(1, $0.1 / pf)) }.filter { $0.1 >= 0.3 }
        let strengths = raw.map { $0.1 }
        let lo = percentile(strengths, 0.08), hi = percentile(strengths, 0.96)
        let beats: [Beat] = raw.map { p in
            let s = hi - lo > 1e-6 ? max(0, min(1, (p.1 - lo) / (hi - lo))) : p.1
            return Beat(t: Double(p.0) * 0.01 + 0.005, s: Double(s))
        }

        var dur = CMTimeGetSeconds(asset.duration)
        if !dur.isFinite || dur <= 0 { dur = Double(rms.count) * 0.01 }
        return Analysis(hop: 0.01, env: env, beats: beats, duration: dur)
    }
}
