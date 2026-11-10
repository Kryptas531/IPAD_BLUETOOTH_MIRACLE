#if os(iOS)
import SwiftUI
import UIKit

/// SPEC §13.2: dedicated handheld deck; all input still uses the existing controller.
struct FlightDeckView: View {
    @ObservedObject var gyro: GyroAimController
    let gameMenu: () -> Void
    let rearm: () -> Void
    let settings: () -> Void

    private let cyan = Color(red: 0.28, green: 0.82, blue: 0.94)

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let compact = geometry.size.height < 540
            let side = min(280.0, max(160.0, geometry.size.width * 0.27))
            let key = compact ? 64.0 : 76.0
            let layout = FlightDeckLayout(width: Double(geometry.size.width), height: Double(geometry.size.height))
            ZStack {
                FlightHorizonView(model: gyro.flightHorizon)
                    .allowsHitTesting(false).accessibilityHidden(true)
                VStack(spacing: compact ? 8 : 16) {
                    if landscape {
                        HStack(spacing: 12) {
                            throttleCluster(compact: compact).frame(width: side)
                            cameraSurface(landscape: true)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            faceCluster(key: key).frame(width: side)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        cameraSurface(landscape: false).frame(maxHeight: .infinity)
                        Spacer(minLength: 0)
                        HStack(spacing: 12) {
                            throttleCluster(compact: true)
                            Spacer(minLength: 0)
                            faceCluster(key: 64)
                        }
                        Spacer(minLength: 0)
                    }
                    footer
                }
                .padding(compact ? 12 : 20)
            }
            .frame(width: geometry.size.width, height: CGFloat(layout.bodyHeight))
            .modifier(FlightBodyViewport(scrolls: layout.bodyHeight > Double(geometry.size.height)))
            .foregroundColor(.white)
            .background(FlightOrientationReader(onChange: gyro.updateFlightOrientation).allowsHitTesting(false))
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            header.padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color(red: 0.035, green: 0.055, blue: 0.08))
                .zIndex(100)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            FlightNavigationButton(title: "GAME MENU", action: gameMenu)
                .frame(width: 100, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text("FLIGHT").font(.system(.headline, design: .rounded)).tracking(3)
                FlightStatusView(sender: gyro.flightSender)
                    .foregroundColor(.white.opacity(0.65)).lineLimit(2)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            FlightNavigationButton(title: "APP SETTINGS", action: settings)
                .frame(width: 104, height: 48)
        }
        .buttonStyle(.plain)
    }

    private func throttleCluster(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 12) {
            HStack(spacing: 12) {
                input("LB", detail: "LEFT", color: cyan, bit: 16)
                input("RB", detail: "RIGHT", color: cyan, bit: 32)
            }.frame(height: 64)
            HStack(spacing: 12) {
                trigger("LT", detail: "BRAKE", trigger: .brake, color: .orange)
                trigger("RT", detail: "THROTTLE", trigger: .gas, color: cyan)
            }.frame(height: compact ? 64 : 104)
            HStack(spacing: 12) {
                input("L3", detail: "STICK CLICK", color: cyan, bit: 256)
                input("R3", detail: "STICK CLICK", color: cyan, bit: 512)
            }.frame(height: 64)
        }
        .frame(maxWidth: 280)
    }

    private func faceCluster(key: Double) -> some View {
        VStack(spacing: 10) {
            input("Y", color: .yellow, bit: 8).frame(width: key, height: key)
            HStack(spacing: max(12, key * 0.55)) {
                input("X", color: .blue, bit: 4).frame(width: key, height: key)
                input("B", color: .red, bit: 2).frame(width: key, height: key)
            }
            input("A", color: .green, bit: 1).frame(width: key, height: key)
        }
    }

    private func cameraSurface(landscape: Bool) -> some View {
        RacingSurfaceView(
            onTouchBegan: { gyro.beginRacingTouch(at: $0) },
            onTouchMoved: { gyro.moveRacingTouch(to: $0) },
            onTouchEnded: { gyro.endRacingTouch() }
        )
        .overlay(cameraGuide(landscape: landscape).allowsHitTesting(false))
        .contentShape(Rectangle())
        .clipped()
    }

    private func cameraGuide(landscape: Bool) -> some View {
        VStack(spacing: 12) {
            Image(systemName: landscape ? "viewfinder" : "ipad.landscape")
                .font(.system(size: 32, weight: .ultraLight))
            Text(landscape ? "DRAG TO LOOK" : "ROTATE iPAD FOR GYRO")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .tracking(1)
            Text(landscape ? "Tilt to fly · release to center camera" : "Buttons work in portrait")
                .font(.caption2).multilineTextAlignment(.center)
            if !gyro.isAvailable {
                Text("Motion unavailable").font(.caption).foregroundColor(.orange)
            }
        }
        .foregroundColor(.white.opacity(0.45))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            input("BACK", color: .gray, bit: 64).frame(width: 64, height: 48)
            Spacer(minLength: 0)
            Button("RECENTER") { gyro.recenter() }
                .font(.system(.caption, design: .rounded).weight(.bold))
                .frame(minWidth: 90, minHeight: 48)
                .background(cyan.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            Button("RE-ARM", action: rearm)
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .frame(minWidth: 72, minHeight: 48)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Reconnect and re-arm receiver")
            Spacer(minLength: 0)
            input("OPTIONS", detail: "START", color: .gray, bit: 128).frame(width: 64, height: 48)
        }
        .buttonStyle(.plain)
    }

    private func plate(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(color.opacity(0.16))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(color.opacity(0.65), lineWidth: 1.5))
    }

    private func legend(_ title: String, detail: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: title.count > 2 ? 13 : 24, weight: .bold, design: .rounded))
                .foregroundColor(color)
            if !detail.isEmpty {
                Text(detail).font(.system(size: 10, weight: .semibold)).tracking(1)
            }
        }.allowsHitTesting(false)
    }

    private func input(_ title: String, detail: String = "", color: Color, bit: UInt16) -> some View {
        HoldButton(
            onPress: { gyro.setFlightButton(bit, pressed: true) },
            onRelease: { gyro.setFlightButton(bit, pressed: false) },
            background: { plate(color) },
            label: { legend(title, detail: detail, color: color) }
        ).accessibilityLabel(title)
    }

    private func trigger(_ title: String, detail: String, trigger: GamepadTrigger, color: Color) -> some View {
        HoldButton(
            onPress: { gyro.setRacingTrigger(trigger, pressed: true) },
            onRelease: { gyro.setRacingTrigger(trigger, pressed: false) },
            background: { plate(color) },
            label: { legend(title, detail: detail, color: color) }
        ).accessibilityLabel("\(title) \(detail)")
    }
}
/// Do not install a scroll recognizer over normal simultaneous gameplay touches.
private struct FlightBodyViewport: ViewModifier {
    let scrolls: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if scrolls {
            ScrollView(.vertical) { content }
        } else {
            content
        }
    }
}

/// A native control owns its touches independently of gameplay SwiftUI gestures.
struct FlightNavigationButton: UIViewRepresentable {
    let title: String
    let action: () -> Void
    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 13)
        button.accessibilityLabel = title == "GAME MENU" ? "GAME modes and navigation" : title
        return button
    }
    func updateUIView(_ button: UIButton, context: Context) {
        button.removeAction(identifiedBy: UIAction.Identifier("navigate"), for: .touchUpInside)
        button.addAction(UIAction(identifier: UIAction.Identifier("navigate")) { _ in action() }, for: .touchUpInside)
    }
}
#endif
