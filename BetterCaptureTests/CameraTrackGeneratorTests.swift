//
//  CameraTrackGeneratorTests.swift
//  BetterCaptureTests
//

import Foundation
import Testing
@testable import BetterCapture

struct CameraTrackGeneratorTests {
    @Test
    func clickGeneratesZoomPulseAndClampsToBounds() {
        let log = InteractionEventLog(
            captureWidth: 1_920,
            captureHeight: 1_080,
            events: [
                InteractionEvent(t: 0.0, type: .cursor, globalX: 100, globalY: 100, captureX: 200, captureY: 200),
                InteractionEvent(t: 0.6, type: .cursor, globalX: 100, globalY: 100, captureX: 900, captureY: 500),
                InteractionEvent(t: 1.0, type: .click, button: .left, globalX: 100, globalY: 100, captureX: 910, captureY: 510),
                InteractionEvent(t: 1.8, type: .scroll, globalX: 100, globalY: 100, captureX: 1_200, captureY: 650, dx: 0, dy: -60)
            ]
        )

        let configuration = StudioRenderConfiguration(
            autoZoomEnabled: true,
            maxScale: 2.2,
            clickEmphasis: 0.8,
            smoothing: 0.55,
            followCursor: true,
            profilePreset: .tutorial,
            exportPreset: .source,
            clickRippleEnabled: true,
            cursorScaleEnabled: true,
            roundedCornersEnabled: true,
            shadowEnabled: true,
            backgroundBlurEnabled: false
        )

        let generator = CameraTrackGenerator()
        let track = generator.generate(from: log, duration: 3.0, configuration: configuration)

        #expect(track.keyframes.count > 4)
        #expect(track.keyframes.contains(where: { $0.scale > 1.0 }))
        #expect(track.keyframes.allSatisfy { $0.scale >= 1.0 && $0.scale <= 2.2 })

        for keyframe in track.keyframes {
            let visibleWidth = Double(log.captureWidth) / max(1, keyframe.scale)
            let visibleHeight = Double(log.captureHeight) / max(1, keyframe.scale)

            let minX = visibleWidth / 2
            let maxX = Double(log.captureWidth) - visibleWidth / 2
            let minY = visibleHeight / 2
            let maxY = Double(log.captureHeight) - visibleHeight / 2

            #expect(keyframe.cx >= minX)
            #expect(keyframe.cx <= maxX)
            #expect(keyframe.cy >= minY)
            #expect(keyframe.cy <= maxY)
        }
    }

    @Test
    func nearbyClicksStayInSingleZoomSession() {
        let log = InteractionEventLog(
            captureWidth: 1_920,
            captureHeight: 1_080,
            events: [
                InteractionEvent(t: 1.0, type: .click, button: .left, globalX: 0, globalY: 0, captureX: 600, captureY: 400),
                InteractionEvent(t: 1.5, type: .click, button: .left, globalX: 0, globalY: 0, captureX: 640, captureY: 430),
                InteractionEvent(t: 1.9, type: .click, button: .left, globalX: 0, globalY: 0, captureX: 670, captureY: 450)
            ]
        )

        let configuration = StudioRenderConfiguration(
            autoZoomEnabled: true,
            maxScale: 2.0,
            clickEmphasis: 0.7,
            smoothing: 0.5,
            followCursor: false,
            profilePreset: .tutorial,
            exportPreset: .source,
            clickRippleEnabled: false,
            cursorScaleEnabled: false,
            roundedCornersEnabled: false,
            shadowEnabled: false,
            backgroundBlurEnabled: false
        )

        let track = CameraTrackGenerator().generate(from: log, duration: 6.0, configuration: configuration)
        let scaleDropMoments = track.keyframes.filter { $0.scale == 1.0 && $0.t > 0.1 }

        // One chapter should produce one zoom-out back to scale 1 (plus final keyframe).
        #expect(scaleDropMoments.count <= 3)
        #expect(track.keyframes.contains(where: { $0.t < 1.0 && $0.scale == 1.0 }))
    }

    @Test
    func zoomUsesAnticipationBeforeClickTime() {
        let log = InteractionEventLog(
            captureWidth: 1_920,
            captureHeight: 1_080,
            events: [
                InteractionEvent(t: 2.0, type: .click, button: .left, globalX: 0, globalY: 0, captureX: 800, captureY: 500)
            ]
        )

        let configuration = StudioRenderConfiguration(
            autoZoomEnabled: true,
            maxScale: 2.0,
            clickEmphasis: 0.7,
            smoothing: 0.5,
            followCursor: false,
            profilePreset: .tutorial,
            exportPreset: .source,
            clickRippleEnabled: false,
            cursorScaleEnabled: false,
            roundedCornersEnabled: false,
            shadowEnabled: false,
            backgroundBlurEnabled: false
        )

        let track = CameraTrackGenerator().generate(from: log, duration: 5.0, configuration: configuration)
        #expect(track.keyframes.contains(where: { $0.t < 2.0 && $0.scale == 1.0 }))
        #expect(track.keyframes.contains(where: { $0.t == 2.0 && $0.scale > 1.0 }))
    }
}
