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

    private struct ClickChapter {
        var events: [TimedPoint]
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
                guard let x = event.captureX, let y = event.captureY else {
                    return nil
                }
                return TimedPoint(t: event.t, point: CGPoint(x: x, y: y))
            }
            .sorted { $0.t < $1.t }

        let smoothedCursor = smoothedSamples(from: cursorSamples, smoothing: configuration.smoothing)

        if configuration.followCursor {
            let followInterval = 0.35
            var time = 0.0
            while time <= safeDuration {
                if let point = point(at: time, in: smoothedCursor) {
                    let clamped = clampedCenter(for: point, scale: 1, width: width, height: height)
                    keyframes.append(CameraKeyframe(t: time, scale: 1, cx: clamped.x, cy: clamped.y))
                }
                time += followInterval
            }
        }

        let clickEvents = eventLog.events
            .filter { $0.type == .click }
            .compactMap { event -> TimedPoint? in
                let resolved = clickCapturePoint(event) ?? point(at: event.t, in: smoothedCursor) ?? defaultCenter
                return TimedPoint(t: event.t, point: resolved)
            }
            .sorted { $0.t < $1.t }

        let clickChapters = clusteredClickChapters(
            from: clickEvents,
            timeThreshold: 2.0,
            distanceThreshold: 200
        )

        let cursorScaleBoost = configuration.cursorScaleEnabled ? 0.15 : 0
        let targetScale = min(max(configuration.maxScale, 1), 1 + configuration.clickEmphasis * 1.4 + cursorScaleBoost)
        let anticipationLead = max(0.45, 0.8 - configuration.clickEmphasis * 0.2)
        let moveLead = max(0.25, anticipationLead * 0.6)
        let idleBeforeZoomOut = 1.5
        let zoomOutDuration = 0.35

        for chapter in clickChapters {
            guard let first = chapter.events.first, let last = chapter.events.last else {
                continue
            }

            var currentCenter = clampedCenter(for: first.point, scale: targetScale, width: width, height: height)
            let chapterZoomStart = max(0, first.t - anticipationLead)

            keyframes.append(
                CameraKeyframe(t: chapterZoomStart, scale: 1, cx: currentCenter.x, cy: currentCenter.y)
            )
            keyframes.append(
                CameraKeyframe(t: first.t, scale: targetScale, cx: currentCenter.x, cy: currentCenter.y)
            )

            for event in chapter.events.dropFirst() {
                let moveStart = max(chapterZoomStart, event.t - moveLead)
                currentCenter = softBoundedCenter(
                    for: event.point,
                    currentCenter: currentCenter,
                    scale: targetScale,
                    width: width,
                    height: height
                )
                keyframes.append(
                    CameraKeyframe(t: moveStart, scale: targetScale, cx: currentCenter.x, cy: currentCenter.y)
                )
                keyframes.append(
                    CameraKeyframe(t: event.t, scale: targetScale, cx: currentCenter.x, cy: currentCenter.y)
                )
            }

            let zoomOutStart = min(safeDuration, last.t + idleBeforeZoomOut)
            let zoomOutEnd = min(safeDuration, zoomOutStart + zoomOutDuration)
            keyframes.append(
                CameraKeyframe(t: zoomOutStart, scale: targetScale, cx: currentCenter.x, cy: currentCenter.y)
            )
            keyframes.append(
                CameraKeyframe(t: zoomOutEnd, scale: 1, cx: currentCenter.x, cy: currentCenter.y)
            )
        }

        let scrollEvents = eventLog.events
            .filter { $0.type == .scroll }
            .sorted { $0.t < $1.t }

        for scroll in scrollEvents {
            guard let dy = scroll.dy, abs(dy) > 0 else {
                continue
            }

            let point = clickCapturePoint(scroll) ?? point(at: scroll.t, in: smoothedCursor) ?? defaultCenter
            let center = clampedCenter(
                for: point,
                scale: 1,
                width: width,
                height: height
            )

            let impulse = min(max(configuration.maxScale, 1), 1 + min(abs(dy) / 220, 1) * 0.35)
            let start = max(0, scroll.t)
            let peak = min(safeDuration, start + 0.10)
            let end = min(safeDuration, peak + 0.18)

            keyframes.append(CameraKeyframe(t: start, scale: 1, cx: center.x, cy: center.y))
            keyframes.append(CameraKeyframe(t: peak, scale: impulse, cx: center.x, cy: center.y))
            keyframes.append(CameraKeyframe(t: end, scale: 1, cx: center.x, cy: center.y))
        }

        keyframes.append(CameraKeyframe(t: safeDuration, scale: 1, cx: defaultCenter.x, cy: defaultCenter.y))

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

    private func clickCapturePoint(_ event: InteractionEvent) -> CGPoint? {
        guard let x = event.captureX, let y = event.captureY else {
            return nil
        }

        return CGPoint(x: x, y: y)
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

        for index in 0..<(samples.count - 1) {
            let start = samples[index]
            let end = samples[index + 1]

            if time >= start.t && time <= end.t {
                let span = max(0.000_001, end.t - start.t)
                let progress = (time - start.t) / span
                return CGPoint(
                    x: start.point.x + (end.point.x - start.point.x) * progress,
                    y: start.point.y + (end.point.y - start.point.y) * progress
                )
            }
        }

        return nil
    }

    private func clusteredClickChapters(
        from clicks: [TimedPoint],
        timeThreshold: Double,
        distanceThreshold: Double
    ) -> [ClickChapter] {
        guard let first = clicks.first else {
            return []
        }

        var chapters: [ClickChapter] = [ClickChapter(events: [first])]

        for click in clicks.dropFirst() {
            guard var current = chapters.popLast(), let last = current.events.last else {
                chapters.append(ClickChapter(events: [click]))
                continue
            }

            let timeDelta = click.t - last.t
            let distance = hypot(click.point.x - last.point.x, click.point.y - last.point.y)

            if timeDelta <= timeThreshold && distance <= distanceThreshold {
                current.events.append(click)
                chapters.append(current)
            } else {
                chapters.append(current)
                chapters.append(ClickChapter(events: [click]))
            }
        }

        return chapters
    }

    private func softBoundedCenter(
        for point: CGPoint,
        currentCenter: CGPoint,
        scale: Double,
        width: Double,
        height: Double
    ) -> CGPoint {
        let safeScale = max(1, scale)
        let visibleWidth = width / safeScale
        let visibleHeight = height / safeScale

        let cropRect = CGRect(
            x: currentCenter.x - visibleWidth / 2,
            y: currentCenter.y - visibleHeight / 2,
            width: visibleWidth,
            height: visibleHeight
        )

        let safeRect = cropRect.insetBy(dx: visibleWidth * 0.2, dy: visibleHeight * 0.2)
        var adjusted = currentCenter

        if point.x < safeRect.minX {
            adjusted.x -= (safeRect.minX - point.x)
        } else if point.x > safeRect.maxX {
            adjusted.x += (point.x - safeRect.maxX)
        }

        if point.y < safeRect.minY {
            adjusted.y -= (safeRect.minY - point.y)
        } else if point.y > safeRect.maxY {
            adjusted.y += (point.y - safeRect.maxY)
        }

        return clampedCenter(for: adjusted, scale: scale, width: width, height: height)
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
}
