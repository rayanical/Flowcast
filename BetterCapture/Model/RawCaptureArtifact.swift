//
//  RawCaptureArtifact.swift
//  BetterCapture
//

import Foundation
import CoreGraphics

/// Supported raw capture scopes for studio post-processing.
enum RawCaptureMode: String, Codable, Sendable {
    case display
    case area
    case unsupported
}

/// Metadata describing a completed raw capture.
struct RawCaptureArtifact: Identifiable, Codable, Sendable {
    let id: UUID
    let rawVideoURL: URL
    let captureWidth: Int
    let captureHeight: Int
    let captureMode: RawCaptureMode
    let startedAt: Date
    let endedAt: Date
    let eventsURL: URL

    var captureSize: CGSize {
        CGSize(width: captureWidth, height: captureHeight)
    }
}
