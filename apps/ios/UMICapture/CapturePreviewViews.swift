import AVKit
import SwiftUI

struct CaptureActivityView: UIViewControllerRepresentable {
    let activityItems: [URL]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

struct RGBVideoPreviewView: View {
    let url: URL
    let shareURLs: [URL]
    let language: AppLanguage

    @State private var player: AVPlayer

    init(
        url: URL,
        shareURLs: [URL],
        language: AppLanguage
    ) {
        self.url = url
        self.shareURLs = shareURLs
        self.language = language
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .background(Color.black)
                .navigationTitle(
                    language.text("RGB Capture", "RGB 录像")
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(items: shareURLs) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel(
                            language.text(
                                "Export complete capture package",
                                "导出完整采集包"
                            )
                        )
                    }
                }
                .onAppear {
                    player.seek(to: .zero)
                    player.play()
                }
                .onDisappear {
                    player.pause()
                }
        }
    }
}

