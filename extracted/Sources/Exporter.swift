import AVFoundation
import CoreVideo

enum Exporter {
    static let width = 720
    static let height = 1280
    static let fps = 30

    /// Draws every frame into an H.264 file, then adds the song's sound. Runs off the main thread.
    static func export(renderer: FrameRenderer, audioURL: URL, duration: Double,
                       progress: @escaping (Double) -> Void) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let silent = tmp.appendingPathComponent("silent-\(UUID().uuidString).mp4")
        let final = tmp.appendingPathComponent("Visualizer-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: silent)
        try? FileManager.default.removeItem(at: final)

        // 1) frames -> silent video
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 9_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw AppError.exportFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? AppError.exportFailed }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw AppError.noPixelPool }

        let total = max(1, Int((duration * Double(fps)).rounded(.up)))
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        for f in 0..<total {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            if writer.status == .failed { throw writer.error ?? AppError.exportFailed }
            var pbOpt: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
            guard let pb = pbOpt else { throw AppError.noPixelPool }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb),
               let ctx = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: space, bitmapInfo: info) {
                let t = (Double(f) + 0.5) / Double(fps)
                renderer.draw(ctx, width: width, time: t, duration: duration)
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps)))
            if f % 10 == 0 { progress(0.9 * Double(f) / Double(total)) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? AppError.exportFailed }

        // 2) silent video + the song's sound -> final file
        progress(0.92)
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: silent)
        guard let vTrack = vAsset.tracks(withMediaType: .video).first,
              let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AppError.exportFailed }
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vAsset.duration), of: vTrack, at: .zero)

        let aAsset = AVURLAsset(url: audioURL)
        if let aTrack = aAsset.tracks(withMediaType: .audio).first,
           let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let d = CMTimeMinimum(aAsset.duration, vAsset.duration)
            try ca.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: aTrack, at: .zero)
        }

        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw AppError.exportFailed
        }
        session.outputURL = final
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                if session.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(throwing: session.error ?? AppError.exportFailed)
                }
            }
        }
        try? FileManager.default.removeItem(at: silent)
        progress(1.0)
        return final
    }
}
