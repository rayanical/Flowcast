//
//  StudioExportPipeline.swift
//  BetterCapture
//

@preconcurrency import AVFoundation
import Foundation

protocol StudioExportPipelineType: Sendable {
    func run(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> StudioExportResult
    func generateCameraTrack(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> CameraTrack
}

struct StudioExportResult: Sendable {
    let artifactID: UUID
    let cameraTrackURL: URL
    let finalVideoURL: URL
    let cameraTrack: CameraTrack
}

final class StudioExportPipeline: StudioExportPipelineType, @unchecked Sendable {
    private let cameraTrackGenerator: CameraTrackGenerator
    private let renderer: StudioVideoRenderer

    init(
        cameraTrackGenerator: CameraTrackGenerator = CameraTrackGenerator(),
        renderer: StudioVideoRenderer = StudioVideoRenderer()
    ) {
        self.cameraTrackGenerator = cameraTrackGenerator
        self.renderer = renderer
    }

    func run(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> StudioExportResult {
        let eventLog = try loadEventLog(from: artifact.eventsURL)
        let cameraTrackURL = artifact.rawVideoURL
            .deletingPathExtension()
            .appendingPathExtension("cameraTrack.json")

        let asset = AVURLAsset(url: artifact.rawVideoURL)
        let duration = max(0, CMTimeGetSeconds(try await asset.load(.duration)))
        let resolvedDuration = max(duration, eventLog.events.last?.t ?? 0)

        let cameraTrack = cameraTrackGenerator.generate(
            from: eventLog,
            duration: resolvedDuration,
            configuration: configuration
        )

        try writeCameraTrack(cameraTrack, to: cameraTrackURL)

        let finalURL = artifact.rawVideoURL
            .deletingPathExtension()
            .appendingPathExtension("final.mov")

        let outputURL = try await renderer.render(
            rawVideoURL: artifact.rawVideoURL,
            cameraTrack: cameraTrack,
            outputURL: finalURL,
            events: eventLog.events,
            configuration: configuration,
            transformerFactory: { outputSize in
                CoreImageFrameTransformer(
                    outputSize: outputSize,
                    style: FrameTransformerStyle(
                        roundedCornersEnabled: configuration.roundedCornersEnabled,
                        shadowEnabled: configuration.shadowEnabled,
                        backgroundBlurEnabled: configuration.backgroundBlurEnabled
                    )
                )
            }
        )

        return StudioExportResult(
            artifactID: artifact.id,
            cameraTrackURL: cameraTrackURL,
            finalVideoURL: outputURL,
            cameraTrack: cameraTrack
        )
    }

    func generateCameraTrack(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> CameraTrack {
        let eventLog = try loadEventLog(from: artifact.eventsURL)
        let asset = AVURLAsset(url: artifact.rawVideoURL)
        let duration = max(0, CMTimeGetSeconds(try await asset.load(.duration)))
        let resolvedDuration = max(duration, eventLog.events.last?.t ?? 0)

        return cameraTrackGenerator.generate(
            from: eventLog,
            duration: resolvedDuration,
            configuration: configuration
        )
    }

    private func loadEventLog(from url: URL) throws -> InteractionEventLog {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(InteractionEventLog.self, from: data)
    }

    private func writeCameraTrack(_ track: CameraTrack, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(track)
        try data.write(to: url, options: .atomic)
    }
}
