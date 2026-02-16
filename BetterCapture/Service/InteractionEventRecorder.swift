//
//  InteractionEventRecorder.swift
//  BetterCapture
//

import AppKit
import Foundation
import OSLog
import ScreenCaptureKit
import os

/// Maps global screen coordinates to capture-space pixel coordinates (top-left origin).
struct CaptureCoordinateMapper: Sendable {
    let globalRect: CGRect
    let captureWidth: Double
    let captureHeight: Double

    func capturePoint(from globalPoint: CGPoint) -> CGPoint? {
        guard globalRect.contains(globalPoint), globalRect.width > 0, globalRect.height > 0 else {
            return nil
        }

        let localX = globalPoint.x - globalRect.minX
        let localY = globalPoint.y - globalRect.minY

        let normalizedX = localX / globalRect.width
        let normalizedY = localY / globalRect.height

        let captureX = normalizedX * captureWidth
        let captureY = (1 - normalizedY) * captureHeight

        return CGPoint(
            x: min(max(captureX, 0), captureWidth),
            y: min(max(captureY, 0), captureHeight)
        )
    }
}

/// Records cursor, click, and scroll metadata aligned to video frame timestamps.
final class InteractionEventRecorder: CaptureEngineSampleBufferDelegate, @unchecked Sendable {
    private enum PendingKind {
        case click(MouseButton)
        case scroll(dx: Double, dy: Double)
    }

    private struct PendingInputEvent {
        let hostTime: UInt64
        let globalPoint: CGPoint
        let kind: PendingKind
    }

    private struct RecorderState {
        var isRecording = false
        var firstVideoPTS: Double?
        var lastFrameTimelineTime: Double?
        var captureWidth = 0
        var captureHeight = 0
        var mapper: CaptureCoordinateMapper?
        var events: [InteractionEvent] = []
        var pendingEvents: [PendingInputEvent] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: RecorderState())
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "InteractionEventRecorder")

    private var leftClickMonitor: Any?
    private var rightClickMonitor: Any?
    private var scrollMonitor: Any?

    @MainActor
    func startRecording(captureWidth: Int, captureHeight: Int, mapper: CaptureCoordinateMapper?) {
        stopMonitorsIfNeeded()

        lock.withLockUnchecked { state in
            state.isRecording = true
            state.firstVideoPTS = nil
            state.lastFrameTimelineTime = nil
            state.captureWidth = captureWidth
            state.captureHeight = captureHeight
            state.mapper = mapper
            state.events = []
            state.pendingEvents = []
        }

        leftClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.enqueueClick(event, button: .left)
        }
        rightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            self?.enqueueClick(event, button: .right)
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.enqueueScroll(event)
        }

        logger.info("Interaction recorder started")
    }

    @MainActor
    func stopAndWriteEvents(to url: URL) async throws -> URL {
        stopMonitorsIfNeeded()

        let log = lock.withLockUnchecked { state in
            state.isRecording = false

            if let lastFrameTime = state.lastFrameTimelineTime {
                flushPendingEvents(state: &state, upToHostTime: .max, timelineTime: lastFrameTime)
            } else {
                state.pendingEvents.removeAll()
            }

            return InteractionEventLog(
                captureWidth: state.captureWidth,
                captureHeight: state.captureHeight,
                events: state.events
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(log)

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)

        logger.info("Wrote events sidecar: \(url.lastPathComponent)")
        return url
    }

    @MainActor
    func cancelRecording() {
        stopMonitorsIfNeeded()

        lock.withLockUnchecked { state in
            state.isRecording = false
            state.firstVideoPTS = nil
            state.lastFrameTimelineTime = nil
            state.events.removeAll()
            state.pendingEvents.removeAll()
        }

        logger.info("Interaction recorder cancelled")
    }

    func captureEngine(_ engine: CaptureEngine, didOutputVideoSampleBuffer sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, isCompleteFrame(sampleBuffer) else {
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard presentationTime.isFinite else {
            return
        }

        let hostTime = DispatchTime.now().uptimeNanoseconds
        let globalPoint = currentGlobalMouseLocation()

        lock.withLockUnchecked { state in
            guard state.isRecording else {
                return
            }

            if state.firstVideoPTS == nil {
                state.firstVideoPTS = presentationTime
            }

            let base = state.firstVideoPTS ?? presentationTime
            let timelineTime = max(0, presentationTime - base)
            state.lastFrameTimelineTime = timelineTime

            let capturePoint = state.mapper?.capturePoint(from: globalPoint)
            let coordinates = captureCoordinates(from: capturePoint)

            state.events.append(
                InteractionEvent(
                    t: timelineTime,
                    type: .cursor,
                    globalX: globalPoint.x,
                    globalY: globalPoint.y,
                    captureX: coordinates.x,
                    captureY: coordinates.y
                )
            )

            flushPendingEvents(state: &state, upToHostTime: hostTime, timelineTime: timelineTime)
        }
    }

    func captureEngine(_ engine: CaptureEngine, didOutputAudioSampleBuffer sampleBuffer: CMSampleBuffer) {
        // Intentionally ignored. Metadata timing is aligned to video frames.
    }

    func captureEngine(_ engine: CaptureEngine, didOutputMicrophoneSampleBuffer sampleBuffer: CMSampleBuffer) {
        // Intentionally ignored. Metadata timing is aligned to video frames.
    }

    @MainActor
    private func stopMonitorsIfNeeded() {
        if let leftClickMonitor {
            NSEvent.removeMonitor(leftClickMonitor)
            self.leftClickMonitor = nil
        }
        if let rightClickMonitor {
            NSEvent.removeMonitor(rightClickMonitor)
            self.rightClickMonitor = nil
        }
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
        }
    }

    private func enqueueClick(_ event: NSEvent, button: MouseButton) {
        let point = event.cgEvent?.location ?? event.locationInWindow
        let pending = PendingInputEvent(
            hostTime: DispatchTime.now().uptimeNanoseconds,
            globalPoint: point,
            kind: .click(button)
        )

        lock.withLockUnchecked { state in
            guard state.isRecording else {
                return
            }
            state.pendingEvents.append(pending)
        }
    }

    private func enqueueScroll(_ event: NSEvent) {
        let point = event.cgEvent?.location ?? event.locationInWindow
        let pending = PendingInputEvent(
            hostTime: DispatchTime.now().uptimeNanoseconds,
            globalPoint: point,
            kind: .scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
        )

        lock.withLockUnchecked { state in
            guard state.isRecording else {
                return
            }
            state.pendingEvents.append(pending)
        }
    }

    private func currentGlobalMouseLocation() -> CGPoint {
        if let location = CGEvent(source: nil)?.location {
            return location
        }
        return NSEvent.mouseLocation
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status.rawValue] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue) else {
            return false
        }

        return status == .complete
    }

    private func flushPendingEvents(state: inout RecorderState, upToHostTime: UInt64, timelineTime: Double) {
        guard !state.pendingEvents.isEmpty else {
            return
        }

        var remaining: [PendingInputEvent] = []
        remaining.reserveCapacity(state.pendingEvents.count)

        for pending in state.pendingEvents {
            guard pending.hostTime <= upToHostTime else {
                remaining.append(pending)
                continue
            }

            let capturePoint = state.mapper?.capturePoint(from: pending.globalPoint)
            let coordinates = captureCoordinates(from: capturePoint)

            switch pending.kind {
            case .click(let button):
                state.events.append(
                    InteractionEvent(
                        t: timelineTime,
                        type: .click,
                        button: button,
                        globalX: pending.globalPoint.x,
                        globalY: pending.globalPoint.y,
                        captureX: coordinates.x,
                        captureY: coordinates.y
                    )
                )
            case .scroll(let dx, let dy):
                state.events.append(
                    InteractionEvent(
                        t: timelineTime,
                        type: .scroll,
                        globalX: pending.globalPoint.x,
                        globalY: pending.globalPoint.y,
                        captureX: coordinates.x,
                        captureY: coordinates.y,
                        dx: dx,
                        dy: dy
                    )
                )
            }
        }

        state.pendingEvents = remaining
    }

    private func captureCoordinates(from point: CGPoint?) -> (x: Double?, y: Double?) {
        guard let point else {
            return (nil, nil)
        }
        return (Double(point.x), Double(point.y))
    }

#if DEBUG
    func testBegin(captureWidth: Int, captureHeight: Int, mapper: CaptureCoordinateMapper?) {
        lock.withLockUnchecked { state in
            state.isRecording = true
            state.firstVideoPTS = nil
            state.lastFrameTimelineTime = nil
            state.captureWidth = captureWidth
            state.captureHeight = captureHeight
            state.mapper = mapper
            state.events = []
            state.pendingEvents = []
        }
    }

    func testInjectClick(hostTime: UInt64, globalPoint: CGPoint, button: MouseButton) {
        lock.withLockUnchecked { state in
            guard state.isRecording else {
                return
            }
            state.pendingEvents.append(
                PendingInputEvent(
                    hostTime: hostTime,
                    globalPoint: globalPoint,
                    kind: .click(button)
                )
            )
        }
    }

    func testInjectScroll(hostTime: UInt64, globalPoint: CGPoint, dx: Double, dy: Double) {
        lock.withLockUnchecked { state in
            guard state.isRecording else {
                return
            }
            state.pendingEvents.append(
                PendingInputEvent(
                    hostTime: hostTime,
                    globalPoint: globalPoint,
                    kind: .scroll(dx: dx, dy: dy)
                )
            )
        }
    }

    func testInjectVideoFrame(presentationTime: Double, hostTime: UInt64, globalPoint: CGPoint) {
        lock.withLockUnchecked { state in
            guard state.isRecording else {
                return
            }
            guard presentationTime.isFinite else {
                return
            }

            if state.firstVideoPTS == nil {
                state.firstVideoPTS = presentationTime
            }

            let base = state.firstVideoPTS ?? presentationTime
            let timelineTime = max(0, presentationTime - base)
            state.lastFrameTimelineTime = timelineTime

            let capturePoint = state.mapper?.capturePoint(from: globalPoint)
            let coordinates = captureCoordinates(from: capturePoint)
            state.events.append(
                InteractionEvent(
                    t: timelineTime,
                    type: .cursor,
                    globalX: globalPoint.x,
                    globalY: globalPoint.y,
                    captureX: coordinates.x,
                    captureY: coordinates.y
                )
            )

            flushPendingEvents(state: &state, upToHostTime: hostTime, timelineTime: timelineTime)
        }
    }

    func testFinishLog() -> InteractionEventLog {
        lock.withLockUnchecked { state in
            state.isRecording = false

            if let lastFrameTime = state.lastFrameTimelineTime {
                flushPendingEvents(state: &state, upToHostTime: .max, timelineTime: lastFrameTime)
            } else {
                state.pendingEvents.removeAll()
            }

            return InteractionEventLog(
                captureWidth: state.captureWidth,
                captureHeight: state.captureHeight,
                events: state.events
            )
        }
    }
#endif
}
