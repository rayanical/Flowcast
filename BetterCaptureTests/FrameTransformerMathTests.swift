//
//  FrameTransformerMathTests.swift
//  BetterCaptureTests
//

import AVFoundation
import Foundation
import Testing
@testable import BetterCapture

struct FrameTransformerMathTests {
    @Test
    func cameraTrackInterpolatesBetweenKeyframes() {
        let track = CameraTrack(
            sourceWidth: 1_920,
            sourceHeight: 1_080,
            keyframes: [
                CameraKeyframe(t: 0, scale: 1, cx: 960, cy: 540),
                CameraKeyframe(t: 1, scale: 2, cx: 1_200, cy: 600)
            ]
        )

        let state = track.state(at: 0.5)
        #expect(abs(state.scale - 1.5) < 0.000_1)
        #expect(abs(state.cx - 1_080) < 0.000_1)
        #expect(abs(state.cy - 570) < 0.000_1)
    }

    @Test
    func coreImageTransformerProducesFrameForDestinationBuffer() throws {
        let sourceWidth = 640
        let sourceHeight = 360
        let outputWidth = 320
        let outputHeight = 180

        var sourceBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            sourceWidth,
            sourceHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &sourceBuffer
        )

        var destinationBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            nil,
            outputWidth,
            outputHeight,
            kCVPixelFormatType_32BGRA,
            nil,
            &destinationBuffer
        )

        guard let sourceBuffer, let destinationBuffer else {
            Issue.record("Failed to allocate pixel buffers for transformer test")
            return
        }

        let transformer = CoreImageFrameTransformer(outputSize: CGSize(width: outputWidth, height: outputHeight))

        try transformer.transform(
            sourcePixelBuffer: sourceBuffer,
            cameraState: CameraState(scale: 1.8, cx: 320, cy: 180),
            destinationPixelBuffer: destinationBuffer
        )

        #expect(CVPixelBufferGetWidth(destinationBuffer) == outputWidth)
        #expect(CVPixelBufferGetHeight(destinationBuffer) == outputHeight)
    }
}
