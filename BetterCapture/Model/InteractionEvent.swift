//
//  InteractionEvent.swift
//  BetterCapture
//

import Foundation

enum InteractionEventType: String, Codable, Sendable {
    case cursor
    case click
    case scroll
}

enum MouseButton: String, Codable, Sendable {
    case left
    case right
}

/// Input event captured during recording, aligned to video timeline time (`t`).
struct InteractionEvent: Codable, Sendable {
    let t: Double
    let type: InteractionEventType
    let button: MouseButton?
    let globalX: Double
    let globalY: Double
    let captureX: Double?
    let captureY: Double?
    let dx: Double?
    let dy: Double?

    init(
        t: Double,
        type: InteractionEventType,
        button: MouseButton? = nil,
        globalX: Double,
        globalY: Double,
        captureX: Double? = nil,
        captureY: Double? = nil,
        dx: Double? = nil,
        dy: Double? = nil
    ) {
        self.t = t
        self.type = type
        self.button = button
        self.globalX = globalX
        self.globalY = globalY
        self.captureX = captureX
        self.captureY = captureY
        self.dx = dx
        self.dy = dy
    }
}

/// Sidecar event file written next to raw recordings.
struct InteractionEventLog: Codable, Sendable {
    let version: Int
    let captureWidth: Int
    let captureHeight: Int
    let events: [InteractionEvent]

    init(version: Int = 1, captureWidth: Int, captureHeight: Int, events: [InteractionEvent]) {
        self.version = version
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.events = events
    }
}
