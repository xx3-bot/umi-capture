import Foundation
import SwiftUI
import simd

struct TrajectoryPlot3D: View {
    let samples: [TrajectoryPoseSample]
    let yaw: CGFloat
    let pitch: CGFloat
    let visibleSampleCount: Int?
    let playbackHeadSample: TrajectoryPoseSample?
    let startLabel: String
    let endLabel: String

    init(
        samples: [TrajectoryPoseSample],
        yaw: CGFloat,
        pitch: CGFloat,
        visibleSampleCount: Int? = nil,
        playbackHeadSample: TrajectoryPoseSample? = nil,
        startLabel: String = "START",
        endLabel: String = "END"
    ) {
        self.samples = samples
        self.yaw = yaw
        self.pitch = pitch
        self.visibleSampleCount = visibleSampleCount
        self.playbackHeadSample = playbackHeadSample
        self.startLabel = startLabel
        self.endLabel = endLabel
    }

    var body: some View {
        Canvas { context, size in
            let layout = makeLayout(size: size)
            drawGrid(layout: layout, context: &context)
            drawAxes(layout: layout, context: &context)
            drawTrajectory(layout: layout, context: &context)
            drawScale(layout: layout, context: &context)
        }
        .drawingGroup()
    }

    private struct Layout {
        let center: SIMD3<Double>
        let plotExtent: Double
        let scale: CGFloat
        let screenCenter: CGPoint
        let size: CGSize
    }

    private var presentationMath: TrajectoryPresentationMath {
        TrajectoryPresentationMath(yaw: yaw, pitch: pitch)
    }

    private func makeLayout(size: CGSize) -> Layout {
        var minimum = SIMD3<Double>(
            repeating: .greatestFiniteMagnitude
        )
        var maximum = SIMD3<Double>(
            repeating: -.greatestFiniteMagnitude
        )

        for sample in samples {
            let value = plotPoint(sample.position)
            minimum = simd_min(minimum, value)
            maximum = simd_max(maximum, value)
        }

        minimum = simd_min(minimum, .zero)
        maximum = simd_max(maximum, .zero)
        let center = (minimum + maximum) / 2
        let spans = maximum - minimum
        let plotExtent = max(
            0.5,
            max(spans.x, max(spans.y, spans.z)) * 1.3
        )

        let candidates = [
            SIMD3<Double>(-plotExtent / 2, -plotExtent / 2, 0),
            SIMD3<Double>(plotExtent / 2, -plotExtent / 2, 0),
            SIMD3<Double>(-plotExtent / 2, plotExtent / 2, 0),
            SIMD3<Double>(plotExtent / 2, plotExtent / 2, 0),
            SIMD3<Double>(0, 0, plotExtent / 2),
            SIMD3<Double>(0, 0, -plotExtent / 2)
        ].map { rotate($0) }

        let minScreenX = candidates.map(\.x).min() ?? -1
        let maxScreenX = candidates.map(\.x).max() ?? 1
        let minScreenY = candidates.map(\.y).min() ?? -1
        let maxScreenY = candidates.map(\.y).max() ?? 1
        let horizontalSpan = max(maxScreenX - minScreenX, 0.1)
        let verticalSpan = max(maxScreenY - minScreenY, 0.1)
        let scale = min(
            (size.width - 34) / CGFloat(horizontalSpan),
            (size.height - 42) / CGFloat(verticalSpan)
        )

        return Layout(
            center: center,
            plotExtent: plotExtent,
            scale: scale,
            screenCenter: CGPoint(
                x: size.width / 2,
                y: size.height / 2
            ),
            size: size
        )
    }

    private func drawGrid(
        layout: Layout,
        context: inout GraphicsContext
    ) {
        let half = layout.plotExtent / 2
        let divisions = 6
        let gridZ = -layout.center.z

        for index in 0...divisions {
            let fraction = Double(index) / Double(divisions)
            let offset = -half + layout.plotExtent * fraction

            var xLine = Path()
            xLine.move(
                to: project(
                    SIMD3<Double>(-half, offset, gridZ),
                    layout: layout
                )
            )
            xLine.addLine(
                to: project(
                    SIMD3<Double>(half, offset, gridZ),
                    layout: layout
                )
            )
            context.stroke(
                xLine,
                with: .color(.white.opacity(0.12)),
                lineWidth: 1
            )

            var yLine = Path()
            yLine.move(
                to: project(
                    SIMD3<Double>(offset, -half, gridZ),
                    layout: layout
                )
            )
            yLine.addLine(
                to: project(
                    SIMD3<Double>(offset, half, gridZ),
                    layout: layout
                )
            )
            context.stroke(
                yLine,
                with: .color(.white.opacity(0.12)),
                lineWidth: 1
            )
        }
    }

    private func drawAxes(
        layout: Layout,
        context: inout GraphicsContext
    ) {
        let length = layout.plotExtent * 0.32
        let origin = -layout.center
        drawArrow(
            from: origin,
            to: origin + SIMD3<Double>(length, 0, 0),
            color: .red,
            label: "X",
            layout: layout,
            context: &context
        )
        drawArrow(
            from: origin,
            to: origin + SIMD3<Double>(0, length, 0),
            color: .green,
            label: "Y",
            layout: layout,
            context: &context
        )
        drawArrow(
            from: origin,
            to: origin + SIMD3<Double>(0, 0, length),
            color: .blue,
            label: "Z",
            layout: layout,
            context: &context
        )
    }

    private func drawArrow(
        from start: SIMD3<Double>,
        to end: SIMD3<Double>,
        color: Color,
        label: String,
        layout: Layout,
        context: inout GraphicsContext
    ) {
        let startPoint = project(start, layout: layout)
        let endPoint = project(end, layout: layout)
        var path = Path()
        path.move(to: startPoint)
        path.addLine(to: endPoint)
        context.stroke(
            path,
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )

        context.draw(
            Text(label)
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(color),
            at: CGPoint(x: endPoint.x + 8, y: endPoint.y - 8)
        )
    }

    private func drawTrajectory(
        layout: Layout,
        context: inout GraphicsContext
    ) {
        var visibleSamples = Array(
            samples.prefix(
                max(
                    0,
                    min(
                        visibleSampleCount ?? samples.count,
                        samples.count
                    )
                )
            )
        )
        if let playbackHeadSample {
            visibleSamples.append(playbackHeadSample)
        }
        guard let first = visibleSamples.first else {
            return
        }

        var path = Path()
        path.move(
            to: project(
                plotPoint(first.position) - layout.center,
                layout: layout
            )
        )

        for sample in visibleSamples.dropFirst() {
            path.addLine(
                to: project(
                    plotPoint(sample.position) - layout.center,
                    layout: layout
                )
            )
        }

        context.stroke(
            path,
            with: .color(.cyan),
            style: StrokeStyle(
                lineWidth: 3,
                lineCap: .round,
                lineJoin: .round
            )
        )

        drawPoseArrows(
            samples: visibleSamples,
            layout: layout,
            context: &context
        )

        let start = project(
            plotPoint(first.position) - layout.center,
            layout: layout
        )
        let current = project(
            plotPoint(
                visibleSamples.last?.position ?? first.position
            ) - layout.center,
            layout: layout
        )
        let final = project(
            plotPoint(samples.last?.position ?? first.position)
                - layout.center,
            layout: layout
        )
        let isComplete =
            (visibleSampleCount ?? samples.count) >= samples.count
            && playbackHeadSample == nil
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: start.x - 4,
                    y: start.y - 4,
                    width: 8,
                    height: 8
                )
            ),
            with: .color(.green)
        )
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: current.x - 5,
                    y: current.y - 5,
                    width: 10,
                    height: 10
                )
            ),
            with: .color(.orange)
        )

        if !isComplete {
            context.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: final.x - 6,
                        y: final.y - 6,
                        width: 12,
                        height: 12
                    )
                ),
                with: .color(.orange.opacity(0.55)),
                lineWidth: 2
            )
        }

        context.draw(
            Text(startLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.green),
            at: CGPoint(x: start.x, y: start.y - 12)
        )
        context.draw(
            Text(endLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.orange),
            at: CGPoint(x: final.x, y: final.y - 13)
        )
    }

    private func drawPoseArrows(
        samples: [TrajectoryPoseSample],
        layout: Layout,
        context: inout GraphicsContext
    ) {
        guard !samples.isEmpty else {
            return
        }

        let targetArrowCount = 16
        let stride = max(
            1,
            Int(ceil(Double(samples.count) / Double(targetArrowCount)))
        )
        var indices = Array(
            Swift.stride(
                from: 0,
                to: samples.count,
                by: stride
            )
        )
        if indices.last != samples.count - 1 {
            indices.append(samples.count - 1)
        }

        let arrowLength = max(0.06, layout.plotExtent * 0.055)
        for index in indices {
            let sample = samples[index]
            drawPoseMarker(
                sample: sample,
                length: arrowLength,
                isCurrent: index == samples.count - 1,
                layout: layout,
                context: &context
            )
        }
    }

    private func drawPoseMarker(
        sample: TrajectoryPoseSample,
        length: Double,
        isCurrent: Bool,
        layout: Layout,
        context: inout GraphicsContext
    ) {
        let start3D = plotPoint(sample.position) - layout.center
        if let orientation = sample.orientationXYZW {
            let rotation = simd_float3x3(
                simd_normalize(simd_quatf(vector: orientation))
            )
            let axes: [(SIMD3<Float>, Color)] = [
                (rotation.columns.0, .red),
                (rotation.columns.1, .green),
                (rotation.columns.2, .blue)
            ]
            for (axis, color) in axes {
                drawPoseAxis(
                    from: start3D,
                    direction: plotPoint(axis),
                    length: length,
                    color: color,
                    isCurrent: isCurrent,
                    layout: layout,
                    context: &context
                )
            }
            return
        }

        drawPoseAxis(
            from: start3D,
            direction: plotPoint(sample.cameraForward),
            length: length,
            color: isCurrent ? .orange : .white,
            isCurrent: isCurrent,
            layout: layout,
            context: &context
        )
    }

    private func drawPoseAxis(
        from start3D: SIMD3<Double>,
        direction direction3D: SIMD3<Double>,
        length: Double,
        color: Color,
        isCurrent: Bool,
        layout: Layout,
        context: inout GraphicsContext
    ) {
        let end3D = start3D + direction3D * length
        let start = project(start3D, layout: layout)
        let end = project(end3D, layout: layout)
        let screenDirection = CGVector(
            dx: end.x - start.x,
            dy: end.y - start.y
        )
        let screenLength = hypot(
            screenDirection.dx,
            screenDirection.dy
        )
        if screenLength < 4 {
            drawDepthMarker(
                at: start,
                pointsTowardViewer: rotate(direction3D).z > 0,
                color: color,
                context: &context
            )
            return
        }

        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: end)
        context.stroke(
            shaft,
            with: .color(color.opacity(isCurrent ? 1 : 0.78)),
            style: StrokeStyle(
                lineWidth: isCurrent ? 2.4 : 1.6,
                lineCap: .round
            )
        )

        let unit = CGVector(
            dx: screenDirection.dx / screenLength,
            dy: screenDirection.dy / screenLength
        )
        let perpendicular = CGVector(dx: -unit.dy, dy: unit.dx)
        let headLength: CGFloat = isCurrent ? 8 : 6
        let headWidth: CGFloat = isCurrent ? 4.5 : 3.5
        let base = CGPoint(
            x: end.x - unit.dx * headLength,
            y: end.y - unit.dy * headLength
        )
        var head = Path()
        head.move(to: end)
        head.addLine(
            to: CGPoint(
                x: base.x + perpendicular.dx * headWidth,
                y: base.y + perpendicular.dy * headWidth
            )
        )
        head.addLine(
            to: CGPoint(
                x: base.x - perpendicular.dx * headWidth,
                y: base.y - perpendicular.dy * headWidth
            )
        )
        head.closeSubpath()
        context.fill(
            head,
            with: .color(color.opacity(isCurrent ? 1 : 0.85))
        )
    }

    private func drawDepthMarker(
        at point: CGPoint,
        pointsTowardViewer: Bool,
        color: Color,
        context: inout GraphicsContext
    ) {
        let markerRect = CGRect(
            x: point.x - 4,
            y: point.y - 4,
            width: 8,
            height: 8
        )
        context.stroke(
            Path(ellipseIn: markerRect),
            with: .color(color.opacity(0.85)),
            lineWidth: 1.5
        )

        if pointsTowardViewer {
            context.fill(
                Path(
                    ellipseIn: CGRect(
                        x: point.x - 1.5,
                        y: point.y - 1.5,
                        width: 3,
                        height: 3
                    )
                ),
                with: .color(color)
            )
        } else {
            var cross = Path()
            cross.move(
                to: CGPoint(x: point.x - 2.5, y: point.y - 2.5)
            )
            cross.addLine(
                to: CGPoint(x: point.x + 2.5, y: point.y + 2.5)
            )
            cross.move(
                to: CGPoint(x: point.x + 2.5, y: point.y - 2.5)
            )
            cross.addLine(
                to: CGPoint(x: point.x - 2.5, y: point.y + 2.5)
            )
            context.stroke(
                cross,
                with: .color(color),
                lineWidth: 1.2
            )
        }
    }

    private func drawScale(
        layout: Layout,
        context: inout GraphicsContext
    ) {
        let target = CGFloat(layout.plotExtent / 4)
        let scaleLength = niceLength(target)
        let pixelLength = scaleLength * layout.scale
        let start = CGPoint(
            x: 16,
            y: layout.size.height - 18
        )
        let end = CGPoint(
            x: start.x + pixelLength,
            y: start.y
        )
        var bar = Path()
        bar.move(to: start)
        bar.addLine(to: end)
        context.stroke(
            bar,
            with: .color(.white.opacity(0.85)),
            lineWidth: 2
        )
        context.draw(
            Text(formatScale(scaleLength))
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.85)),
            at: CGPoint(
                x: start.x + pixelLength / 2,
                y: start.y - 9
            )
        )
    }

    private func project(
        _ point: SIMD3<Double>,
        layout: Layout
    ) -> CGPoint {
        presentationMath.project(
            point,
            screenCenter: layout.screenCenter,
            scale: layout.scale
        )
    }

    private func rotate(
        _ point: SIMD3<Double>
    ) -> SIMD3<Double> {
        presentationMath.rotate(point)
    }

    private func plotPoint(
        _ point: SIMD3<Float>
    ) -> SIMD3<Double> {
        presentationMath.plotPoint(point)
    }

    private func niceLength(_ value: CGFloat) -> CGFloat {
        guard value > 0 else {
            return 0.1
        }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let niceFraction: CGFloat
        if fraction < 1.5 {
            niceFraction = 1
        } else if fraction < 3.5 {
            niceFraction = 2
        } else if fraction < 7.5 {
            niceFraction = 5
        } else {
            niceFraction = 10
        }
        return niceFraction * base
    }

    private func formatScale(_ value: CGFloat) -> String {
        if value >= 1 {
            return String(format: "%.0f m", value)
        }
        return String(format: "%.0f cm", value * 100)
    }
}
