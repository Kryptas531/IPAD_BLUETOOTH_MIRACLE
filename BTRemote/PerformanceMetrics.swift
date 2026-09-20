import Combine
import Foundation
import QuartzCore

struct PerformanceMetricsSnapshot: Sendable {
    var touchEventsHz = 0.0
    var rawSamplesHz = 0.0
    var generatedReportsHz = 0.0
    var attemptedReportsHz = 0.0
    var acceptedReportsHz = 0.0
    var backpressurePerSecond = 0
    var coalescedMousePerSecond = 0
    var pendingMouseCount = 0
    var lostDelta = 0
    var averageSampleIntervalMs = 0.0
    var maxSampleIntervalMs = 0.0
}

@MainActor
final class PerformanceMetrics: ObservableObject {
    @Published private(set) var snapshot = PerformanceMetricsSnapshot()

    private var touchEvents: [TimeInterval] = []
    private var rawSamples: [TimeInterval] = []
    private var generatedReports: [TimeInterval] = []
    private var attemptedReports: [TimeInterval] = []
    private var acceptedReports: [TimeInterval] = []
    private var backpressure: [TimeInterval] = []
    private var coalescedMouse: [TimeInterval] = []
    private var sampleIntervals: [(interval: TimeInterval, at: TimeInterval)] = []
    private var lastSampleTime: TimeInterval?
    func recordTouchEvent() {
        touchEvents.append(CACurrentMediaTime())
        refresh()
    }

    func recordRawSample(at time: TimeInterval = CACurrentMediaTime()) {
        rawSamples.append(time)
        if let lastSampleTime {
            sampleIntervals.append((interval: max(0, time - lastSampleTime), at: time))
        }
        lastSampleTime = time
        refresh()
    }

    func recordGeneratedReport() {
        generatedReports.append(CACurrentMediaTime())
        refresh()
    }

    func recordAttemptedReport() {
        attemptedReports.append(CACurrentMediaTime())
        refresh()
    }

    func recordAcceptedReport() {
        acceptedReports.append(CACurrentMediaTime())
        refresh()
    }

    func recordBackpressure() {
        backpressure.append(CACurrentMediaTime())
        refresh()
    }

    func recordCoalescedMouse() {
        coalescedMouse.append(CACurrentMediaTime())
        refresh()
    }

    func setPendingMouseCount(_ count: Int) {
        snapshot.pendingMouseCount = count
    }

    func recordLostDelta(_ count: Int32 = 1) {
        snapshot.lostDelta += Int(count)
    }

    private func refresh() {
        let now = CACurrentMediaTime()
        prune(&touchEvents, now: now)
        prune(&rawSamples, now: now)
        prune(&generatedReports, now: now)
        prune(&attemptedReports, now: now)
        prune(&acceptedReports, now: now)
        prune(&backpressure, now: now)
        prune(&coalescedMouse, now: now)
        sampleIntervals.removeAll { now - $0.at > 1 }

        snapshot.touchEventsHz = Double(touchEvents.count)
        snapshot.rawSamplesHz = Double(rawSamples.count)
        snapshot.generatedReportsHz = Double(generatedReports.count)
        snapshot.attemptedReportsHz = Double(attemptedReports.count)
        snapshot.acceptedReportsHz = Double(acceptedReports.count)
        snapshot.backpressurePerSecond = backpressure.count
        snapshot.coalescedMousePerSecond = coalescedMouse.count
        snapshot.averageSampleIntervalMs = sampleIntervals.isEmpty
            ? 0
            : sampleIntervals.reduce(0) { $0 + $1.interval } / Double(sampleIntervals.count) * 1000
        snapshot.maxSampleIntervalMs = sampleIntervals.map { $0.interval }.max().map { $0 * 1000 } ?? 0
    }

    private func prune(_ values: inout [TimeInterval], now: TimeInterval) {
        values.removeAll { now - $0 > 1 }
    }
}
