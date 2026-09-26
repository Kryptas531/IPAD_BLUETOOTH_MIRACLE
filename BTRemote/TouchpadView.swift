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
        var mode: PadMode = .trackpad
        var metrics: PerformanceMetrics?
        /// `false` disables touch movement only; single-finger tap-to-LMB still works
        /// (SPEC §5.1 B — used while the GAME input source is Gyro).
        var touchMovementEnabled: Bool = true
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
            if mode == .game {
                return HighFidelityTouchView(
                    metrics: metrics,
                    onMove: onMove,
                    onTap: onLeftClick,
                    moveSensitivity: moveSensitivity,
                    movementEnabled: touchMovementEnabled
                )
            }
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
            if let gameView = uiView as? HighFidelityTouchView {
                gameView.metrics = metrics
                gameView.onMove = onMove
                gameView.onTap = onLeftClick
                gameView.moveSensitivity = moveSensitivity
                gameView.movementEnabled = touchMovementEnabled
                return
            }
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

    @MainActor
    final class HighFidelityTouchView: UIView {
        var metrics: PerformanceMetrics?
        var onMove: (Int8, Int8) -> Void
        var onTap: () -> Void
        var moveSensitivity: CGFloat = 1
        /// `false` while the GAME input source is Gyro: touch movement is not sent,
        /// but tap-to-LMB keeps working (SPEC §5.1 B).
        var movementEnabled: Bool = true

        private var previousLocations: [ObjectIdentifier: CGPoint] = [:]
        private var beganLocations: [ObjectIdentifier: CGPoint] = [:]
        private var movedTouches: Set<ObjectIdentifier> = []

        init(
            metrics: PerformanceMetrics?,
            onMove: @escaping (Int8, Int8) -> Void,
            onTap: @escaping () -> Void,
            moveSensitivity: CGFloat = 1,
            movementEnabled: Bool = true
        ) {
            self.metrics = metrics
            self.onMove = onMove
            self.onTap = onTap
            self.moveSensitivity = moveSensitivity
            self.movementEnabled = movementEnabled
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            metrics?.recordTouchEvent()
            for touch in touches {
                let id = ObjectIdentifier(touch)
                let location = touch.location(in: self)
                previousLocations[id] = location
                beganLocations[id] = location
            }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            metrics?.recordTouchEvent()
            for touch in touches {
                let id = ObjectIdentifier(touch)
                let samples = event?.coalescedTouches(for: touch) ?? [touch]
                for sample in samples {
                    let location = sample.location(in: self)
                    guard let previous = previousLocations[id] else {
                        previousLocations[id] = location
                        continue
                    }
                    metrics?.recordRawSample(at: sample.timestamp)
                    let delta = CGPoint(x: location.x - previous.x, y: location.y - previous.y)
                    send(delta: delta)
                    previousLocations[id] = location
                    if delta != .zero { movedTouches.insert(id) }
                }
            }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            finish(touches)
        }

        private func finish(_ touches: Set<UITouch>) {
            metrics?.recordTouchEvent()
            if touches.count == 1, let touch = touches.first {
                let id = ObjectIdentifier(touch)
                if !movedTouches.contains(id), let start = beganLocations[id],
                   hypot(touch.location(in: self).x - start.x, touch.location(in: self).y - start.y) < 12
                {
                    onTap()
                }
            }
            for touch in touches {
                let id = ObjectIdentifier(touch)
                previousLocations.removeValue(forKey: id)
                beganLocations.removeValue(forKey: id)
                movedTouches.remove(id)
            }
        }

        private func send(delta: CGPoint) {
            guard movementEnabled else { return }
            var x = delta.x * moveSensitivity
            var y = delta.y * moveSensitivity
            while abs(x) > 127 || abs(y) > 127 {
                let dx = x > 0 ? min(127, x) : max(-127, x)
                let dy = y > 0 ? min(127, y) : max(-127, y)
                onMove(HIDInput.clamp(dx), HIDInput.clamp(dy))
                x -= dx
                y -= dy
            }
            if x != 0 || y != 0 {
                onMove(HIDInput.clamp(x), HIDInput.clamp(y))
            }
        }
    }
#endif
