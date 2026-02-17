//
//  CameraPreviewEngine.swift
//  BetterCapture
//

import AppKit
@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Lightweight preview renderer for camera track tuning before export.
@MainActor
@Observable
final class CameraPreviewEngine {
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "CameraPreviewEngine")

    private(set) var previewImage: NSImage?
    private(set) var isRendering = false
    private(set) var lastErrorMessage: String?

    private var previewTask: Task<Void, Never>?
    private var renderToken = UUID()

    func startPreview(rawVideoURL: URL, cameraTrack: CameraTrack, configuration: StudioRenderConfiguration) {
        stopPreview(clearImage: false)

        let token = UUID()
        renderToken = token
        isRendering = true
        lastErrorMessage = nil

        previewTask = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Self.renderPreviewLoop(
                    rawVideoURL: rawVideoURL,
                    cameraTrack: cameraTrack,
                    configuration: configuration
                ) { image in
                    guard self.renderToken == token else {
                        return
                    }
                    self.previewImage = image
                }

                guard self.renderToken == token else {
                    return
                }
                self.isRendering = false

            } catch is CancellationError {
                guard self.renderToken == token else {
                    return
                }
                self.isRendering = false

            } catch {
                guard self.renderToken == token else {
                    return
                }
                self.isRendering = false
                self.lastErrorMessage = error.localizedDescription
                self.logger.error("Camera preview failed: \(error.localizedDescription)")
            }
        }
    }

    func stopPreview(clearImage: Bool = false) {
        previewTask?.cancel()
        previewTask = nil
        isRendering = false
        if clearImage {
            previewImage = nil
        }
    }

    private nonisolated static func renderPreviewLoop(
        rawVideoURL: URL,
        cameraTrack: CameraTrack,
        configuration: StudioRenderConfiguration,
        onFrame: @escaping @MainActor (NSImage) -> Void
    ) async throws {
        let asset = AVURLAsset(url: rawVideoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return
        }

        let sourceSize = try await track.load(.naturalSize)
        let previewSize = resolvedPreviewSize(for: sourceSize)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            return
        }

        reader.add(output)

        guard reader.startReading() else {
            return
        }

        var firstPTS: CMTime?
        let transformer: any FrameTransformer = CoreImageFrameTransformer(
            outputSize: previewSize,
            style: FrameTransformerStyle(
                roundedCornersEnabled: configuration.roundedCornersEnabled,
                shadowEnabled: configuration.shadowEnabled,
                backgroundBlurEnabled: configuration.backgroundBlurEnabled
            )
        )
        let ciContext = CIContext()
        let pool = try createPixelBufferPool(width: Int(previewSize.width), height: Int(previewSize.height))

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if firstPTS == nil {
                firstPTS = samplePTS
            }

            let timeline = CMTimeGetSeconds(CMTimeSubtract(samplePTS, firstPTS ?? samplePTS))
            let state = cameraTrack.state(at: max(0, timeline))

            var destinationBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destinationBuffer)

            guard let destinationBuffer else {
                continue
            }

            try transformer.transform(
                sourcePixelBuffer: sourcePixelBuffer,
                cameraState: state,
                destinationPixelBuffer: destinationBuffer
            )

            let image = CIImage(cvPixelBuffer: destinationBuffer)
            let rect = CGRect(origin: .zero, size: previewSize)
            guard let cgImage = ciContext.createCGImage(image, from: rect) else {
                continue
            }

            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await onFrame(nsImage)

            try await Task.sleep(for: .milliseconds(33))
        }
    }

    private nonisolated static func resolvedPreviewSize(for source: CGSize) -> CGSize {
        let maxWidth: CGFloat = 640
        let maxHeight: CGFloat = 360

        let widthScale = maxWidth / max(1, source.width)
        let heightScale = maxHeight / max(1, source.height)
        let scale = min(widthScale, heightScale, 1)

        let width = max(2, Int((source.width * scale).rounded()) / 2 * 2)
        let height = max(2, Int((source.height * scale).rounded()) / 2 * 2)

        return CGSize(width: width, height: height)
    }

    private nonisolated static func createPixelBufferPool(width: Int, height: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]

        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw StudioRenderError.pixelBufferPoolUnavailable
        }

        return pool
    }
}
