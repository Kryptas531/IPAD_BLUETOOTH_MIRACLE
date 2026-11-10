#if os(iOS)
import SwiftUI

/// Only this small subtree observes attitude; controls do not redraw at sensor cadence.
@MainActor
final class FlightHorizonModel: ObservableObject {
    @Published private(set) var sample: FlightHorizonSample?
    private var cadence = FlightHorizonCadence()
    func update(roll: Double, pitch: Double) {
        guard cadence.accepts(now: ProcessInfo.processInfo.systemUptime) else { return }
        sample = FlightHorizonSample.make(roll: roll, pitch: pitch)
    }
    func clear() {
        if sample != nil { sample = nil }
        cadence = FlightHorizonCadence()
    }
}

struct FlightHorizonView: View {
    @ObservedObject var model: FlightHorizonModel

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let unit = min(size.width, size.height) / 100
            let live = model.sample != nil
            let ink = Color(red: 0.38, green: 0.83, blue: 0.73).opacity(live ? 0.55 : 0.16)
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(Color(red: 0.025, green: 0.04, blue: 0.055)))
            var moving = context
            moving.translateBy(x: center.x, y: center.y)
            // Positive control roll tilts the world oppositely; positive pitch
            // moves its horizon down. Angles are device-relative, not game telemetry.
            moving.rotate(by: .degrees(-(model.sample?.roll ?? 0)))
            moving.translateBy(x: 0, y: (model.sample?.pitch ?? 0) * unit * 0.7)
            let extent = max(size.width, size.height) * 3
            moving.fill(Path(CGRect(x: -extent, y: -extent, width: extent * 2, height: extent)),
                        with: .color(Color(red: 0.045, green: 0.10, blue: 0.14).opacity(live ? 1 : 0.3)))
            moving.fill(Path(CGRect(x: -extent, y: 0, width: extent * 2, height: extent)),
                        with: .color(Color(red: 0.10, green: 0.075, blue: 0.045).opacity(live ? 0.65 : 0.2)))
            var ladder = Path()
            ladder.move(to: CGPoint(x: -extent, y: 0))
            ladder.addLine(to: CGPoint(x: extent, y: 0))
            moving.stroke(ladder, with: .color(ink), lineWidth: 1.5)
            for degrees in stride(from: -60, through: 60, by: 10) where degrees != 0 {
                let y = -Double(degrees) * unit * 0.7
                let width = degrees % 20 == 0 ? 18 * unit : 11 * unit
                var rung = Path()
                rung.move(to: CGPoint(x: -width, y: y))
                rung.addLine(to: CGPoint(x: -4 * unit, y: y))
                rung.move(to: CGPoint(x: 4 * unit, y: y))
                rung.addLine(to: CGPoint(x: width, y: y))
                moving.stroke(rung, with: .color(ink), lineWidth: 1)
                moving.draw(Text("\(abs(degrees))").font(.system(size: 10, design: .monospaced)).foregroundColor(ink),
                            at: CGPoint(x: width + 4 * unit, y: y))
            }
            let radius = min(size.width, size.height) * 0.37
            var bank = Path()
            for degrees in [-60.0, -45, -30, -20, -10, 0, 10, 20, 30, 45, 60] {
                let angle = degrees * .pi / 180
                bank.move(to: CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius))
                bank.addLine(to: CGPoint(x: center.x + sin(angle) * (radius - 2 * unit),
                                        y: center.y - cos(angle) * (radius - 2 * unit)))
            }
            context.stroke(bank, with: .color(ink), lineWidth: 1)
            let roll = -(model.sample?.roll ?? 0) * .pi / 180
            let pointer = CGPoint(x: center.x + sin(roll) * (radius - 4 * unit),
                                  y: center.y - cos(roll) * (radius - 4 * unit))
            var marker = Path()
            marker.move(to: pointer)
            marker.addLine(to: CGPoint(x: pointer.x - unit, y: pointer.y + 2 * unit))
            marker.addLine(to: CGPoint(x: pointer.x + unit, y: pointer.y + 2 * unit))
            marker.closeSubpath()
            context.fill(marker, with: .color(ink))
            var aircraft = Path()
            aircraft.move(to: CGPoint(x: center.x - 15 * unit, y: center.y))
            aircraft.addLine(to: CGPoint(x: center.x - 4 * unit, y: center.y))
            aircraft.addLine(to: CGPoint(x: center.x, y: center.y + 2 * unit))
            aircraft.addLine(to: CGPoint(x: center.x + 4 * unit, y: center.y))
            aircraft.addLine(to: CGPoint(x: center.x + 15 * unit, y: center.y))
            context.stroke(aircraft, with: .color(.orange.opacity(live ? 0.8 : 0.25)), lineWidth: 2)
            context.draw(Text(live ? "DEVICE ATTITUDE · RECENTERED" : "DEVICE ATTITUDE · NO LIVE REFERENCE")
                .font(.system(size: 10, design: .monospaced)).foregroundColor(ink),
                         at: CGPoint(x: center.x, y: size.height - 12))
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
