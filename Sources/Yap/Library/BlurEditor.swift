import AVFoundation
import SwiftUI

/// Draw boxes over a frame to hide them: for the whole video or just a stretch of it.
struct BlurEditor: View {
    let url: URL
    let at: Double
    let done: ([BlurRegion]?) -> Void

    @Local private var frame: CGImage?
    @Local private var time = 0.0
    @Local private var duration = 1.0
    @Local private var regions: [BlurRegion] = []
    @Local private var draft: CGRect?
    @Local private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blur areas").font(.title3.weight(.semibold))
            Text("Drag on the frame to cover something. Each box can hide it for the whole video or part of it.")
                .font(.callout).foregroundStyle(.secondary)
            canvas
            HStack {
                Text(Polisher.stamp(time)).monospacedDigit().font(.caption)
                Slider(value: $time, in: 0...max(duration, 0.1)) { Text("Frame") }
                    .labelsHidden()
                    .onChange(of: time) { _, t in Task { await load(t) } }
                Text(Polisher.stamp(duration)).monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            if !regions.isEmpty { list }
            HStack {
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Blurred Copy") { done(regions) }
                    .keyboardShortcut(.defaultAction).disabled(regions.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 720)
        .task {
            duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 1
            time = min(at, duration)
            await load(time)
        }
    }

    private var canvas: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(decorative: frame, scale: 1).resizable().frame(width: size.width, height: size.height)
                } else {
                    Rectangle().fill(.quaternary).frame(width: size.width, height: size.height)
                }
                ForEach(regions) { r in box(r.rect, in: size, active: r.id == selected, visible: time >= r.start && time <= r.end, pixelate: r.pixelate) }
                if let draft { box(draft, in: size, active: true, visible: true, pixelate: false) }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                draft = normalized(from: g.startLocation, to: g.location, in: size)
            }.onEnded { g in
                defer { draft = nil }
                let r = normalized(from: g.startLocation, to: g.location, in: size)
                guard r.width > 0.01, r.height > 0.01 else { return }
                let region = BlurRegion(rect: r)
                regions.append(region)
                selected = region.id
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: 360)
    }

    private func box(_ r: CGRect, in size: CGSize, active: Bool, visible: Bool, pixelate: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(.ultraThinMaterial.opacity(visible ? 1 : 0.25))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(active ? Color.accentColor : .white.opacity(0.8), style: StrokeStyle(lineWidth: active ? 2 : 1, dash: visible ? [] : [4, 3])))
            .overlay(Image(systemName: pixelate ? "square.grid.3x3.fill" : "eye.slash").font(.caption).foregroundStyle(.secondary).opacity(r.width * size.width > 40 ? 1 : 0))
            .frame(width: r.width * size.width, height: r.height * size.height)
            .offset(x: r.minX * size.width, y: r.minY * size.height)
            .allowsHitTesting(false)
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach($regions) { $r in
                    HStack(spacing: 10) {
                        Button { selected = r.id } label: {
                            Image(systemName: r.id == selected ? "largecircle.fill.circle" : "circle")
                        }.buttonStyle(.borderless)
                        Picker("Style", selection: $r.pixelate) {
                            Text("Blur").tag(false); Text("Pixelate").tag(true)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 150)
                        Toggle("Whole video", isOn: Binding(get: { r.start == 0 && r.end == .infinity }, set: { whole in
                            if whole { r.start = 0; r.end = .infinity } else { r.start = time; r.end = duration }
                        }))
                        if !(r.start == 0 && r.end == .infinity) {
                            Button("From \(Polisher.stamp(r.start))") { r.start = min(time, r.end) }.help("Start at the current frame")
                            Button("To \(Polisher.stamp(min(r.end, duration)))") { r.end = max(time, r.start) }.help("End at the current frame")
                        }
                        Spacer()
                        Button(role: .destructive) { regions.removeAll { $0.id == r.id } } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxHeight: 120)
    }

    private func fitted(in box: CGSize) -> CGSize {
        let w = CGFloat(frame?.width ?? 16), h = CGFloat(frame?.height ?? 10)
        let k = min(box.width / w, box.height / h)
        return CGSize(width: w * k, height: h * k)
    }

    private func normalized(from a: CGPoint, to b: CGPoint, in size: CGSize) -> CGRect {
        let x0 = max(0, min(a.x, b.x) / size.width), y0 = max(0, min(a.y, b.y) / size.height)
        let x1 = min(1, max(a.x, b.x) / size.width), y1 = min(1, max(a.y, b.y) / size.height)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private func load(_ t: Double) async {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1440, height: 900)
        gen.requestedTimeToleranceBefore = .init(seconds: 0.1, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = .init(seconds: 0.1, preferredTimescale: 600)
        if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { frame = img }
    }
}
