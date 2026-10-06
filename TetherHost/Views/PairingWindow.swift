import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PairingWindow: View {
    @Bindable var store: HostStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 24) {
            if store.pairingSucceeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(TetherType.hero)
                    .foregroundStyle(Color.tether.success)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: store.pairingSucceeded)
                    .padding(.top, 32)
                Text(L10n.pairSuccess)
                    .font(TetherType.title)
            } else if let offer = store.offer {
                qrCard(offer.qr)
                Text(offer.manualCode)
                    .font(TetherType.code)
                    .monospacedDigit()
                countdown(until: offer.expiresAt)
                Text(L10n.pairScan)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text(store.pairingMessage)
                    .font(.headline)
                    .foregroundStyle(Color.tether.accentText)
                Text(store.networkLine)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
                Text(L10n.pairWaiting)
                    .font(.headline)
            }
        }
        .padding(32)
        .frame(width: 420, height: 520)
        .onAppear { store.beginPairing() }
        .onChange(of: store.pairingSucceeded) { _, succeeded in
            guard succeeded else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.2))
                dismiss()
            }
        }
    }

    private func qrCard(_ text: String) -> some View {
        Image(nsImage: qrImage(text))
            .interpolation(.none)
            .resizable()
            .frame(width: 240, height: 240)
            .padding(16)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func countdown(until date: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, date.timeIntervalSince(context.date))
            let fraction = remaining / 120
            VStack(spacing: 8) {
                ZStack {
                    Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(remaining < 20 ? Color.tether.warning : Color.tether.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(TetherMotion.spring(reduceMotion), value: fraction)
                }
                .frame(width: 44, height: 44)
                Text("\(Int(remaining))s")
                    .font(TetherType.meta)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.secondary)
            }
            .onChange(of: remaining == 0) { _, expired in
                if expired { store.beginPairing() }
            }
        }
    }

    private func qrImage(_ text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        let output = filter.outputImage ?? CIImage()
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
