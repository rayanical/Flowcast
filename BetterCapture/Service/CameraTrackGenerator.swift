//
//  CameraTrackGenerator.swift
//  BetterCapture
//

import CoreGraphics
import Foundation

/// Generates cinematic camera keyframes from interaction events.
struct CameraTrackGenerator {
    private struct TimedPoint {
        let t: Double
        let point: CGPoint
    }

    private struct ActionCluster {
        let start: Double
        let end: Double
        let bounds: CGRect
        let center: CGPoint
        let targetScale: Double
    }

    private struct TargetState {
        let focusPoint: CGPoint
        let scale: Double
    }

    private final class CameraSimulator {
        private var cx: Double
        private var cy: Double
        private var scale: Double
        private var vx = 0.0
        private var vy = 0.0
        private var vs = 0.0

        init(initial: CameraState) {
            cx = initial.cx
            cy = initial.cy
            scale = initial.scale
        }

        func update(
            dt: Double,
            target: CameraState,
            maxPanVelocity: Double,
            maxScaleVelocity: Double,
            smoothing: Double
        ) -> CameraState {
            let response = min(max(smoothing, 0.08), 0.9)
            let positionStiffness = 24 - response * 14
            let positionDamping = 9 + response * 9
            let scaleStiffness = 20 - response * 12
            let scaleDamping = 8 + response * 8

            let ax = (target.cx - cx) * positionStiffness - vx * positionDamping
            let ay = (target.cy - cy) * positionStiffness - vy * positionDamping

            vx += ax * dt
            vy += ay * dt

            let speed = hypot(vx, vy)
            if speed > maxPanVelocity {
                let factor = maxPanVelocity / speed
                vx *= factor
                vy *= factor
            }

            cx += vx * dt
            cy += vy * dt

            let ascale = (target.scale - scale) * scaleStiffness - vs * scaleDamping
            vs += ascale * dt
            vs = min(max(vs, -maxScaleVelocity), maxScaleVelocity)
            scale += vs * dt
            scale = max(1, scale)

            return CameraState(scale: scale, cx: cx, cy: cy)
        }

        var currentState: CameraState {
            CameraState(scale: scale, cx: cx, cy: cy)
        }
    }

    func generate(from eventLog: InteractionEventLog, duration: Double, configuration: StudioRenderConfiguration) -> CameraTrack {
        let width = Double(eventLog.captureWidth)
        let height = Double(eventLog.captureHeight)
        let safeDuration = max(0, duration)
        let defaultCenter = CGPoint(x: width / 2, y: height / 2)

        var keyframes: [CameraKeyframe] = [
            CameraKeyframe(t: 0, scale: 1, cx: defaultCenter.x, cy: defaultCenter.y)
        ]

        guard configuration.autoZoomEnabled else {
            keyframes.append(CameraKeyframe(t: safeDuration, scale: 1, cx: defaultCenter.x, cy: defaultCenter.y))
            return CameraTrack(sourceWidth: eventLog.captureWidth, sourceHeight: eventLog.captureHeight, keyframes: deduplicated(keyframes))
        }

        let cursorSamples = eventLog.events
            .filter { $0.type == .cursor }
            .compactMap { event -> TimedPoint? in
                guard let point = coordinatePoint(for: event) else {
                    return nil
                }
                return TimedPoint(t: event.t, point: point)
            }
            .sorted { $0.t < $1.t }

        let downsampledCursor = downsampledSamples(from: cursorSamples, minimumDistance: 6)
        let smoothedCursor = smoothedSamples(from: downsampledCursor, smoothing: configuration.smoothing)
        let clusters = buildActionClusters(
            from: eventLog.events,
            cursorSamples: smoothedCursor,
            width: width,
            height: height,
            maxScale: configuration.maxScale
        )

        let sampleInterval = 1.0 / 60.0
        let anticipationLead = 0.8
        let idleHold = 1.5

        let simulator = CameraSimulator(
            initial: CameraState(
                scale: 1,
                cx: defaultCenter.x,
                cy: defaultCenter.y
            )
        )

        var idealCenter = defaultCenter
        var time = 0.0

        while time <= safeDuration {
            let target = targetState(
                at: time,
                clusters: clusters,
                cursorSamples: smoothedCursor,
                defaultCenter: defaultCenter,
                followCursor: configuration.followCursor,
                anticipationLead: anticipationLead,
                idleHold: idleHold
            )

            idealCenter = softDeadZoneAdjustedCenter(
                currentCenter: idealCenter,
                focusPoint: target.focusPoint,
                scale: target.scale,
                width: width,
                height: height
            )

            let clampedIdealCenter = clampedCenter(
                for: idealCenter,
                scale: target.scale,
                width: width,
                height: height
            )

            let simulated = simulator.update(
                dt: sampleInterval,
                target: CameraState(
                    scale: target.scale,
                    cx: clampedIdealCenter.x,
                    cy: clampedIdealCenter.y
                ),
                maxPanVelocity: width * 0.9,
                maxScaleVelocity: 1.6,
                smoothing: configuration.smoothing
            )

            let clampedActualCenter = clampedCenter(
                for: CGPoint(x: simulated.cx, y: simulated.cy),
                scale: simulated.scale,
                width: width,
                height: height
            )

            appendKeyframeIfNeeded(
                CameraKeyframe(
                    t: time,
                    scale: simulated.scale,
                    cx: clampedActualCenter.x,
                    cy: clampedActualCenter.y
                ),
                to: &keyframes
            )

            time += sampleInterval
        }

        if (keyframes.last?.t ?? 0) < safeDuration {
            let final = simulator.currentState
            let clampedFinalCenter = clampedCenter(
                for: CGPoint(x: final.cx, y: final.cy),
                scale: final.scale,
                width: width,
                height: height
            )
            keyframes.append(
                CameraKeyframe(
                    t: safeDuration,
                    scale: final.scale,
                    cx: clampedFinalCenter.x,
                    cy: clampedFinalCenter.y
                )
            )
        }

        let clamped = deduplicated(keyframes).map { keyframe in
            let clampedCenter = clampedCenter(
                for: CGPoint(x: keyframe.cx, y: keyframe.cy),
                scale: keyframe.scale,
                width: width,
                height: height
            )

            return CameraKeyframe(
                t: keyframe.t,
                scale: min(max(keyframe.scale, 1), max(configuration.maxScale, 1)),
                cx: clampedCenter.x,
                cy: clampedCenter.y
            )
        }

        return CameraTrack(sourceWidth: eventLog.captureWidth, sourceHeight: eventLog.captureHeight, keyframes: clamped)
    }

    private func buildActionClusters(
        from events: [InteractionEvent],
        cursorSamples: [TimedPoint],
        width: Double,
        height: Double,
        maxScale: Double
    ) -> [ActionCluster] {
        let actionPoints = events
            .filter { $0.type == .click || $0.type == .scroll }
            .compactMap { event -> TimedPoint? in
                guard let point = coordinatePoint(for: event) else {
                    return nil
                }
                return TimedPoint(t: event.t, point: point)
            }
            .sorted { $0.t < $1.t }

        guard let first = actionPoints.first else {
            return []
        }

        var grouped: [[TimedPoint]] = [[first]]

        for point in actionPoints.dropFirst() {
            guard var current = grouped.popLast(), let previous = current.last else {
                grouped.append([point])
                continue
            }

            let dt = point.t - previous.t
            let distance = hypot(point.point.x - previous.point.x, point.point.y - previous.point.y)

            if dt <= 2.0 && distance <= 240 {
                current.append(point)
                grouped.append(current)
            } else {
                grouped.append(current)
                grouped.append([point])
            }
        }

        var clusters: [ActionCluster] = []
        for group in grouped {
            guard let firstPoint = group.first, let lastPoint = group.last else {
                continue
            }

            let cursorContext = cursorSamples.filter {
                $0.t >= firstPoint.t - 0.45 && $0.t <= lastPoint.t + 0.45
            }

            let allPoints = group.map(\.point) + cursorContext.map(\.point)
            let bounds = boundingRect(for: allPoints) ?? CGRect(x: firstPoint.point.x, y: firstPoint.point.y, width: 1, height: 1)

            let widthFraction = bounds.width / width
            let heightFraction = bounds.height / height
            let isWideShot = widthFraction >= 0.72 || heightFraction >= 0.72

            let paddingX = width * 0.12
            let paddingY = height * 0.12
            let computedScale: Double

            if isWideShot {
                computedScale = 1
            } else {
                let scaleX = width / max(bounds.width + paddingX, 1)
                let scaleY = height / max(bounds.height + paddingY, 1)
                computedScale = min(max(maxScale, 1), max(1, min(scaleX, scaleY)))
            }

            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let clamped = clampedCenter(for: center, scale: computedScale, width: width, height: height)

            clusters.append(
                ActionCluster(
                    start: firstPoint.t,
                    end: lastPoint.t,
                    bounds: bounds,
                    center: clamped,
                    targetScale: computedScale
                )
            )
        }

        return clusters
    }

    private func boundingRect(for points: [CGPoint]) -> CGRect? {
        guard let first = points.first else {
            return nil
        }

        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y

        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        let width = max(1, maxX - minX)
        let height = max(1, maxY - minY)
        return CGRect(x: minX, y: minY, width: width, height: height)
    }

    private func targetState(
        at time: Double,
        clusters: [ActionCluster],
        cursorSamples: [TimedPoint],
        defaultCenter: CGPoint,
        followCursor: Bool,
        anticipationLead: Double,
        idleHold: Double
    ) -> TargetState {
        if let active = clusters.first(where: { time >= $0.start && time <= $0.end + idleHold }) {
            return TargetState(focusPoint: active.center, scale: active.targetScale)
        }

        if let upcoming = clusters.first(where: { time < $0.start && ($0.start - time) <= anticipationLead }) {
            return TargetState(focusPoint: upcoming.center, scale: upcoming.targetScale)
        }

        if followCursor, let cursorPoint = point(at: time, in: cursorSamples) {
            return TargetState(focusPoint: cursorPoint, scale: 1)
        }

        return TargetState(focusPoint: defaultCenter, scale: 1)
    }

    private func softDeadZoneAdjustedCenter(
        currentCenter: CGPoint,
        focusPoint: CGPoint,
        scale: Double,
        width: Double,
        height: Double
    ) -> CGPoint {
        let safeScale = max(1, scale)
        let viewportWidth = width / safeScale
        let viewportHeight = height / safeScale
        let deadZoneWidth = viewportWidth * 0.5
        let deadZoneHeight = viewportHeight * 0.5

        let deadZone = CGRect(
            x: currentCenter.x - deadZoneWidth / 2,
            y: currentCenter.y - deadZoneHeight / 2,
            width: deadZoneWidth,
            height: deadZoneHeight
        )

        var adjusted = currentCenter

        if focusPoint.x < deadZone.minX {
            adjusted.x -= (deadZone.minX - focusPoint.x)
        } else if focusPoint.x > deadZone.maxX {
            adjusted.x += (focusPoint.x - deadZone.maxX)
        }

        if focusPoint.y < deadZone.minY {
            adjusted.y -= (deadZone.minY - focusPoint.y)
        } else if focusPoint.y > deadZone.maxY {
            adjusted.y += (focusPoint.y - deadZone.maxY)
        }

        return adjusted
    }

    private func coordinatePoint(for event: InteractionEvent) -> CGPoint? {
        let x = event.captureX ?? event.globalX
        let y = event.captureY ?? event.globalY
        guard x.isFinite, y.isFinite else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func downsampledSamples(from samples: [TimedPoint], minimumDistance: Double) -> [TimedPoint] {
        guard samples.count > 2 else {
            return samples
        }

        var output: [TimedPoint] = [samples[0]]
        var lastKept = samples[0]
        output.reserveCapacity(samples.count / 2)

        for index in 1..<samples.count {
            let sample = samples[index]
            let isLast = index == samples.count - 1
            let distance = hypot(
                sample.point.x - lastKept.point.x,
                sample.point.y - lastKept.point.y
            )

            if isLast || distance >= minimumDistance {
                output.append(sample)
                lastKept = sample
            }
        }

        return output
    }

    private func smoothedSamples(from samples: [TimedPoint], smoothing: Double) -> [TimedPoint] {
        guard let first = samples.first else {
            return []
        }

        var output: [TimedPoint] = [first]
        let alpha = min(max(0.08, smoothing), 0.9)

        var smoothedX = first.point.x
        var smoothedY = first.point.y

        for sample in samples.dropFirst() {
            smoothedX += (sample.point.x - smoothedX) * alpha
            smoothedY += (sample.point.y - smoothedY) * alpha
            output.append(TimedPoint(t: sample.t, point: CGPoint(x: smoothedX, y: smoothedY)))
        }

        return output
    }

    private func point(at time: Double, in samples: [TimedPoint]) -> CGPoint? {
        guard !samples.isEmpty else {
            return nil
        }

        if time <= samples[0].t {
            return samples[0].point
        }

        if time >= samples[samples.count - 1].t {
            return samples[samples.count - 1].point
        }

        var low = 0
        var high = samples.count - 1

        while low <= high {
            let mid = (low + high) / 2
            let midTime = samples[mid].t

            if midTime < time {
                low = mid + 1
            } else if midTime > time {
                high = mid - 1
            } else {
                return samples[mid].point
            }
        }

        let upperIndex = min(max(low, 1), samples.count - 1)
        let lowerIndex = upperIndex - 1
        let start = samples[lowerIndex]
        let end = samples[upperIndex]
        let span = max(0.000_001, end.t - start.t)
        let progress = (time - start.t) / span

        return CGPoint(
            x: start.point.x + (end.point.x - start.point.x) * progress,
            y: start.point.y + (end.point.y - start.point.y) * progress
        )
    }

    private func clampedCenter(for point: CGPoint, scale: Double, width: Double, height: Double) -> CGPoint {
        let safeScale = max(1, scale)
        let visibleWidth = width / safeScale
        let visibleHeight = height / safeScale

        let minX = visibleWidth / 2
        let maxX = width - (visibleWidth / 2)
        let minY = visibleHeight / 2
        let maxY = height - (visibleHeight / 2)

        return CGPoint(
            x: min(max(point.x, minX), maxX),
            y: min(max(point.y, minY), maxY)
        )
    }

    private func deduplicated(_ keyframes: [CameraKeyframe]) -> [CameraKeyframe] {
        let sorted = keyframes
            .enumerated()
            .sorted { lhs, rhs in
                if abs(lhs.element.t - rhs.element.t) < 0.000_5 {
                    return lhs.offset < rhs.offset
                }
                return lhs.element.t < rhs.element.t
            }
            .map(\.element)

        var output: [CameraKeyframe] = []
        output.reserveCapacity(sorted.count)

        for keyframe in sorted {
            if let last = output.last, abs(last.t - keyframe.t) < 0.000_5 {
                output[output.count - 1] = keyframe
            } else {
                output.append(keyframe)
            }
        }

        return output
    }

    private func appendKeyframeIfNeeded(_ keyframe: CameraKeyframe, to keyframes: inout [CameraKeyframe]) {
        guard let last = keyframes.last else {
            keyframes.append(keyframe)
            return
        }

        let positionEpsilon = 0.35
        let scaleEpsilon = 0.001

        let isUnchanged =
            abs(last.cx - keyframe.cx) <= positionEpsilon &&
            abs(last.cy - keyframe.cy) <= positionEpsilon &&
            abs(last.scale - keyframe.scale) <= scaleEpsilon

        if !isUnchanged {
            keyframes.append(keyframe)
        }
    }
}
