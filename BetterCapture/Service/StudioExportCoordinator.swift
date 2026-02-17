//
//  StudioExportCoordinator.swift
//  BetterCapture
//

import Foundation
import OSLog

@MainActor
@Observable
final class StudioExportCoordinator {
    enum Status: Equatable {
        case idle
        case queued(Int)
        case exporting(UUID)
        case completed(URL)
        case failed(String)
        case cancelled
    }

    private struct Job: Sendable {
        let artifact: RawCaptureArtifact
        let configuration: StudioRenderConfiguration
    }

    private enum QueueEvent: Sendable {
        case queued(Int)
        case exporting(UUID)
        case completed(StudioExportResult)
        case failed(String)
        case cancelled
        case idle
    }

    private actor ExportQueue {
        private var pendingJobs: [Job] = []
        private var activeArtifactID: UUID?
        private var activeTask: Task<Void, Never>?

        private let pipeline: any StudioExportPipelineType
        private let eventSink: @Sendable (QueueEvent) -> Void

        init(pipeline: any StudioExportPipelineType, eventSink: @escaping @Sendable (QueueEvent) -> Void) {
            self.pipeline = pipeline
            self.eventSink = eventSink
        }

        func enqueue(_ job: Job) {
            if activeArtifactID == job.artifact.id {
                return
            }
            if pendingJobs.contains(where: { $0.artifact.id == job.artifact.id }) {
                return
            }

            pendingJobs.append(job)
            eventSink(.queued(totalJobsCount))
            startNextIfNeeded()
        }

        func cancelAll() {
            pendingJobs.removeAll()
            activeTask?.cancel()
            eventSink(.cancelled)
        }

        private var totalJobsCount: Int {
            pendingJobs.count + (activeArtifactID == nil ? 0 : 1)
        }

        private func startNextIfNeeded() {
            guard activeTask == nil else {
                return
            }

            guard !pendingJobs.isEmpty else {
                eventSink(.idle)
                return
            }

            let nextJob = pendingJobs.removeFirst()
            activeArtifactID = nextJob.artifact.id
            eventSink(.exporting(nextJob.artifact.id))

            activeTask = Task {
                do {
                    let result = try await pipeline.run(
                        artifact: nextJob.artifact,
                        configuration: nextJob.configuration
                    )
                    try Task.checkCancellation()
                    eventSink(.completed(result))
                } catch is CancellationError {
                    eventSink(.cancelled)
                } catch {
                    eventSink(.failed(error.localizedDescription))
                }

                finishActiveTaskAndContinue()
            }
        }

        private func finishActiveTaskAndContinue() {
            activeTask = nil
            activeArtifactID = nil
            startNextIfNeeded()
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "StudioExportCoordinator")

    private let settings: SettingsStore
    private let pipeline: any StudioExportPipelineType
    private let isPreviewEnabled: Bool

    @ObservationIgnored private var queue: ExportQueue?

    private(set) var status: Status = .idle
    private(set) var lastRawArtifact: RawCaptureArtifact?
    private(set) var lastResult: StudioExportResult?

    let previewEngine = CameraPreviewEngine()
    private var previewRefreshTask: Task<Void, Never>?
    private var previewRevision = 0

    init(
        settings: SettingsStore,
        pipeline: (any StudioExportPipelineType)? = nil,
        previewEnabled: Bool = true
    ) {
        let resolvedPipeline = pipeline ?? StudioExportPipeline()
        self.settings = settings
        self.pipeline = resolvedPipeline
        self.isPreviewEnabled = previewEnabled
        self.queue = ExportQueue(pipeline: resolvedPipeline) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleQueueEvent(event)
            }
        }
    }

    var statusText: String {
        switch status {
        case .idle:
            return "Studio export idle"
        case .queued(let count):
            return "Studio export queued (\(count))"
        case .exporting:
            return "Rendering final.mov..."
        case .completed(let url):
            return "Studio export complete: \(url.lastPathComponent)"
        case .failed(let message):
            return "Studio export failed: \(message)"
        case .cancelled:
            return "Studio export cancelled"
        }
    }

    var canCancelExports: Bool {
        switch status {
        case .queued, .exporting:
            return true
        case .idle, .completed, .failed, .cancelled:
            return false
        }
    }

    var canExportLastRaw: Bool {
        lastRawArtifact != nil
    }

    var latestFinalVideoURL: URL? {
        lastResult?.finalVideoURL
    }

    func recordRawArtifact(_ artifact: RawCaptureArtifact, autoExport: Bool) {
        lastRawArtifact = artifact
        refreshPreview()

        guard autoExport else {
            return
        }
        guard let queue else {
            return
        }

        let configuration = settings.studioRenderConfiguration
        Task {
            await queue.enqueue(Job(artifact: artifact, configuration: configuration))
        }
    }

    func enqueue(_ artifact: RawCaptureArtifact) {
        recordRawArtifact(artifact, autoExport: settings.autoZoomEnabled)
    }

    func enqueueLastRawArtifact() {
        guard let artifact = lastRawArtifact else {
            return
        }
        guard let queue else {
            return
        }

        let configuration = settings.studioRenderConfiguration

        Task {
            await queue.enqueue(Job(artifact: artifact, configuration: configuration))
        }

        refreshPreview()
    }

    func cancelAllExports() {
        guard let queue else {
            return
        }
        Task {
            await queue.cancelAll()
        }
    }

    func refreshPreview() {
        previewRefreshTask?.cancel()

        guard isPreviewEnabled else {
            return
        }

        guard let artifact = lastRawArtifact else {
            previewEngine.stopPreview()
            return
        }

        let configuration = settings.studioRenderConfiguration
        previewRevision += 1
        let revision = previewRevision

        previewRefreshTask = Task {
            do {
                let track = try await pipeline.generateCameraTrack(
                    artifact: artifact,
                    configuration: configuration
                )
                try Task.checkCancellation()

                guard revision == previewRevision else {
                    return
                }

                previewEngine.startPreview(
                    rawVideoURL: artifact.rawVideoURL,
                    cameraTrack: track,
                    configuration: configuration
                )
            } catch is CancellationError {
                return
            } catch {
                logger.error("Failed to refresh camera preview: \(error.localizedDescription)")
            }
        }
    }

    private func handleQueueEvent(_ event: QueueEvent) {
        switch event {
        case .queued(let count):
            status = .queued(count)
        case .exporting(let id):
            status = .exporting(id)
        case .completed(let result):
            lastResult = result
            status = .completed(result.finalVideoURL)
            logger.info("Studio export completed: \(result.finalVideoURL.lastPathComponent)")
            refreshPreview()
        case .failed(let message):
            status = .failed(message)
            logger.error("Studio export failed: \(message)")
        case .cancelled:
            status = .cancelled
            logger.info("Studio export cancelled")
        case .idle:
            if case .completed = status {
                return
            }
            if case .cancelled = status {
                return
            }
            status = .idle
        }
    }
}
