import SwiftUI

struct VIOAxesOverlay: View {
    let axes: VIOAxisDirections

    var body: some View {
        VStack(spacing: 2) {
            Text("VIO FRAME")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            Canvas { context, size in
                let origin = CGPoint(
                    x: size.width / 2,
                    y: size.height / 2
                )

                drawAxis(
                    axes.x,
                    color: .red,
                    label: "X",
                    origin: origin,
                    context: &context
                )
                drawAxis(
                    axes.y,
                    color: .green,
                    label: "Y",
                    origin: origin,
                    context: &context
                )
                drawAxis(
                    axes.z,
                    color: .blue,
                    label: "Z",
                    origin: origin,
                    context: &context
                )

                let center = Path(
                    ellipseIn: CGRect(
                        x: origin.x - 2,
                        y: origin.y - 2,
                        width: 4,
                        height: 4
                    )
                )
                context.fill(center, with: .color(.white))
            }
            .frame(width: 108, height: 88)

            Text("● toward  × away")
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
    }

    private func drawAxis(
        _ axis: VIOAxisDirection,
        color: Color,
        label: String,
        origin: CGPoint,
        context: inout GraphicsContext
    ) {
        let scale: CGFloat = 36
        let endpoint = CGPoint(
            x: origin.x + axis.horizontal * scale,
            y: origin.y + axis.vertical * scale
        )
        let projectedLength = hypot(
            endpoint.x - origin.x,
            endpoint.y - origin.y
        )

        if projectedLength > 4 {
            var shaft = Path()
            shaft.move(to: origin)
            shaft.addLine(to: endpoint)
            context.stroke(
                shaft,
                with: .color(color),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )

            let unitX = (endpoint.x - origin.x) / projectedLength
            let unitY = (endpoint.y - origin.y) / projectedLength
            let perpendicularX = -unitY
            let perpendicularY = unitX
            let arrowLength: CGFloat = 8
            let arrowWidth: CGFloat = 4

            var arrowHead = Path()
            arrowHead.move(to: endpoint)
            arrowHead.addLine(
                to: CGPoint(
                    x: endpoint.x - unitX * arrowLength
                        + perpendicularX * arrowWidth,
                    y: endpoint.y - unitY * arrowLength
                        + perpendicularY * arrowWidth
                )
            )
            arrowHead.addLine(
                to: CGPoint(
                    x: endpoint.x - unitX * arrowLength
                        - perpendicularX * arrowWidth,
                    y: endpoint.y - unitY * arrowLength
                        - perpendicularY * arrowWidth
                )
            )
            arrowHead.closeSubpath()
            context.fill(arrowHead, with: .color(color))
        }

        if abs(axis.depth) > 0.55 {
            drawDepthMarker(
                at: endpoint,
                towardViewer: axis.depth > 0,
                color: color,
                context: &context
            )
        }

        let labelOffsetX: CGFloat
        let labelOffsetY: CGFloat
        if projectedLength > 4 {
            labelOffsetX = (endpoint.x - origin.x) / projectedLength * 10
            labelOffsetY = (endpoint.y - origin.y) / projectedLength * 10
        } else {
            labelOffsetX = 10
            labelOffsetY = -10
        }

        context.draw(
            Text(label)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(color),
            at: CGPoint(
                x: endpoint.x + labelOffsetX,
                y: endpoint.y + labelOffsetY
            )
        )
    }

    private func drawDepthMarker(
        at center: CGPoint,
        towardViewer: Bool,
        color: Color,
        context: inout GraphicsContext
    ) {
        let radius: CGFloat = 5
        let circle = Path(
            ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        context.stroke(circle, with: .color(color), lineWidth: 2)

        if towardViewer {
            let dot = Path(
                ellipseIn: CGRect(
                    x: center.x - 1.8,
                    y: center.y - 1.8,
                    width: 3.6,
                    height: 3.6
                )
            )
            context.fill(dot, with: .color(color))
        } else {
            var cross = Path()
            cross.move(
                to: CGPoint(x: center.x - 3, y: center.y - 3)
            )
            cross.addLine(
                to: CGPoint(x: center.x + 3, y: center.y + 3)
            )
            cross.move(
                to: CGPoint(x: center.x + 3, y: center.y - 3)
            )
            cross.addLine(
                to: CGPoint(x: center.x - 3, y: center.y + 3)
            )
            context.stroke(
                cross,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
            )
        }
    }
}


