//
//  FrameTransformer.swift
//  BetterCapture
//

@preconcurrency import AVFoundation
import CoreImage
import Foundation

protocol FrameTransformer: Sendable {
    nonisolated func transform(sourcePixelBuffer: CVPixelBuffer, cameraState: CameraState, destinationPixelBuffer: CVPixelBuffer) throws
}

struct FrameTransformerStyle: Sendable {
    var roundedCornersEnabled = false
    var shadowEnabled = false
    var backgroundBlurEnabled = false

    nonisolated init(
        roundedCornersEnabled: Bool = false,
        shadowEnabled: Bool = false,
        backgroundBlurEnabled: Bool = false
    ) {
        self.roundedCornersEnabled = roundedCornersEnabled
        self.shadowEnabled = shadowEnabled
        self.backgroundBlurEnabled = backgroundBlurEnabled
    }
}

enum FrameTransformerError: LocalizedError {
    case failedToRender
    case metalBackendUnavailable

    var errorDescription: String? {
        switch self {
        case .failedToRender:
            return "Failed to transform the current frame."
        case .metalBackendUnavailable:
            return "The Metal frame transformer is not implemented yet."
        }
    }
}

/// Core Image implementation for camera crop and zoom transforms.
final class CoreImageFrameTransformer: FrameTransformer, @unchecked Sendable {
    private let context = CIContext()
    private let outputSize: CGSize
    private let style: FrameTransformerStyle

    nonisolated init(outputSize: CGSize, style: FrameTransformerStyle = .init()) {
        self.outputSize = outputSize
        self.style = style
    }

    nonisolated func transform(sourcePixelBuffer: CVPixelBuffer, cameraState: CameraState, destinationPixelBuffer: CVPixelBuffer) throws {
        let sourceWidth = Double(CVPixelBufferGetWidth(sourcePixelBuffer))
        let sourceHeight = Double(CVPixelBufferGetHeight(sourcePixelBuffer))

        let safeScale = max(1.0, cameraState.scale)
        let cropWidth = sourceWidth / safeScale
        let cropHeight = sourceHeight / safeScale

        let clampedCenterX = min(max(cameraState.cx, cropWidth / 2), sourceWidth - cropWidth / 2)
        let clampedCenterY = min(max(cameraState.cy, cropHeight / 2), sourceHeight - cropHeight / 2)

        let cropRect = CGRect(
            x: clampedCenterX - cropWidth / 2,
            y: clampedCenterY - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        )

        let outputRect = CGRect(origin: .zero, size: outputSize)

        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)

        var image = sourceImage
            .cropped(to: cropRect)
            .transformed(by: .init(translationX: -cropRect.minX, y: -cropRect.minY))

        let scaleX = outputSize.width / cropRect.width
        let scaleY = outputSize.height / cropRect.height
        if scaleX > 1 || scaleY > 1 {
            // Use Lanczos when upscaling to preserve sharp text/edges during zoom.
            image = image.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: scaleX,
                    kCIInputAspectRatioKey: scaleY / max(scaleX, 0.000_001)
                ]
            )
        } else {
            image = image.transformed(by: .init(scaleX: scaleX, y: scaleY))
        }

        if style.roundedCornersEnabled {
            image = roundedImage(image, in: outputRect)
        }

        if style.shadowEnabled {
            let shadow = image
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35)
                    ]
                )
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.0])
                .transformed(by: .init(translationX: 0, y: -4))

            image = image.composited(over: shadow)
        }

        var background = CIImage(color: CIColor.black).cropped(to: outputRect)
        if style.backgroundBlurEnabled {
            let blurred = sourceImage
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 18.0])
                .cropped(to: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))

            let bgScaleX = outputSize.width / sourceWidth
            let bgScaleY = outputSize.height / sourceHeight

            background = blurred
                .transformed(by: .init(scaleX: bgScaleX, y: bgScaleY))
                .cropped(to: outputRect)
        }

        let composited = image.composited(over: background)
        context.render(composited, to: destinationPixelBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    nonisolated private func roundedImage(_ image: CIImage, in rect: CGRect) -> CIImage {
        let radius = min(rect.width, rect.height) * 0.04
        let maskFilter = CIFilter(
            name: "CIRoundedRectangleGenerator",
            parameters: [
                "inputExtent": CIVector(cgRect: rect),
                "inputRadius": radius,
                "inputColor": CIColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
        )

        guard let maskImage = maskFilter?.outputImage else {
            return image
        }

        let clearBackground = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        return image.applyingFilter(
            "CIBlendWithMask",
            parameters: [
                kCIInputMaskImageKey: maskImage,
                kCIInputBackgroundImageKey: clearBackground
            ]
        )
    }
}

/// Placeholder backend for future Metal implementation.
struct MetalFrameTransformer: FrameTransformer {
    nonisolated func transform(sourcePixelBuffer: CVPixelBuffer, cameraState: CameraState, destinationPixelBuffer: CVPixelBuffer) throws {
        throw FrameTransformerError.metalBackendUnavailable
    }
}
