//
//  CameraTrack.swift
//  BetterCapture
//

import Foundation

struct CameraKeyframe: Codable, Sendable {
    let t: Double
    let scale: Double
    let cx: Double
    let cy: Double
}

struct CameraState: Sendable {
    let scale: Double
    let cx: Double
    let cy: Double
}

struct CameraTrack: Codable, Sendable {
    let version: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let keyframes: [CameraKeyframe]

    init(version: Int = 1, sourceWidth: Int, sourceHeight: Int, keyframes: [CameraKeyframe]) {
        self.version = version
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.keyframes = keyframes.sorted { $0.t < $1.t }
    }

    var duration: Double {
        keyframes.last?.t ?? 0
    }

    func state(at time: Double) -> CameraState {
        guard let first = keyframes.first else {
            return CameraState(
                scale: 1,
                cx: Double(sourceWidth) / 2,
                cy: Double(sourceHeight) / 2
            )
        }

        if time <= first.t {
            return CameraState(scale: first.scale, cx: first.cx, cy: first.cy)
        }

        guard let last = keyframes.last else {
            return CameraState(scale: first.scale, cx: first.cx, cy: first.cy)
        }

        if time >= last.t {
            return CameraState(scale: last.scale, cx: last.cx, cy: last.cy)
        }

        for index in 0..<(keyframes.count - 1) {
            let start = keyframes[index]
            let end = keyframes[index + 1]
            if time >= start.t && time <= end.t {
                let span = max(0.000_001, end.t - start.t)
                let progress = (time - start.t) / span
                let easedProgress = smoothStep(progress)
                return CameraState(
                    scale: start.scale + (end.scale - start.scale) * easedProgress,
                    cx: start.cx + (end.cx - start.cx) * easedProgress,
                    cy: start.cy + (end.cy - start.cy) * easedProgress
                )
            }
        }

        return CameraState(scale: last.scale, cx: last.cx, cy: last.cy)
    }

    private func smoothStep(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
