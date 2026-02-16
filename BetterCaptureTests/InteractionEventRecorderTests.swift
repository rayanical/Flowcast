//
//  InteractionEventRecorderTests.swift
//  BetterCaptureTests
//

import Foundation
import Testing
@testable import BetterCapture

struct InteractionEventRecorderTests {
    @Test
    func interactionEventLogRoundTripsWithDualCoordinates() throws {
        let events = [
            InteractionEvent(
                t: 0.016,
                type: .cursor,
                globalX: 1_700,
                globalY: 980,
                captureX: 1_023,
                captureY: 612
            ),
            InteractionEvent(
                t: 1.402,
                type: .click,
                button: .left,
                globalX: 1_512,
                globalY: 886,
                captureX: 820,
                captureY: 520
            ),
            InteractionEvent(
                t: 2.100,
                type: .scroll,
                globalX: 1_512,
                globalY: 886,
                captureX: nil,
                captureY: nil,
                dx: 0,
                dy: -34
            )
        ]

        let log = InteractionEventLog(captureWidth: 1_920, captureHeight: 1_080, events: events)
        let encoded = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(InteractionEventLog.self, from: encoded)

        #expect(decoded.version == 1)
        #expect(decoded.captureWidth == 1_920)
        #expect(decoded.captureHeight == 1_080)
        #expect(decoded.events.count == 3)

        #expect(decoded.events[0].type == .cursor)
        #expect(decoded.events[0].captureX == 1_023)
        #expect(decoded.events[0].captureY == 612)

        #expect(decoded.events[2].type == .scroll)
        #expect(decoded.events[2].captureX == nil)
        #expect(decoded.events[2].captureY == nil)
        #expect(decoded.events[2].dy == -34)
    }

    @Test
    func recorderAlignsClickAndScrollToNextVideoFrameTimebase() {
        let mapper = CaptureCoordinateMapper(
            globalRect: CGRect(x: 100, y: 100, width: 1_000, height: 500),
            captureWidth: 1_920,
            captureHeight: 1_080
        )

        let recorder = InteractionEventRecorder()
        recorder.testBegin(captureWidth: 1_920, captureHeight: 1_080, mapper: mapper)

        recorder.testInjectVideoFrame(
            presentationTime: 10.000,
            hostTime: 1_000,
            globalPoint: CGPoint(x: 250, y: 250)
        )

        recorder.testInjectClick(
            hostTime: 1_010,
            globalPoint: CGPoint(x: 400, y: 300),
            button: .left
        )
        recorder.testInjectScroll(
            hostTime: 1_020,
            globalPoint: CGPoint(x: 420, y: 320),
            dx: 0,
            dy: -34
        )

        recorder.testInjectVideoFrame(
            presentationTime: 10.016,
            hostTime: 1_030,
            globalPoint: CGPoint(x: 260, y: 260)
        )
        recorder.testInjectVideoFrame(
            presentationTime: 10.033,
            hostTime: 1_040,
            globalPoint: CGPoint(x: 270, y: 270)
        )

        let log = recorder.testFinishLog()

        let times = log.events.map(\.t)
        #expect(times == times.sorted())

        let clicks = log.events.filter { $0.type == .click }
        let scrolls = log.events.filter { $0.type == .scroll }
        #expect(clicks.count == 1)
        #expect(scrolls.count == 1)
        #expect(clicks[0].t == 0.016)
        #expect(scrolls[0].t == 0.016)

        #expect(clicks[0].captureX != nil)
        #expect(clicks[0].captureY != nil)
        #expect(scrolls[0].captureX != nil)
        #expect(scrolls[0].captureY != nil)
    }

    @Test
    func recorderSupportsUnsupportedModeWithGlobalCoordinatesOnly() {
        let recorder = InteractionEventRecorder()
        recorder.testBegin(captureWidth: 1_920, captureHeight: 1_080, mapper: nil)

        recorder.testInjectVideoFrame(
            presentationTime: 1.000,
            hostTime: 100,
            globalPoint: CGPoint(x: 50, y: 60)
        )
        recorder.testInjectClick(
            hostTime: 101,
            globalPoint: CGPoint(x: 70, y: 80),
            button: .right
        )
        recorder.testInjectVideoFrame(
            presentationTime: 1.017,
            hostTime: 102,
            globalPoint: CGPoint(x: 90, y: 100)
        )

        let log = recorder.testFinishLog()
        let click = log.events.first { $0.type == .click }

        #expect(click != nil)
        #expect(click?.globalX == 70)
        #expect(click?.globalY == 80)
        #expect(click?.captureX == nil)
        #expect(click?.captureY == nil)
    }
}
