//
//  CameraPreviewView.swift
//  BetterCapture
//

import SwiftUI

struct CameraPreviewView: View {
    @Bindable var coordinator: StudioExportCoordinator
    @Bindable var settings: SettingsStore

    private var refreshToken: Int {
        var hasher = Hasher()
        hasher.combine(settings.autoZoomEnabled)
        hasher.combine(settings.autoZoomMaxScale)
        hasher.combine(settings.clickEmphasis)
        hasher.combine(settings.cameraSmoothing)
        hasher.combine(settings.followCursor)
        hasher.combine(settings.studioProfilePreset)
        hasher.combine(settings.studioExportPreset)
        hasher.combine(settings.studioClickRipple)
        hasher.combine(settings.studioCursorScale)
        hasher.combine(settings.studioRoundedCorners)
        hasher.combine(settings.studioShadow)
        hasher.combine(settings.studioBackgroundBlur)
        return hasher.finalize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Camera Preview")
                .font(.headline)

            Group {
                if let image = coordinator.previewEngine.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                        .overlay {
                            Text("No preview yet")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)

            HStack {
                Button("Refresh Preview") {
                    coordinator.refreshPreview()
                }
                .disabled(!coordinator.canExportLastRaw)

                Button("Stop Preview") {
                    coordinator.previewEngine.stopPreview()
                }

                Spacer()

                if coordinator.previewEngine.isRendering {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let message = coordinator.previewEngine.lastErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: refreshToken) { _, _ in
            coordinator.refreshPreview()
        }
        .onChange(of: coordinator.lastRawArtifact?.id) { _, _ in
            coordinator.refreshPreview()
        }
    }
}

#Preview {
    CameraPreviewView(
        coordinator: StudioExportCoordinator(settings: SettingsStore()),
        settings: SettingsStore()
    )
    .frame(width: 480)
    .padding()
}
