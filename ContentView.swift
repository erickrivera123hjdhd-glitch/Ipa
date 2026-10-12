import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var studio = Studio()
    @State private var showImporter = false
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    header
                    player
                    pickers
                    look
                    export
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 40)
            }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie]) { result in
            switch result {
            case .success(let url): studio.loadSong(from: url)
            case .failure(let e): studio.error = e.localizedDescription
            }
        }
        .onChange(of: pickerItem) { item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    studio.setCover(img)
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { studio.error != nil },
                                                          set: { if !$0 { studio.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(studio.error ?? "")
        }
    }

    // MARK: pieces

    private var header: some View {
        VStack(spacing: 4) {
            Text("VISUALIZER")
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .tracking(6)
                .foregroundColor(.white.opacity(0.9))
            Text(studio.hasSong ? studio.songName : "Pick a song to begin")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
        }
        .padding(.top, 10)
    }

    private var player: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: studio.hasSong && !studio.isPlaying)) { _ in
            let t = studio.currentTime
            VStack(spacing: 14) {
                if let cg = studio.renderer.image(width: 360, time: t, duration: studio.clip) {
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .aspectRatio(9.0 / 16.0, contentMode: .fit)
                        .frame(maxHeight: 520)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1))
                }
                if studio.isAnalyzing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Listening to the song…").font(.footnote).foregroundColor(.white.opacity(0.7))
                    }
                } else {
                    HStack(spacing: 14) {
                        Button { studio.togglePlay() } label: {
                            Image(systemName: studio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 46, height: 46)
                                .background(Circle().fill(Color.white))
                        }
                        .disabled(!studio.hasSong)
                        .opacity(studio.hasSong ? 1 : 0.35)
                        Slider(value: Binding(get: { min(t, studio.clip) }, set: { studio.seek($0) }),
                               in: 0...max(studio.clip, 0.1))
                            .disabled(!studio.hasSong)
                        Text(timeText(t) + " / " + timeText(studio.clip))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
        }
    }

    private var pickers: some View {
        HStack(spacing: 12) {
            Button { showImporter = true } label: {
                chip("Choose song", "music.note")
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                chip("Cover photo", "photo")
            }
        }
    }

    private var look: some View {
        VStack(alignment: .leading, spacing: 14) {
            label("LOOK")
            sliderRow("Line thickness", $studio.thickness)
            sliderRow("Line length", $studio.length)
            Toggle("Floating dots", isOn: $studio.dots)
                .font(.system(size: 14, weight: .medium))
            label("VIDEO LENGTH")
            Picker("Length", selection: $studio.maxSeconds) {
                Text("15s").tag(15)
                Text("30s").tag(30)
                Text("60s").tag(60)
                Text("Full").tag(0)
            }
            .pickerStyle(.segmented)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.07)))
    }

    private var export: some View {
        VStack(spacing: 12) {
            Button { studio.makeVideo() } label: {
                Text(studio.exportProgress == nil ? "Make video" : "Rendering…")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white))
            }
            .disabled(!studio.hasSong || studio.exportProgress != nil)
            .opacity(studio.hasSong ? 1 : 0.35)

            if let p = studio.exportProgress {
                ProgressView(value: p)
                Text("\(Int(p * 100))%").font(.caption).foregroundColor(.white.opacity(0.6))
            }
            if let url = studio.exportedURL {
                HStack(spacing: 12) {
                    Button { studio.saveToPhotos(url) } label: { chip("Save to Photos", "square.and.arrow.down") }
                    ShareLink(item: url) { chip("Share", "square.and.arrow.up") }
                }
                Text("Nothing is posted automatically. You decide where the video goes.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
            }
            if let s = studio.status {
                Text(s).font(.footnote).foregroundColor(.white.opacity(0.7))
            }
        }
    }

    // MARK: helpers

    private func chip(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text).font(.system(size: 14, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.35), lineWidth: 1))
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .tracking(3)
            .foregroundColor(.white.opacity(0.45))
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .medium))
            Slider(value: value, in: 0...1)
        }
    }

    private func timeText(_ s: Double) -> String {
        let i = Int(max(0, s))
        return "\(i / 60):" + String(format: "%02d", i % 60)
    }
}
