//
//  StudioRenderConfiguration.swift
//  BetterCapture
//

import Foundation
import CoreGraphics

enum StudioExportPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case source
    case hd1080
    case qhd1440
    case uhd4k

    var id: String { rawValue }

    var label: String {
        switch self {
        case .source:
            return "Source"
        case .hd1080:
            return "1080p"
        case .qhd1440:
            return "1440p"
        case .uhd4k:
            return "4K"
        }
    }

    func resolvedSize(for source: CGSize) -> CGSize {
        let safeSource = CGSize(width: max(2, source.width), height: max(2, source.height))

        guard self != .source else {
            return evenSized(safeSource)
        }

        let longEdgeTarget: Double
        switch self {
        case .source:
            longEdgeTarget = max(safeSource.width, safeSource.height)
        case .hd1080:
            longEdgeTarget = 1_920
        case .qhd1440:
            longEdgeTarget = 2_560
        case .uhd4k:
            longEdgeTarget = 3_840
        }

        let sourceLongEdge = max(safeSource.width, safeSource.height)
        let scale = longEdgeTarget / sourceLongEdge

        return evenSized(
            CGSize(
                width: safeSource.width * scale,
                height: safeSource.height * scale
            )
        )
    }

    private func evenSized(_ size: CGSize) -> CGSize {
        let width = max(2, Int(size.width.rounded()) / 2 * 2)
        let height = max(2, Int(size.height.rounded()) / 2 * 2)
        return CGSize(width: width, height: height)
    }
}

enum StudioProfilePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case demo
    case tutorial
    case speedrun

    var id: String { rawValue }

    var label: String {
        switch self {
        case .demo:
            return "Demo"
        case .tutorial:
            return "Tutorial"
        case .speedrun:
            return "Speedrun"
        }
    }
}

struct StudioRenderConfiguration: Codable, Sendable {
    var autoZoomEnabled: Bool
    var maxScale: Double
    var clickEmphasis: Double
    var smoothing: Double
    var followCursor: Bool

    var profilePreset: StudioProfilePreset
    var exportPreset: StudioExportPreset

    var clickRippleEnabled: Bool
    var cursorScaleEnabled: Bool
    var roundedCornersEnabled: Bool
    var shadowEnabled: Bool
    var backgroundBlurEnabled: Bool
}
