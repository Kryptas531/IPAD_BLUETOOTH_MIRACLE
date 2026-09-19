#if os(iOS)
    import SwiftUI
    import UIKit

    /// 1-finger drag: moves
    /// 1-finger tap: left-clicks
    /// 2-finger tap: right-clicks
    /// 2-finger drag: scrolls
    struct TouchpadView: UIViewRepresentable {
        var moveSensitivity: CGFloat
        var scrollSensitivity: CGFloat
        var onMove: (Int8, Int8) -> Void
        var onScroll: (Int8) -> Void
        var onLeftClick: () -> Void
        var onRightClick: () -> Void
        var onDragDown: () -> Void = {}
        var onDragMove: (Int8, Int8) -> Void = { _, _ in }
        var onDragUp: () -> Void = {}

        func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            view.isMultipleTouchEnabled = true
            let c = context.coordinator

            let move = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleMove(_:)))
            move.minimumNumberOfTouches = 1
            move.maximumNumberOfTouches = 1
            move.delegate = c

            let scroll = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.handleScroll(_:)))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            scroll.delegate = c

            let left = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleLeft))
            left.numberOfTouchesRequired = 1
            left.delegate = c

            let right = UITapGestureRecognizer(target: c, action: #selector(Coordinator.handleRight))
            right.numberOfTouchesRequired = 2
            right.delegate = c

            // double-tap-hold drag: second touch held → LMB down; move; lift-off → LMB up
            let drag = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.handleDrag(_:)))
            drag.numberOfTouchesRequired = 1
            drag.minimumPressDuration = 0.35
            drag.delegate = c

            let recognizers: [UIGestureRecognizer] = [move, scroll, left, right, drag]
            recognizers.forEach { view.addGestureRecognizer($0) }
            return view
        }

        func updateUIView(_ uiView: UIView, context: Context) {
            let c = context.coordinator
            c.moveSensitivity = moveSensitivity
            c.scrollSensitivity = scrollSensitivity
            c.onMove = onMove
            c.onScroll = onScroll
            c.onLeftClick = onLeftClick
            c.onRightClick = onRightClick
            c.onDragDown = onDragDown
            c.onDragMove = onDragMove
            c.onDragUp = onDragUp
        }

        @MainActor
        final class Coordinator: NSObject, UIGestureRecognizerDelegate {
            var moveSensitivity: CGFloat = 1
            var scrollSensitivity: CGFloat = 1
            var onMove: (Int8, Int8) -> Void = { _, _ in }
            var onScroll: (Int8) -> Void = { _ in }
            var onLeftClick: () -> Void = {}
            var onRightClick: () -> Void = {}
            var onDragDown: () -> Void = {}
            var onDragMove: (Int8, Int8) -> Void = { _, _ in }
            var onDragUp: () -> Void = {}

            private var scrollAccumulator: CGFloat = 0
            private let scrollStep: CGFloat = 6
            private var dragging = false

            @objc func handleMove(_ pan: UIPanGestureRecognizer) {
                guard let view = pan.view else { return }
                let t = pan.translation(in: view)
                // HID MouseReport dX/dY are Int8 (±127): split larger deltas into
                // several consecutive reports so fast swipes don't lose distance.
                var remainingX = t.x * moveSensitivity
                var remainingY = t.y * moveSensitivity
                while abs(remainingX) > 127 || abs(remainingY) > 127 {
                    let chunkX = remainingX > 0 ? min(127, remainingX) : max(-127, remainingX)
                    let chunkY = remainingY > 0 ? min(127, remainingY) : max(-127, remainingY)
                    if dragging {
                        onDragMove(HIDInput.clamp(chunkX), HIDInput.clamp(chunkY))
                    } else {
                        onMove(HIDInput.clamp(chunkX), HIDInput.clamp(chunkY))
                    }
                    remainingX -= chunkX
                    remainingY -= chunkY
                }
                if remainingX != 0 || remainingY != 0 {
                    if dragging {
                        onDragMove(HIDInput.clamp(remainingX), HIDInput.clamp(remainingY))
                    } else {
                        onMove(HIDInput.clamp(remainingX), HIDInput.clamp(remainingY))
                    }
                }
                pan.setTranslation(.zero, in: view)
            }

            @objc func handleDrag(_ sender: UILongPressGestureRecognizer) {
                switch sender.state {
                case .began:
                    Haptics.tap()
                    dragging = true
                    onDragDown()
                case .ended, .cancelled, .failed:
                    guard dragging else { break }
                    dragging = false
                    onDragUp()
                default:
                    break
                }
            }

            @objc func handleScroll(_ pan: UIPanGestureRecognizer) {
                guard let view = pan.view else { return }
                if pan.state == .began { scrollAccumulator = 0 }
                scrollAccumulator += pan.translation(in: view).y
                pan.setTranslation(.zero, in: view)
                let step = scrollStep / max(scrollSensitivity, 0.1)
                while abs(scrollAccumulator) >= step {
                    // drag up: scroll up (positive wheel)
                    onScroll(scrollAccumulator > 0 ? -1 : 1)
                    scrollAccumulator -= scrollAccumulator > 0 ? step : -step
                }
            }

            @objc func handleLeft() {
                onLeftClick()
            }

            @objc func handleRight() {
                onRightClick()
            }

            nonisolated func gestureRecognizer(
                _ gestureRecognizer: UIGestureRecognizer,
                shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
            ) -> Bool {
                true
            }
        }
    }
#endif
