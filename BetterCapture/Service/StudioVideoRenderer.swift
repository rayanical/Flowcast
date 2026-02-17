//
//  StudioVideoRenderer.swift
//  BetterCapture
//

@preconcurrency import AVFoundation
import CoreImage
import Foundation
import OSLog

enum StudioRenderError: LocalizedError {
    case noVideoTrack
    case failedToCreateReader
    case failedToCreateWriter
    case failedToStartReader
    case failedToStartWriter
    case noVideoFrames
    case missingPixelBuffer
    case pixelBufferPoolUnavailable
    case failedToAppendVideo
    case failedToAppendAudio
    case writerFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "No video track found in the raw recording."
        case .failedToCreateReader:
            return "Could not create an AVAssetReader for studio export."
        case .failedToCreateWriter:
            return "Could not create an AVAssetWriter for studio export."
        case .failedToStartReader:
            return "Failed to start reading raw recording samples."
        case .failedToStartWriter:
            return "Failed to start writing studio output."
        case .noVideoFrames:
            return "No video frames were available for studio export."
        case .missingPixelBuffer:
            return "A video sample was missing its image buffer."
        case .pixelBufferPoolUnavailable:
            return "Unable to allocate destination pixel buffers for rendering."
        case .failedToAppendVideo:
            return "Failed to append a transformed video frame."
        case .failedToAppendAudio:
            return "Failed to append audio during studio export."
        case .writerFailed(let error):
            return "Studio writer failed: \(error?.localizedDescription ?? "Unknown error")"
        }
    }
}

final class StudioVideoRenderer: @unchecked Sendable {
    private struct AudioPipe {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
    }

    private final class WriterBox: @unchecked Sendable {
        let writer: AVAssetWriter

        init(writer: AVAssetWriter) {
            self.writer = writer
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "StudioVideoRenderer")
    private let overlayContext = CIContext()

    func render(
        rawVideoURL: URL,
        cameraTrack: CameraTrack,
        outputURL: URL,
        events: [InteractionEvent],
        configuration: StudioRenderConfiguration,
        transformerFactory: (CGSize) -> any FrameTransformer
    ) async throws -> URL {
        let asset = AVURLAsset(url: rawVideoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioRenderError.noVideoTrack
        }

        let sourceSize = try await videoTrack.load(.naturalSize)
        let outputSize = configuration.exportPreset.resolvedSize(for: sourceSize)
        let sourceWidth = sourceSize.width
        let sourceHeight = sourceSize.height

        let clickEvents = events
            .filter { $0.type == .click }
            .sorted { $0.t < $1.t }

        let cursorEvents = events
            .filter { $0.type == .cursor }
            .sorted { $0.t < $1.t }

        let reader = try AVAssetReader(asset: asset)

        let videoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        videoOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(videoOutput) else {
            throw StudioRenderError.failedToCreateReader
        }
        reader.add(videoOutput)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioPipes: [AudioPipe] = []
        audioPipes.reserveCapacity(audioTracks.count)

        for track in audioTracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false

            guard reader.canAdd(output) else {
                continue
            }

            reader.add(output)

            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            input.expectsMediaDataInRealTime = false
            audioPipes.append(AudioPipe(output: output, input: input))
        }

        if FileManager.default.fileExists(atPath: outputURL.path()) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings(for: outputSize)
        )
        videoInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(videoInput) else {
            throw StudioRenderError.failedToCreateWriter
        }
        writer.add(videoInput)

        let activeAudioPipes = audioPipes.filter { writer.canAdd($0.input) }
        for pipe in activeAudioPipes {
            writer.add(pipe.input)
        }

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(outputSize.width),
                kCVPixelBufferHeightKey as String: Int(outputSize.height)
            ]
        )

        guard writer.startWriting() else {
            throw StudioRenderError.failedToStartWriter
        }

        guard reader.startReading() else {
            throw StudioRenderError.failedToStartReader
        }

        let transformer = transformerFactory(outputSize)

        do {
            guard let firstSample = videoOutput.copyNextSampleBuffer() else {
                throw StudioRenderError.noVideoFrames
            }

            let firstPTS = CMSampleBufferGetPresentationTimeStamp(firstSample)
            writer.startSession(atSourceTime: firstPTS)

            try await appendVideoSample(
                firstSample,
                firstPTS: firstPTS,
                cameraTrack: cameraTrack,
                transformer: transformer,
                adaptor: adaptor,
                videoInput: videoInput,
                clickEvents: clickEvents,
                cursorEvents: cursorEvents,
                sourceSize: CGSize(width: sourceWidth, height: sourceHeight),
                outputSize: outputSize,
                configuration: configuration
            )

            while let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try await appendVideoSample(
                    sampleBuffer,
                    firstPTS: firstPTS,
                    cameraTrack: cameraTrack,
                    transformer: transformer,
                    adaptor: adaptor,
                    videoInput: videoInput,
                    clickEvents: clickEvents,
                    cursorEvents: cursorEvents,
                    sourceSize: CGSize(width: sourceWidth, height: sourceHeight),
                    outputSize: outputSize,
                    configuration: configuration
                )

                // Consume audio continuously while reading video so reader buffers do not stall.
                for pipe in activeAudioPipes {
                    try appendOneAudioSampleIfAvailable(from: pipe.output, to: pipe.input)
                }
            }

            videoInput.markAsFinished()

            for pipe in activeAudioPipes {
                try await appendAudio(from: pipe.output, to: pipe.input)
                pipe.input.markAsFinished()
            }

            try await finishWriting(writer)

            if writer.status == .failed {
                throw StudioRenderError.writerFailed(writer.error)
            }

            logger.info("Studio render finished: \(outputURL.lastPathComponent)")
            return outputURL

        } catch {
            reader.cancelReading()
            writer.cancelWriting()

            if FileManager.default.fileExists(atPath: outputURL.path()) {
                try? FileManager.default.removeItem(at: outputURL)
            }

            throw error
        }
    }

    private func appendVideoSample(
        _ sampleBuffer: CMSampleBuffer,
        firstPTS: CMTime,
        cameraTrack: CameraTrack,
        transformer: any FrameTransformer,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        videoInput: AVAssetWriterInput,
        clickEvents: [InteractionEvent],
        cursorEvents: [InteractionEvent],
        sourceSize: CGSize,
        outputSize: CGSize,
        configuration: StudioRenderConfiguration
    ) async throws {
        try Task.checkCancellation()

        guard let sourceBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw StudioRenderError.missingPixelBuffer
        }

        guard let pool = adaptor.pixelBufferPool else {
            throw StudioRenderError.pixelBufferPoolUnavailable
        }

        var destinationBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer)

        guard let destinationBuffer else {
            throw StudioRenderError.pixelBufferPoolUnavailable
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let relativeTime = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS))
        let state = cameraTrack.state(at: max(0, relativeTime))

        try transformer.transform(
            sourcePixelBuffer: sourceBuffer,
            cameraState: state,
            destinationPixelBuffer: destinationBuffer
        )

        applyPolishOverlays(
            destinationPixelBuffer: destinationBuffer,
            relativeTime: max(0, relativeTime),
            cameraState: state,
            clickEvents: clickEvents,
            cursorEvents: cursorEvents,
            sourceSize: sourceSize,
            outputSize: outputSize,
            configuration: configuration
        )

        while !videoInput.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(1))
        }

        guard adaptor.append(destinationBuffer, withPresentationTime: pts) else {
            throw StudioRenderError.failedToAppendVideo
        }
    }

    private func appendAudio(from output: AVAssetReaderTrackOutput, to input: AVAssetWriterInput) async throws {
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(1))
            }

            if !input.append(sampleBuffer) {
                throw StudioRenderError.failedToAppendAudio
            }
        }
    }

    private func appendOneAudioSampleIfAvailable(from output: AVAssetReaderTrackOutput, to input: AVAssetWriterInput) throws {
        guard input.isReadyForMoreMediaData else {
            return
        }
        guard let sampleBuffer = output.copyNextSampleBuffer() else {
            return
        }
        if !input.append(sampleBuffer) {
            throw StudioRenderError.failedToAppendAudio
        }
    }

    private func finishWriting(_ writer: AVAssetWriter) async throws {
        let box = WriterBox(writer: writer)
        try await withCheckedThrowingContinuation { continuation in
            box.writer.finishWriting {
                if box.writer.status == .completed {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: StudioRenderError.writerFailed(box.writer.error))
                }
            }
        }
    }

    private func applyPolishOverlays(
        destinationPixelBuffer: CVPixelBuffer,
        relativeTime: Double,
        cameraState: CameraState,
        clickEvents: [InteractionEvent],
        cursorEvents: [InteractionEvent],
        sourceSize: CGSize,
        outputSize: CGSize,
        configuration: StudioRenderConfiguration
    ) {
        guard configuration.clickRippleEnabled || configuration.cursorScaleEnabled else {
            return
        }

        let outputRect = CGRect(origin: .zero, size: outputSize)
        var image = CIImage(cvPixelBuffer: destinationPixelBuffer)

        if configuration.clickRippleEnabled,
           let clickEvent = latestClickEvent(at: relativeTime, clickEvents: clickEvents),
           let capturePoint = capturePoint(from: clickEvent),
           let mappedPoint = mapCapturePointToOutput(
                capturePoint,
                cameraState: cameraState,
                sourceSize: sourceSize,
                outputSize: outputSize
           ) {
            let age = max(0, relativeTime - clickEvent.t)
            let progress = min(max(age / 0.35, 0), 1)
            let radius = 24 + 120 * progress
            let alpha = 0.35 * (1 - progress)

            if alpha > 0.01 {
                let ripple = radialGradient(
                    center: mappedPoint,
                    innerRadius: radius * 0.35,
                    outerRadius: radius,
                    alpha: alpha,
                    extent: outputRect
                )
                image = ripple.composited(over: image)
            }
        }

        if configuration.cursorScaleEnabled,
           cameraState.scale > 1,
           let cursorEvent = latestCursorEvent(at: relativeTime, cursorEvents: cursorEvents),
           let capturePoint = capturePoint(from: cursorEvent),
           let mappedPoint = mapCapturePointToOutput(
                capturePoint,
                cameraState: cameraState,
                sourceSize: sourceSize,
                outputSize: outputSize
           ) {
            let emphasis = min(max((cameraState.scale - 1) / 1.5, 0), 1)
            let radius = 10 + 20 * emphasis
            let halo = radialGradient(
                center: mappedPoint,
                innerRadius: radius * 0.2,
                outerRadius: radius,
                alpha: 0.22,
                extent: outputRect
            )
            image = halo.composited(over: image)
        }

        overlayContext.render(image, to: destinationPixelBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    private func latestClickEvent(at time: Double, clickEvents: [InteractionEvent]) -> InteractionEvent? {
        clickEvents.last { event in
            event.t <= time && (time - event.t) <= 0.35
        }
    }

    private func latestCursorEvent(at time: Double, cursorEvents: [InteractionEvent]) -> InteractionEvent? {
        if let latest = cursorEvents.last(where: { $0.t <= time }) {
            return latest
        }
        return cursorEvents.first
    }

    private func capturePoint(from event: InteractionEvent) -> CGPoint? {
        guard let x = event.captureX, let y = event.captureY else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    private func mapCapturePointToOutput(
        _ point: CGPoint,
        cameraState: CameraState,
        sourceSize: CGSize,
        outputSize: CGSize
    ) -> CGPoint? {
        guard sourceSize.width > 0, sourceSize.height > 0, outputSize.width > 0, outputSize.height > 0 else {
            return nil
        }

        let sourceWidth = sourceSize.width
        let sourceHeight = sourceSize.height
        let safeScale = max(1, cameraState.scale)

        let cropWidth = sourceWidth / safeScale
        let cropHeight = sourceHeight / safeScale

        let clampedCenterX = min(max(cameraState.cx, cropWidth / 2), sourceWidth - cropWidth / 2)
        let clampedCenterY = min(max(cameraState.cy, cropHeight / 2), sourceHeight - cropHeight / 2)

        let cropRect = CGRect(
            x: clampedCenterX - cropWidth / 2,
            y: clampedCenterY - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        )

        let normalizedX = (point.x - cropRect.minX) / cropRect.width
        let normalizedY = (point.y - cropRect.minY) / cropRect.height

        return CGPoint(
            x: normalizedX * outputSize.width,
            y: normalizedY * outputSize.height
        )
    }

    private func radialGradient(
        center: CGPoint,
        innerRadius: Double,
        outerRadius: Double,
        alpha: Double,
        extent: CGRect
    ) -> CIImage {
        let gradient = CIFilter(
            name: "CIRadialGradient",
            parameters: [
                "inputCenter": CIVector(cgPoint: center),
                "inputRadius0": innerRadius,
                "inputRadius1": outerRadius,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: alpha),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            ]
        )?.outputImage ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

        return gradient.cropped(to: extent)
    }

    private func videoSettings(for outputSize: CGSize) -> [String: Any] {
        let longEdge = max(outputSize.width, outputSize.height)
        let bitrate: Int

        if longEdge <= 1_920 {
            bitrate = 16_000_000
        } else if longEdge <= 2_560 {
            bitrate = 28_000_000
        } else {
            bitrate = 45_000_000
        }

        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
    }
}
