import MacFleetState
import SwiftUI

/// Draws a fixed-height history with one `Canvas` pass per series. Gaps (unavailable samples) break the
/// line instead of dropping to zero. Redraws only when the presentation value changes.
struct SparklineChart: View {
    let chart: ChartPresentation

    var body: some View {
        Canvas { context, size in
            drawMidline(in: &context, size: size)
            for series in chart.series {
                draw(series, in: &context, size: size)
            }
        }
        .frame(height: 56)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chart.title)
        .accessibilityValue(chart.spokenSummary)
    }

    private func drawMidline(in context: inout GraphicsContext, size: CGSize) {
        var midline = Path()
        midline.move(to: CGPoint(x: 0, y: size.height / 2))
        midline.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        context.stroke(
            midline,
            with: .color(Color.secondary.opacity(0.35)),
            style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
        )
    }

    private func draw(_ series: ChartSeries, in context: inout GraphicsContext, size: CGSize) {
        let count = series.samples.count
        guard count > 0 else { return }
        var path = Path()
        var penDown = false
        for (index, sample) in series.samples.enumerated() {
            guard let sample else {
                penDown = false
                continue
            }
            let x = size.width * CGFloat(index) / CGFloat(max(count - 1, 1))
            let fraction = CGFloat(min(sample / chart.ceiling, 1))
            let point = CGPoint(x: x, y: size.height * (1 - fraction))
            if penDown {
                path.addLine(to: point)
            } else {
                path.move(to: point)
            }
            penDown = true
        }
        context.stroke(
            path,
            with: .color(series.role.color),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }
}
