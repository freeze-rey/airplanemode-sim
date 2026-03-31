import SwiftUI

/// A sparkline chart with idle-gap detection and hover tooltips.
/// Breaks the line at idle segments and shows value at hovered point.
struct SparklineView: View {
    let values: [Double]
    let isIdle: [Bool]
    let maxValue: Double?
    let color: Color
    let referenceValue: Double?
    let valueFormatter: (Double) -> String

    @State private var hoverIndex: Int?

    init(
        values: [Double],
        isIdle: [Bool] = [],
        maxValue: Double? = nil,
        color: Color = .blue,
        referenceValue: Double? = nil,
        valueFormatter: @escaping (Double) -> String = { "\(Int($0))" }
    ) {
        self.values = values
        self.isIdle = isIdle
        self.maxValue = maxValue
        self.color = color
        self.referenceValue = referenceValue
        self.valueFormatter = valueFormatter
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let effectiveMax = maxValue ?? values.max() ?? 1
            let clampedMax = Swift.max(effectiveMax, 1)
            let points = chartPoints(in: size, max: clampedMax)

            ZStack(alignment: .topLeading) {
                // Reference line (dashed)
                if let ref = referenceValue, clampedMax > 0 {
                    let refY = size.height * (1 - ref / clampedMax)
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: refY))
                        path.addLine(to: CGPoint(x: size.width, y: refY))
                    }
                    .stroke(color.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }

                if points.count >= 2 {
                    // Filled area (active segments only)
                    filledPath(points: points, size: size)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.3), color.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    // Active stroke
                    strokePath(points: points, idle: false)
                        .stroke(color, lineWidth: 1.5)

                    // Idle stroke (dashed, dimmed)
                    strokePath(points: points, idle: true)
                        .stroke(color.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                // Hover crosshair + tooltip
                if let idx = hoverIndex, idx < points.count, idx < values.count {
                    let pt = points[idx]

                    // Vertical line
                    Path { path in
                        path.move(to: CGPoint(x: pt.x, y: 0))
                        path.addLine(to: CGPoint(x: pt.x, y: size.height))
                    }
                    .stroke(color.opacity(0.5), lineWidth: 1)

                    // Dot
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .position(pt)

                    // Value label
                    let label = valueFormatter(values[idx])
                    let labelX = pt.x > size.width - 40 ? pt.x - 30 : pt.x + 8
                    let labelY = Swift.max(10, Swift.min(size.height - 10, pt.y - 10))
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .position(x: labelX, y: labelY)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard values.count >= 2 else { hoverIndex = nil; return }
                    let stepX = size.width / CGFloat(values.count - 1)
                    let rawIndex = Int(round(location.x / stepX))
                    hoverIndex = Swift.max(0, Swift.min(values.count - 1, rawIndex))
                case .ended:
                    hoverIndex = nil
                @unknown default:
                    hoverIndex = nil
                }
            }
        }
    }

    // MARK: - Path builders

    /// Segments of consecutive points, split at idle boundaries.
    private struct Segment {
        let startIndex: Int
        let points: [CGPoint]
        let idle: Bool
    }

    private func segments(from points: [CGPoint]) -> [Segment] {
        guard !points.isEmpty else { return [] }
        var result: [Segment] = []
        var currentStart = 0
        var currentPoints: [CGPoint] = [points[0]]
        var currentIdle = isIdle.isEmpty ? false : isIdle[0]

        for i in 1..<points.count {
            let pointIdle = i < isIdle.count ? isIdle[i] : false
            if pointIdle != currentIdle {
                // Close current segment with overlap point for continuity
                result.append(Segment(startIndex: currentStart, points: currentPoints, idle: currentIdle))
                currentStart = i - 1
                currentPoints = [points[i - 1], points[i]]
                currentIdle = pointIdle
            } else {
                currentPoints.append(points[i])
            }
        }
        result.append(Segment(startIndex: currentStart, points: currentPoints, idle: currentIdle))
        return result
    }

    /// Filled area path (only active segments).
    private func filledPath(points: [CGPoint], size: CGSize) -> Path {
        Path { path in
            for seg in segments(from: points) where !seg.idle {
                guard let first = seg.points.first, let last = seg.points.last else { continue }
                path.move(to: CGPoint(x: first.x, y: size.height))
                path.addLine(to: first)
                for pt in seg.points.dropFirst() {
                    path.addLine(to: pt)
                }
                path.addLine(to: CGPoint(x: last.x, y: size.height))
                path.closeSubpath()
            }
        }
    }

    /// Stroke path for either active or idle segments.
    private func strokePath(points: [CGPoint], idle: Bool) -> Path {
        Path { path in
            for seg in segments(from: points) where seg.idle == idle {
                guard let first = seg.points.first else { continue }
                path.move(to: first)
                for pt in seg.points.dropFirst() {
                    path.addLine(to: pt)
                }
            }
        }
    }

    /// Maps values to CGPoints within the given size.
    private func chartPoints(in size: CGSize, max: Double) -> [CGPoint] {
        guard values.count >= 2 else { return [] }
        let count = values.count
        let stepX = size.width / CGFloat(count - 1)

        return values.enumerated().map { index, value in
            let x = CGFloat(index) * stepX
            let normalizedY = CGFloat(value / max)
            let y = size.height * (1 - normalizedY)
            return CGPoint(x: x, y: Swift.max(0, Swift.min(size.height, y)))
        }
    }
}
