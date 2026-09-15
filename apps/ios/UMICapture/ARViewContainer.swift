import SwiftUI

struct ARViewContainer: UIViewControllerRepresentable {

    @ObservedObject var viewController: ViewController

    func makeUIViewController(context: Context) -> ViewController {
        return self.viewController
    }

    func updateUIViewController(_ uiViewController: ViewController, context: Context) {
    }
}


