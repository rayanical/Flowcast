//
//  CaptureSampleBufferRouter.swift
//  BetterCapture
//

import Foundation
import ScreenCaptureKit

/// Forwards capture sample buffers to multiple delegates.
final class CaptureSampleBufferRouter: CaptureEngineSampleBufferDelegate, @unchecked Sendable {
    nonisolated(unsafe) weak var primaryDelegate: CaptureEngineSampleBufferDelegate?
    nonisolated(unsafe) weak var secondaryDelegate: CaptureEngineSampleBufferDelegate?

    func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        primaryDelegate?.captureEngine(engine, didOutputVideoSampleBuffer: sampleBuffer)
        secondaryDelegate?.captureEngine(engine, didOutputVideoSampleBuffer: sampleBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        primaryDelegate?.captureEngine(engine, didOutputAudioSampleBuffer: sampleBuffer)
        secondaryDelegate?.captureEngine(engine, didOutputAudioSampleBuffer: sampleBuffer)
    }

    func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        primaryDelegate?.captureEngine(engine, didOutputMicrophoneSampleBuffer: sampleBuffer)
        secondaryDelegate?.captureEngine(engine, didOutputMicrophoneSampleBuffer: sampleBuffer)
    }
}
