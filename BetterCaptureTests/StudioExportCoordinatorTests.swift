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
        let snapshot = await MainActor.run {
            (
                id: artifact.id,
                captureWidth: artifact.captureWidth,
                captureHeight: artifact.captureHeight,
                eventsURL: artifact.eventsURL,
                rawVideoURL: artifact.rawVideoURL
            )
        }

        runOrder.append(snapshot.id)
        runCount += 1

        do {
            try await Task.sleep(for: delay)
        } catch {
            cancellationCount += 1
            throw error
        }

        let track = CameraTrack(
            sourceWidth: snapshot.captureWidth,
            sourceHeight: snapshot.captureHeight,
            keyframes: [
                CameraKeyframe(
                    t: 0,
                    scale: 1,
                    cx: Double(snapshot.captureWidth) / 2,
                    cy: Double(snapshot.captureHeight) / 2
                )
            ]
        )

        return StudioExportResult(
            artifactID: snapshot.id,
            cameraTrackURL: snapshot.eventsURL,
            finalVideoURL: snapshot.rawVideoURL,
            cameraTrack: track
        )
    }

    func generateCameraTrack(artifact: RawCaptureArtifact, configuration: StudioRenderConfiguration) async throws -> CameraTrack {
        let snapshot = await MainActor.run {
            (
                captureWidth: artifact.captureWidth,
                captureHeight: artifact.captureHeight
            )
        }

        return CameraTrack(
            sourceWidth: snapshot.captureWidth,
            sourceHeight: snapshot.captureHeight,
            keyframes: [
                CameraKeyframe(
                    t: 0,
                    scale: 1,
                    cx: Double(snapshot.captureWidth) / 2,
                    cy: Double(snapshot.captureHeight) / 2
                )
            ]
        )
    }
}

@MainActor
struct StudioExportCoordinatorTests {
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

    @Test
    func cancellationDoesNotDeleteRawRecording() async throws {
        let mockPipeline = MockStudioExportPipeline(delay: .seconds(1))
        let coordinator = StudioExportCoordinator(
            settings: SettingsStore(),
            pipeline: mockPipeline,
            previewEnabled: false
        )

        let id = UUID()
        let temporaryDirectory = URL.temporaryDirectory
        let rawURL = temporaryDirectory.appending(path: "\(id.uuidString).mov")
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
                eventsURL: temporaryDirectory.appending(path: "\(id.uuidString).events.json")
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
        let temporaryDirectory = URL.temporaryDirectory
        return RawCaptureArtifact(
            id: id,
            rawVideoURL: temporaryDirectory.appending(path: "\(id.uuidString).mov"),
            captureWidth: 1_920,
            captureHeight: 1_080,
            captureMode: .display,
            startedAt: .now,
            endedAt: .now,
            eventsURL: temporaryDirectory.appending(path: "\(id.uuidString).events.json")
        )
    }
}
