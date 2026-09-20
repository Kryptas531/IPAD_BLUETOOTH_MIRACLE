import SwiftUI

struct TrackpadPanel: View {
    let hid: HIDInput
    var mode: PadMode = .trackpad
    var metrics: PerformanceMetrics?

    @AppStorage(AppSettings.touchpadSensitivityKey) private var touchpadSensitivity = AppSettings.defaultPointerSensitivity
    @AppStorage(AppSettings.scrollSensitivityKey) private var scrollSensitivity = AppSettings.defaultScrollSensitivity
    @AppStorage(AppSettings.developerModeKey) private var developerMode = false
    #if os(macOS)
        @State private var dragOffset: CGSize = .zero
    #endif

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if mode == .deck {
                DeckPanel(hid: hid)
            } else {
                surface
            }
            if mode == .game, developerMode, let metrics {
                PerformanceOverlay(metrics: metrics)
                    .padding(12)
            }
        }
    }

    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(groupFill)
            #if os(iOS)
                if mode == .touch {
                    VStack(spacing: 8) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text(L10n.Input.inDevelopment)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    TouchpadView(
                        moveSensitivity: touchpadSensitivity,
                        scrollSensitivity: scrollSensitivity,
                        mode: mode,
                        metrics: metrics,
                        onMove: { hid.move(dx: $0, dy: $1) },
                        onScroll: { hid.scroll($0) },
                        onLeftClick: { Haptics.tap(); hid.click(.left) },
                        onRightClick: { Haptics.tap(); hid.click(.right) },
                        onDragDown: { Haptics.tap(); hid.sendMouse(MouseReport(buttons: .left)) },
                        onDragMove: { hid.sendMouse(MouseReport(buttons: .left, dX: $0, dY: $1)) },
                        onDragUp: { hid.sendMouse(.zero) }
                    )
                    .id(mode)
                }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let dx = HIDInput.clamp((value.translation.width - dragOffset.width) * touchpadSensitivity)
                        let dy = HIDInput.clamp((value.translation.height - dragOffset.height) * touchpadSensitivity)
                        dragOffset = value.translation
                        hid.move(dx: dx, dy: dy)
                    }
                    .onEnded { _ in
                        dragOffset = .zero
                        hid.sendMouse(.zero)
                    }
            )
        #endif
    }

}

private struct PerformanceOverlay: View {
    @ObservedObject var metrics: PerformanceMetrics

    var body: some View {
        let value = metrics.snapshot
        VStack(alignment: .leading, spacing: 2) {
            Text("Touch event: \(Int(value.touchEventsHz)) Hz")
            Text("Raw samples: \(Int(value.rawSamplesHz)) Hz")
            Text("Mouse generated: \(Int(value.generatedReportsHz)) Hz")
            Text("BLE accepted: \(Int(value.acceptedReportsHz)) Hz")
            Text("Backpressure: \(value.backpressurePerSecond)/s")
            Text("Coalesced: \(value.coalescedMousePerSecond)/s")
            Text("Pending: \(value.pendingMouseCount)")
            Text("Lost delta: \(value.lostDelta)")
            Text(String(format: "Avg interval: %.1f ms", value.averageSampleIntervalMs))
            Text(String(format: "Max interval: %.1f ms", value.maxSampleIntervalMs))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
