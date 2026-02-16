//
//  StudioExportCoordinatorTests.swift
//  BetterCaptureTests
//

import Foundation
import Testing
@testable import BetterCapture

actor MockStudioExportPipeline: StudioExportPipelineType {
    private(set) var runOrder: [UUID] = []
    private(set) var runCount = 0
    private(set) var cancellationCount = 0

    let delay: Duration

    init(delay: Duration = .milliseconds(60)) {
        self.delay = delay
    }

    func run(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> StudioExportResult {
        runOrder.append(artifact.id)
        runCount += 1

        do {
            try await Task.sleep(for: delay)
        } catch {
            cancellationCount += 1
            throw error
        }

        let track = CameraTrack(
            sourceWidth: artifact.captureWidth,
            sourceHeight: artifact.captureHeight,
            keyframes: [
                CameraKeyframe(t: 0, scale: 1, cx: Double(artifact.captureWidth) / 2, cy: Double(artifact.captureHeight) / 2)
            ]
        )

        return StudioExportResult(
            artifactID: artifact.id,
            cameraTrackURL: artifact.eventsURL,
            finalVideoURL: artifact.rawVideoURL,
            cameraTrack: track
        )
    }

    func generateCameraTrack(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> CameraTrack {
        CameraTrack(
            sourceWidth: artifact.captureWidth,
            sourceHeight: artifact.captureHeight,
            keyframes: [
                CameraKeyframe(t: 0, scale: 1, cx: Double(artifact.captureWidth) / 2, cy: Double(artifact.captureHeight) / 2)
            ]
        )
    }
}

struct StudioExportCoordinatorTests {
    @MainActor
    @Test
    func coordinatorQueuesJobsSerially() async throws {
        let mockPipeline = MockStudioExportPipeline()
        let coordinator = StudioExportCoordinator(
            settings: SettingsStore(),
            pipeline: mockPipeline,
            previewEnabled: false
        )

        let firstID = UUID()
        let secondID = UUID()

        coordinator.recordRawArtifact(makeArtifact(id: firstID), autoExport: true)
        coordinator.recordRawArtifact(makeArtifact(id: secondID), autoExport: true)

        try await Task.sleep(for: .milliseconds(220))

        let order = await mockPipeline.runOrder
        #expect(order == [firstID, secondID])
        #expect(await mockPipeline.runCount == 2)
        #expect(await mockPipeline.cancellationCount == 0)
    }

    @MainActor
    @Test
    func coordinatorCanCancelActiveExports() async throws {
        let mockPipeline = MockStudioExportPipeline(delay: .seconds(1))
        let coordinator = StudioExportCoordinator(
            settings: SettingsStore(),
            pipeline: mockPipeline,
            previewEnabled: false
        )

        coordinator.recordRawArtifact(makeArtifact(id: UUID()), autoExport: true)
        try await Task.sleep(for: .milliseconds(80))

        coordinator.cancelAllExports()
        try await Task.sleep(for: .milliseconds(120))

        #expect(await mockPipeline.cancellationCount >= 1)
    }

    @MainActor
    @Test
    func cancellationDoesNotDeleteRawRecording() async throws {
        let mockPipeline = MockStudioExportPipeline(delay: .seconds(1))
        let coordinator = StudioExportCoordinator(
            settings: SettingsStore(),
            pipeline: mockPipeline,
            previewEnabled: false
        )

        let id = UUID()
        let rawURL = URL(filePath: "/tmp/\(id.uuidString).mov")
        let rawData = Data("raw".utf8)
        try rawData.write(to: rawURL, options: .atomic)

        coordinator.recordRawArtifact(
            RawCaptureArtifact(
                id: id,
                rawVideoURL: rawURL,
                captureWidth: 1_920,
                captureHeight: 1_080,
                captureMode: .display,
                startedAt: .now,
                endedAt: .now,
                eventsURL: URL(filePath: "/tmp/\(id.uuidString).events.json")
            ),
            autoExport: true
        )
        try await Task.sleep(for: .milliseconds(80))
        coordinator.cancelAllExports()
        try await Task.sleep(for: .milliseconds(120))

        #expect(FileManager.default.fileExists(atPath: rawURL.path()))

        try? FileManager.default.removeItem(at: rawURL)
    }

    private func makeArtifact(id: UUID) -> RawCaptureArtifact {
        RawCaptureArtifact(
            id: id,
            rawVideoURL: URL(filePath: "/tmp/\(id.uuidString).mov"),
            captureWidth: 1_920,
            captureHeight: 1_080,
            captureMode: .display,
            startedAt: .now,
            endedAt: .now,
            eventsURL: URL(filePath: "/tmp/\(id.uuidString).events.json")
        )
    }
}
