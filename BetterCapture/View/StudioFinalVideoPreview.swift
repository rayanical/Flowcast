//
//  StudioFinalVideoPreview.swift
//  BetterCapture
//

@preconcurrency import AVKit
import SwiftUI

struct StudioFinalVideoPreview: View {
    let url: URL

    @State private var player: AVPlayer?
    @State private var currentURL: URL?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .clipShape(.rect(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .onAppear {
            loadPlayerIfNeeded(for: url)
        }
        .onChange(of: url) { _, newURL in
            loadPlayerIfNeeded(for: newURL)
        }
    }

    private func loadPlayerIfNeeded(for url: URL) {
        guard currentURL != url else {
            return
        }

        currentURL = url
        player = AVPlayer(url: url)
    }
}

#Preview {
    StudioFinalVideoPreview(url: URL(filePath: "/tmp/sample.final.mov"))
        .frame(width: 480)
        .padding()
}
