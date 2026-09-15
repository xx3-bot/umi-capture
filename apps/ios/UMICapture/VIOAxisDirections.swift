import CoreGraphics

struct VIOAxisDirection: Equatable {
    let horizontal: CGFloat
    let vertical: CGFloat
    let depth: CGFloat
}

struct VIOAxisDirections: Equatable {
    let x: VIOAxisDirection
    let y: VIOAxisDirection
    let z: VIOAxisDirection
}

