import APOEngine
import SwiftUI

enum BandPalette {
    private static let colors: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .mint, .indigo, .brown, .cyan]

    static func color(_ index: Int) -> Color {
        colors[((index % colors.count) + colors.count) % colors.count]
    }
}

/// Maps between frequency/dB and view coordinates.
struct GraphGeometry {
    static let minimumFrequency = 20.0
    static let maximumFrequency = 20_000.0
    static let insets = EdgeInsets(top: 10, leading: 36, bottom: 22, trailing: 12)

    let plot: CGRect
    let range: Double

    init(size: CGSize, range: Double) {
        plot = CGRect(
            x: Self.insets.leading,
            y: Self.insets.top,
            width: max(1, size.width - Self.insets.leading - Self.insets.trailing),
            height: max(1, size.height - Self.insets.top - Self.insets.bottom)
        )
        self.range = range
    }

    func x(_ frequency: Double) -> CGFloat {
        let position = log(frequency / Self.minimumFrequency) / log(Self.maximumFrequency / Self.minimumFrequency)
        return plot.minX + plot.width * CGFloat(position)
    }

    func y(_ decibels: Double) -> CGFloat {
        plot.minY + plot.height * CGFloat((range - decibels) / (2 * range))
    }

    func frequency(atX x: CGFloat) -> Double {
        let position = Double((x - plot.minX) / plot.width)
        return Self.minimumFrequency * pow(Self.maximumFrequency / Self.minimumFrequency, position)
    }

    func decibels(atY y: CGFloat) -> Double {
        range - Double((y - plot.minY) / plot.height) * 2 * range
    }
}

struct ResponseGraphView: View {
    let responses: [[APOFrequencyResponsePoint]]
    let channelNames: [String]
    let filters: [EditableFilter]
    let selectedFilterID: UUID?
    let isBypassed: Bool
    let isEditable: Bool
    let onSelect: (UUID) -> Void
    let onDrag: (_ filter: EditableFilter, _ frequency: Double, _ gainDB: Double, _ isFirstChange: Bool) -> Void
    let onAdd: (_ frequency: Double, _ gainDB: Double) -> Void

    @State private var hoverLocation: CGPoint?
    @State private var draggingFilterID: UUID?

    /// Preamp gain applied on top of every band; handles are drawn at
    /// band gain + preamp so they sit on the curve.
    private var gainOffset: Double {
        filters.filter { $0.kind == .preamp }.map(\.gainDB).reduce(0, +)
    }

    private var bands: [(number: Int, filter: EditableFilter)] {
        filters.filter(\.kind.isBand).enumerated().map { ($0.offset + 1, $0.element) }
    }

    private var channelsDiffer: Bool {
        guard responses.count > 1, let first = responses.first else { return false }
        return responses.dropFirst().contains { other in
            zip(first, other).contains { abs($0.magnitudeDB - $1.magnitudeDB) > 0.01 }
        }
    }

    private var range: Double {
        let responseExtreme = responses.flatMap { $0.map { abs($0.magnitudeDB) } }.max() ?? 0
        let bandExtreme = bands.filter { $0.filter.kind.supportsGain }.map { abs($0.filter.gainDB + gainOffset) }.max() ?? 0
        let extreme = max(responseExtreme, bandExtreme)
        for candidate in [12.0, 18, 24, 30] where extreme <= candidate - 1 { return candidate }
        return 36
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = GraphGeometry(size: proxy.size, range: range)
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawGrid(in: &context, geometry: geometry)
                    drawCurves(in: &context, geometry: geometry)
                    drawHover(in: &context, geometry: geometry)
                }
                if isEditable {
                    ForEach(bands, id: \.filter.id) { band in
                        handle(for: band.filter, number: band.number, geometry: geometry)
                    }
                }
                overlayLabels(geometry: geometry)
            }
            .coordinateSpace(.named("graph"))
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .named("graph")) { phase in
                switch phase {
                case .active(let location): hoverLocation = geometry.plot.contains(location) ? location : nil
                case .ended: hoverLocation = nil
                }
            }
            .onTapGesture(count: 2, coordinateSpace: .named("graph")) { location in
                guard isEditable, geometry.plot.contains(location) else { return }
                onAdd(roundedFrequency(geometry.frequency(atX: location.x)), roundedGain(geometry.decibels(atY: location.y) - gainOffset))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frequency response")
    }

    // MARK: Drawing

    private func drawGrid(in context: inout GraphicsContext, geometry: GraphGeometry) {
        let plot = geometry.plot
        context.fill(Path(roundedRect: plot, cornerRadius: 6), with: .color(.primary.opacity(0.03)))

        var minor = Path()
        var major = Path()
        for decade in [10.0, 100, 1_000, 10_000] {
            for multiple in 1...9 {
                let frequency = decade * Double(multiple)
                guard frequency >= GraphGeometry.minimumFrequency, frequency <= GraphGeometry.maximumFrequency else { continue }
                let x = geometry.x(frequency)
                let isMajor = [1, 2, 5].contains(multiple)
                var path = isMajor ? major : minor
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                if isMajor { major = path } else { minor = path }
            }
        }
        let step = geometry.range <= 12 ? 3.0 : 6.0
        for decibels in stride(from: -geometry.range, through: geometry.range, by: step) {
            let y = geometry.y(decibels)
            major.move(to: CGPoint(x: plot.minX, y: y))
            major.addLine(to: CGPoint(x: plot.maxX, y: y))
            let label = Text(FilterEditorFormatter.signedDecimal(decibels, maximumFractionDigits: 0))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: plot.minX - 5, y: y), anchor: .trailing)
        }
        context.stroke(minor, with: .color(.primary.opacity(0.05)), lineWidth: 0.5)
        context.stroke(major, with: .color(.primary.opacity(0.1)), lineWidth: 0.5)

        var zero = Path()
        zero.move(to: CGPoint(x: plot.minX, y: geometry.y(0)))
        zero.addLine(to: CGPoint(x: plot.maxX, y: geometry.y(0)))
        context.stroke(zero, with: .color(.primary.opacity(0.3)), lineWidth: 1)

        for frequency in [20.0, 50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000, 20_000] {
            let text = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
            let label = Text(text).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: geometry.x(frequency), y: plot.maxY + 4), anchor: .top)
        }
    }

    private func drawCurves(in context: inout GraphicsContext, geometry: GraphGeometry) {
        guard !responses.isEmpty else { return }
        let plot = geometry.plot
        let opacity = isBypassed ? 0.35 : 1.0
        context.clip(to: Path(plot.insetBy(dx: -1, dy: -1)))

        if channelsDiffer {
            for (channel, points) in responses.enumerated() {
                context.stroke(curvePath(points, geometry: geometry), with: .color(channelColor(channel).opacity(opacity)), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            return
        }

        guard let points = responses.first, points.count > 1 else { return }
        let curve = curvePath(points, geometry: geometry)
        var fill = curve
        if let last = visiblePoints(points).last, let first = visiblePoints(points).first {
            fill.addLine(to: CGPoint(x: geometry.x(last.frequency), y: geometry.y(0)))
            fill.addLine(to: CGPoint(x: geometry.x(first.frequency), y: geometry.y(0)))
            fill.closeSubpath()
        }
        context.fill(fill, with: .color(Color.accentColor.opacity(0.14 * opacity)))
        context.stroke(curve, with: .color(Color.accentColor.opacity(opacity)), style: StrokeStyle(lineWidth: 2.25, lineCap: .round, lineJoin: .round))
    }

    private func drawHover(in context: inout GraphicsContext, geometry: GraphGeometry) {
        guard let hoverLocation, draggingFilterID == nil, let points = responses.first, !points.isEmpty else { return }
        let frequency = geometry.frequency(atX: hoverLocation.x)
        let decibels = interpolatedResponse(points, at: frequency)
        var line = Path()
        line.move(to: CGPoint(x: hoverLocation.x, y: geometry.plot.minY))
        line.addLine(to: CGPoint(x: hoverLocation.x, y: geometry.plot.maxY))
        context.stroke(line, with: .color(.primary.opacity(0.25)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
        let dot = CGRect(x: hoverLocation.x - 3, y: geometry.y(decibels) - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: dot), with: .color(.accentColor))

        let text = Text("\(FilterEditorFormatter.frequency(frequency))  \(FilterEditorFormatter.signedDecimal(decibels, maximumFractionDigits: 1)) dB")
            .font(.caption.monospacedDigit())
        let resolved = context.resolve(text)
        let size = resolved.measure(in: CGSize(width: 300, height: 40))
        let alignLeft = hoverLocation.x + size.width + 16 > geometry.plot.maxX
        let origin = CGPoint(x: alignLeft ? hoverLocation.x - size.width - 14 : hoverLocation.x + 6, y: geometry.plot.minY + 4)
        let background = CGRect(origin: origin, size: CGSize(width: size.width + 8, height: size.height + 4))
        context.fill(Path(roundedRect: background, cornerRadius: 4), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.9)))
        context.draw(resolved, at: CGPoint(x: origin.x + 4, y: origin.y + 2), anchor: .topLeading)
    }

    @ViewBuilder
    private func overlayLabels(geometry: GraphGeometry) -> some View {
        HStack(spacing: 10) {
            if channelsDiffer {
                ForEach(Array(responses.indices), id: \.self) { channel in
                    HStack(spacing: 4) {
                        Circle().fill(channelColor(channel)).frame(width: 7, height: 7)
                        Text(channelNames.indices.contains(channel) ? channelNames[channel] : "Ch \(channel + 1)")
                    }
                }
            }
            if isBypassed {
                Label("Bypassed", systemImage: "power.dotted").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .opacity(channelsDiffer || isBypassed ? 1 : 0)
        .position(x: geometry.plot.maxX - 80, y: geometry.plot.minY + 16)
        .allowsHitTesting(false)
    }

    // MARK: Handles

    private func handle(for filter: EditableFilter, number: Int, geometry: GraphGeometry) -> some View {
        let frequency = min(max(filter.frequency, GraphGeometry.minimumFrequency), GraphGeometry.maximumFrequency)
        let decibels = filter.kind.supportsGain
            ? filter.gainDB + gainOffset
            : interpolatedResponse(responses.first ?? [], at: frequency)
        let clamped = min(max(decibels, -geometry.range), geometry.range)
        let isSelected = filter.id == selectedFilterID
        let color = BandPalette.color(number - 1)
        let diameter: CGFloat = isSelected ? 20 : 16

        return ZStack {
            Circle()
                .fill(filter.isOff ? Color(nsColor: .windowBackgroundColor) : color)
                .overlay(Circle().strokeBorder(filter.isOff ? color : .white.opacity(0.9), lineWidth: isSelected ? 2.5 : 1.5))
                .shadow(color: .black.opacity(0.25), radius: isSelected ? 3 : 1.5, y: 1)
            Text("\(number)")
                .font(.system(size: isSelected ? 10 : 9, weight: .bold).monospacedDigit())
                .foregroundStyle(filter.isOff ? color : .white)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle().inset(by: -6))
        .position(x: geometry.x(frequency), y: geometry.y(clamped))
        .help("\(filter.title) · \(filter.detail)")
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("graph"))
                .onChanged { value in
                    let isFirst = draggingFilterID != filter.id
                    if isFirst {
                        draggingFilterID = filter.id
                        onSelect(filter.id)
                    }
                    guard value.translation != .zero else { return }
                    let newFrequency = roundedFrequency(min(max(geometry.frequency(atX: value.location.x), GraphGeometry.minimumFrequency), GraphGeometry.maximumFrequency))
                    let newGain = filter.kind.supportsGain
                        ? roundedGain(min(max(geometry.decibels(atY: value.location.y), -geometry.range), geometry.range) - gainOffset)
                        : filter.gainDB
                    onDrag(filter, newFrequency, newGain, isFirst)
                }
                .onEnded { _ in draggingFilterID = nil }
        )
    }

    // MARK: Helpers

    private func visiblePoints(_ points: [APOFrequencyResponsePoint]) -> [APOFrequencyResponsePoint] {
        points.filter { $0.frequency >= GraphGeometry.minimumFrequency && $0.frequency <= GraphGeometry.maximumFrequency }
    }

    private func curvePath(_ points: [APOFrequencyResponsePoint], geometry: GraphGeometry) -> Path {
        var path = Path()
        for (index, point) in visiblePoints(points).enumerated() {
            let position = CGPoint(x: geometry.x(point.frequency), y: geometry.y(point.magnitudeDB))
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        return path
    }

    private func interpolatedResponse(_ points: [APOFrequencyResponsePoint], at frequency: Double) -> Double {
        guard let first = points.first else { return 0 }
        if frequency <= first.frequency { return first.magnitudeDB }
        for index in 1..<points.count where points[index].frequency >= frequency {
            let lower = points[index - 1]
            let upper = points[index]
            let amount = log(frequency / lower.frequency) / log(upper.frequency / lower.frequency)
            return lower.magnitudeDB + (upper.magnitudeDB - lower.magnitudeDB) * amount
        }
        return points.last?.magnitudeDB ?? 0
    }

    private func channelColor(_ channel: Int) -> Color {
        [Color.blue, .red, .green, .orange, .purple, .teal, .pink, .yellow][channel % 8]
    }

    private func roundedFrequency(_ frequency: Double) -> Double {
        let magnitude = pow(10, floor(log10(frequency)) - 2)
        return (frequency / magnitude).rounded() * magnitude
    }

    private func roundedGain(_ gain: Double) -> Double {
        (gain * 10).rounded() / 10
    }
}
