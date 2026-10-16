import SwiftUI

@main
struct YapMicApp: App {
    @StateObject private var client = MicClient()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView(client: client)
                // The system Camera can scan the code too: it opens yapmic://pair links here.
                .onOpenURL { url in if let p = MicLink.Pairing(url: url) { client.pair(p) } }
                .onChange(of: phase) { _, p in
                    Platform.keepAwake(p == .active)
                    if p == .active { client.refresh() } else { client.stop(send: false) }
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var client: MicClient
    @State private var scanning = false

    var body: some View {
        Group {
            if let p = client.pairing { TalkView(client: client, macName: p.macName) } else { welcome }
        }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                PairScanner { p in client.pair(p); scanning = false }
                    .navigationTitle("Scan the code on your Mac")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { scanning = false } } }
            }
        }
    }

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "iphone.radiowaves.left.and.right").font(.system(size: 56, weight: .light))
            Text("Yap Mic").font(.largeTitle.bold())
            Text("Use your iPhone as a wireless microphone for Yap. Talk from anywhere in the room and your words paste at the cursor on your Mac.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("On your Mac: Yap Settings → Dictation → Pair iPhone", systemImage: "1.circle")
                Label("Tap Pair below and scan the code", systemImage: "2.circle")
            }
            .font(.callout)
            Spacer()
            Button { scanning = true } label: { Text("Pair").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!Platform.canScan)
            if !Platform.canScan {
                Text("Scan the code with the Camera app instead, then tap the link.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(28)
    }
}

/// Hold the button to talk; a quick tap keeps it listening until you tap again.
struct TalkView: View {
    @ObservedObject var client: MicClient
    let macName: String
    @State private var command = false
    @State private var pressedAt: Date?
    @State private var locked = false
    @State private var confirmUnpair = false

    var body: some View {
        VStack(spacing: 24) {
            header
            Spacer()
            words
            Spacer()
            button
            hint
            Toggle(isOn: $command) { Label("Command Mode", systemImage: "wand.and.stars") }
                .toggleStyle(.button).disabled(client.talking)
        }
        .padding(24)
        .animation(.easeOut(duration: 0.18), value: client.talking)
        .confirmationDialog("Unpair from \(macName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        }
    }

    private var header: some View {
        HStack {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(macName).font(.headline)
                Text(linkText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Reconnect") { client.connect() }
                Button("Unpair", role: .destructive) { confirmUnpair = true }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        }
    }

    private var words: some View {
        VStack(spacing: 8) {
            Text(stateText).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            if let t = client.mac.text, !t.isEmpty {
                Text(t).font(.title3).multilineTextAlignment(.center).lineLimit(8)
                    .foregroundStyle(client.mac.state == .error ? .red : .primary)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private var button: some View {
        let ready = client.link == .connected
        let scale = client.talking ? 1.04 + CGFloat(client.level) * 0.18 : 1
        return ZStack {
            Circle().fill(client.talking ? Color.red : Color.primary).opacity(ready ? 1 : 0.25)
            Image(systemName: locked ? "lock.fill" : (command ? "wand.and.stars" : "mic.fill"))
                .font(.system(size: 54, weight: .medium)).foregroundStyle(.background)
        }
        .frame(width: 210, height: 210)
        .scaleEffect(scale)
        .animation(.easeOut(duration: 0.08), value: client.level)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard ready, pressedAt == nil else { return }
                pressedAt = Date()
                if !client.talking { client.start(command: command) }
            }
            .onEnded { _ in
                defer { pressedAt = nil }
                guard let start = pressedAt else { return }
                let quick = Date().timeIntervalSince(start) < 0.3
                if locked { locked = false; client.stop() }          // tap again to finish
                else if quick, client.talking { locked = true }      // quick tap: hands-free
                else { client.stop() }                               // released after holding: paste
            })
        .accessibilityLabel(client.talking ? "Stop and paste" : "Hold to talk")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var hint: some View {
        if locked {
            HStack {
                Text("Listening. Tap to paste.")
                Button("Cancel", role: .destructive) { locked = false; client.stop(cancel: true) }
            }.font(.footnote)
        } else {
            Text(client.link == .connected ? "Hold to talk · tap for hands-free" : "Open Yap on your Mac, on the same Wi-Fi")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var dotColor: Color {
        switch client.link {
        case .connected: .green
        case .searching: .orange
        case .failed: .red
        case .unpaired: .gray
        }
    }

    private var linkText: String {
        switch client.link {
        case .connected: "Connected"
        case .searching: "Looking for your Mac…"
        case .failed(let e): e
        case .unpaired: "Not paired"
        }
    }

    private var stateText: String {
        switch client.mac.state {
        case .ready: client.link == .connected ? "Ready" : ""
        case .listening: "Listening"
        case .thinking: "Writing…"
        case .done: "Pasted on your Mac"
        case .error: "Something went wrong"
        case .busy: "Yap is busy on your Mac"
        }
    }
}
