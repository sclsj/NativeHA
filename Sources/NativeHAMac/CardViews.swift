import AppKit
import NativeHACore
import SwiftUI

struct CardRenderer: View {
    let card: LovelaceCard

    var body: some View {
        switch card.type {
        case "vertical-stack":
            VStack(spacing: AppConfig.dashboardColumnSpacing) {
                ForEach(card.cards ?? [], id: \.nativeID) { nestedCard in
                    CardRenderer(card: nestedCard)
                }
            }
        case "entities":
            EntitiesCard(card: card)
        case "history-graph":
            HistoryGraphCard(card: card)
        case "weather-forecast":
            WeatherCard(card: card)
        case "markdown":
            MarkdownCard(card: card)
        default:
            UnsupportedCard(card: card)
        }
    }
}

extension LovelaceCard {
    var nativeID: String {
        [
            type,
            title ?? "",
            entity ?? "",
            entities?.compactMap(\.entity).joined(separator: ",") ?? "",
            cards?.map(\.nativeID).joined(separator: "|") ?? "",
        ].joined(separator: "::")
    }
}

struct EntitiesCard: View {
    @EnvironmentObject private var model: DashboardViewModel
    let card: LovelaceCard

    private var entityIDs: [String] {
        card.entities?.compactMap(\.entity) ?? []
    }

    private var toggleableEntityIDs: [String] {
        entityIDs.filter { model.canToggle(entityID: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let title = card.title {
                    CardTitle(title)
                }
                Spacer()
                if toggleableEntityIDs.count > 1 {
                    Toggle("", isOn: Binding(
                        get: { model.allOn(entityIDs: toggleableEntityIDs) },
                        set: { model.setPower(entityIDs: toggleableEntityIDs, isOn: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }
            .padding(.bottom, 14)

            ForEach(card.entities ?? []) { entityRef in
                if let entityID = entityRef.entity {
                    EntityRow(
                        entityID: entityID,
                        name: entityRef.name ?? model.displayName(for: entityID)
                    )

                    if entityRef.id != (card.entities ?? []).last?.id {
                        Divider()
                            .background(Color.white.opacity(0.08))
                    }
                }
            }
        }
        .cardStyle()
    }
}

struct EntityRow: View {
    @EnvironmentObject private var model: DashboardViewModel
    let entityID: String
    let name: String

    var body: some View {
        Button(action: {
            model.openDetails(entityID: entityID)
        }) {
            HStack(spacing: 16) {
                DomainIcon(entityID: entityID)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(1)
                    if model.showEntityIDs {
                        Text(entityID)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }

                Spacer()

                if model.canToggle(entityID: entityID) {
                    Toggle("", isOn: Binding(
                        get: { model.isOn(entityID: entityID) },
                        set: { model.setPower(entityID: entityID, isOn: $0) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .onTapGesture {}
                } else {
                    Text(model.displayState(for: entityID))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.78))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

struct WeatherCard: View {
    @EnvironmentObject private var model: DashboardViewModel
    let card: LovelaceCard

    var body: some View {
        Button(action: {
            if let entityID = card.entity {
                model.openDetails(entityID: entityID)
            }
        }) {
            HStack(spacing: 16) {
                Image(systemName: "cloud.sun.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.yellow)
                    .frame(width: 48)

                VStack(alignment: .leading, spacing: 4) {
                    if let entityID = card.entity, let state = model.states[entityID] {
                        Text(model.weatherSummary(state.state))
                            .font(.system(size: 22, weight: .semibold))
                        Text(model.displayName(for: entityID))
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    } else {
                        Text("Weather unavailable")
                            .font(.system(size: 15, weight: .medium))
                    }
                }

                Spacer()

                if let entityID = card.entity, let state = model.states[entityID] {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(weatherTemperature(from: state))
                            .font(.system(size: 28, weight: .medium))
                        if let humidity = humidity(from: state) {
                            Text(humidity)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private func weatherTemperature(from state: HAState) -> String {
        guard
            let temperature = state.attributes["temperature"],
            case let .double(value) = temperature
        else {
            return model.displayState(for: state.entityId)
        }

        let unit: String
        if
            let unitValue = state.attributes["temperature_unit"],
            case let .string(rawUnit) = unitValue
        {
            unit = rawUnit
        } else {
            unit = ""
        }

        return "\(String(format: "%.1f", value)) \(unit)"
    }

    private func humidity(from state: HAState) -> String? {
        guard
            let humidity = state.attributes["humidity"],
            case let .double(value) = humidity
        else {
            return nil
        }

        return "\(String(format: "%.0f", value))%"
    }
}

struct HistoryGraphCard: View {
    @EnvironmentObject private var model: DashboardViewModel
    let card: LovelaceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                if let title = card.title {
                    CardTitle(title)
                }
                Spacer()
                Text("\(model.selectedGraphHours)h")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            if let series = model.historySeries(for: card), !series.isEmpty {
                let groups = groupedSeries(series)
                ForEach(groups, id: \.unit) { group in
                    UnitGraph(unit: group.unit, series: group.series)

                    if group.unit != groups.last?.unit {
                        Divider()
                            .background(Color.white.opacity(0.08))
                            .padding(.vertical, 6)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("Loading history")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            }
        }
        .cardStyle()
    }

    private func groupedSeries(_ series: [HAHistorySeries]) -> [SeriesGroup] {
        let groups = Dictionary(grouping: series) { item in
            model.unit(for: item.entityID) ?? (model.domain(for: item.entityID) == "binary_sensor" ? "State" : "")
        }

        return groups
            .map { SeriesGroup(unit: $0.key, series: $0.value) }
            .sorted { left, right in
                groupSortKey(left.unit) < groupSortKey(right.unit)
            }
    }

    private func groupSortKey(_ unit: String) -> String {
        switch unit {
        case "%":
            return "0-%"
        case "°C":
            return "1-c"
        case "IAQ":
            return "2-iaq"
        case "ppm":
            return "3-ppm"
        case "µg/m³", "μg/m³":
            return "4-ug"
        default:
            return "9-\(unit)"
        }
    }
}

private struct SeriesGroup {
    let unit: String
    let series: [HAHistorySeries]
}

struct UnitGraph: View {
    @EnvironmentObject private var model: DashboardViewModel
    let unit: String
    let series: [HAHistorySeries]
    @State private var hoverLocation: CGPoint?
    @State private var zoomScale: CGFloat = 1

    private var chartSeries: [ChartSeries] {
        series.map { item in
            ChartSeries(
                entityID: item.entityID,
                name: model.displayName(for: item.entityID),
                unit: unit,
                color: color(for: item.entityID),
                points: item.points.compactMap { point in
                    guard let date = model.date(from: point), let value = numericValue(from: point.state) else {
                        return nil
                    }
                    return ChartPoint(
                        date: date,
                        value: value,
                        display: displayValue(point.state, unit: unit)
                    )
                }
            )
        }
        .filter { !$0.points.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InteractiveLineChart(
                unit: unit,
                series: chartSeries,
                zoomScale: zoomScale,
                hoverLocation: $hoverLocation
            )
            .frame(height: chartHeight)
            .overlay(
                GraphInteractionOverlay(
                    onHover: { point in
                        hoverLocation = point
                    },
                    onMagnify: { delta in
                        let next = zoomScale * CGFloat(1 + delta)
                        zoomScale = min(max(next, 1), 18)
                    }
                )
            )

            HStack(spacing: 12) {
                ForEach(chartSeries) { item in
                    Button(action: {
                        model.openDetails(entityID: item.entityID)
                    }) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 8, height: 8)
                            Text(item.name)
                                .lineLimit(1)
                            Text(model.displayState(for: item.entityID))
                                .fontWeight(.semibold)
                                .lineLimit(1)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                if zoomScale > 1.05 {
                    Text("\(String(format: "%.1f", zoomScale))x")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.48))
                }
            }
        }
    }

    private var chartHeight: CGFloat {
        unit == "State" ? 96 : 178
    }

    private func numericValue(from state: String) -> Double? {
        if state == "on" || state == "Running" || state == "running" {
            return 1
        }

        if state == "off" || state == "idle" || state == "Not running" {
            return 0
        }

        return Double(state)
    }

    private func displayValue(_ state: String, unit: String) -> String {
        if let value = Double(state) {
            if unit.isEmpty {
                return String(format: "%.2f", value)
            }
            if abs(value) >= 100 {
                return "\(String(format: "%.0f", value)) \(unit)"
            }
            return "\(String(format: "%.1f", value)) \(unit)"
        }

        return state
    }
}

struct InteractiveLineChart: View {
    @EnvironmentObject private var model: DashboardViewModel
    let unit: String
    let series: [ChartSeries]
    let zoomScale: CGFloat
    @Binding var hoverLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let model = ChartModel(series: series, rect: geometry.frame(in: .local), zoomScale: zoomScale)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.black.opacity(0.19))

                grid(model: model)

                Text(unit.isEmpty ? "value" : unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
                    .position(x: 18, y: 11)

                ForEach(model.yTicks, id: \.self) { tick in
                    Text(formatAxisValue(tick))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .position(x: 21, y: model.y(for: tick))
                }

                ForEach(model.xTicks, id: \.self) { tick in
                    Text(model.shortTime(tick))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.55))
                        .position(x: model.x(for: tick), y: geometry.size.height - 11)
                }

                ForEach(series) { item in
                    Path { path in
                        let points = model.visiblePoints(for: item)
                        for (index, point) in points.enumerated() {
                            let cgPoint = CGPoint(x: model.x(for: point.date), y: model.y(for: point.value))
                            if index == 0 {
                                path.move(to: cgPoint)
                            } else {
                                path.addLine(to: cgPoint)
                            }
                        }
                    }
                    .stroke(item.color, lineWidth: 2)
                }

                if let hoverLocation = hoverLocation, let sample = model.sample(at: hoverLocation.x) {
                    hoverOverlay(sample: sample, model: model, size: geometry.size)
                }
            }
        }
    }

    private func grid(model: ChartModel) -> some View {
        Path { path in
            for tick in model.yTicks {
                let y = model.y(for: tick)
                path.move(to: CGPoint(x: model.plotRect.minX, y: y))
                path.addLine(to: CGPoint(x: model.plotRect.maxX, y: y))
            }

            for tick in model.xTicks {
                let x = model.x(for: tick)
                path.move(to: CGPoint(x: x, y: model.plotRect.minY))
                path.addLine(to: CGPoint(x: x, y: model.plotRect.maxY))
            }
        }
        .stroke(Color.white.opacity(0.08), lineWidth: 1)
    }

    private func hoverOverlay(sample: ChartSample, model: ChartModel, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: sample.x, y: model.plotRect.minY))
                path.addLine(to: CGPoint(x: sample.x, y: model.plotRect.maxY))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)

            ForEach(sample.values) { value in
                Circle()
                    .fill(value.series.color)
                    .frame(width: 8, height: 8)
                    .position(x: sample.x, y: model.y(for: value.point.value))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(model.shortTime(sample.date))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)

                ForEach(sample.values) { value in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(value.series.color)
                            .frame(width: 7, height: 7)
                        Text(value.series.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(value.point.display)
                            .fontWeight(.semibold)
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.82))
                }
            }
            .padding(9)
            .frame(width: 230)
            .background(Color(red: 0.06, green: 0.065, blue: 0.07).opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .cornerRadius(7)
            .position(
                x: min(max(sample.x + 118, 118), size.width - 118),
                y: model.plotRect.minY + 58
            )
        }
    }

    private func formatAxisValue(_ value: Double) -> String {
        if abs(value) >= 100 {
            return String(format: "%.0f", value)
        }
        if abs(value) >= 10 {
            return String(format: "%.1f", value)
        }
        return String(format: "%.2f", value)
    }
}

struct ChartSeries: Identifiable {
    var id: String { entityID }
    let entityID: String
    let name: String
    let unit: String
    let color: Color
    let points: [ChartPoint]
}

struct ChartPoint {
    let date: Date
    let value: Double
    let display: String
}

struct ChartSample {
    let date: Date
    let x: CGFloat
    let values: [ChartSampleValue]
}

struct ChartSampleValue: Identifiable {
    var id: String { series.entityID }
    let series: ChartSeries
    let point: ChartPoint
}

struct ChartModel {
    let series: [ChartSeries]
    let rect: CGRect
    let zoomScale: CGFloat

    var plotRect: CGRect {
        CGRect(
            x: rect.minX + 42,
            y: rect.minY + 18,
            width: max(rect.width - 52, 1),
            height: max(rect.height - 42, 1)
        )
    }

    private var allPoints: [ChartPoint] {
        series.flatMap(\.points)
    }

    private var fullStart: Date {
        allPoints.map(\.date).min() ?? Date()
    }

    private var fullEnd: Date {
        allPoints.map(\.date).max() ?? Date()
    }

    private var visibleStart: Date {
        let fullInterval = max(fullEnd.timeIntervalSince(fullStart), 1)
        let visibleInterval = fullInterval / max(Double(zoomScale), 1)
        return fullEnd.addingTimeInterval(-visibleInterval)
    }

    private var visibleEnd: Date {
        fullEnd
    }

    private var values: [Double] {
        series.flatMap { visiblePoints(for: $0).map(\.value) }
    }

    private var yMin: Double {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let padding = max((maxValue - minValue) * 0.08, 0.01)
        return minValue - padding
    }

    private var yMax: Double {
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let padding = max((maxValue - minValue) * 0.08, 0.01)
        return maxValue + padding
    }

    var yTicks: [Double] {
        let range = max(yMax - yMin, 0.001)
        return (0...4).map { yMin + range * Double($0) / 4 }.reversed()
    }

    var xTicks: [Date] {
        let interval = max(visibleEnd.timeIntervalSince(visibleStart), 1)
        return (0...4).map { visibleStart.addingTimeInterval(interval * Double($0) / 4) }
    }

    func visiblePoints(for item: ChartSeries) -> [ChartPoint] {
        let points = item.points.filter { $0.date >= visibleStart && $0.date <= visibleEnd }
        guard points.count > 520 else {
            return points
        }

        let stride = max(points.count / 520, 1)
        return points.enumerated().compactMap { index, point in
            index % stride == 0 ? point : nil
        }
    }

    func x(for date: Date) -> CGFloat {
        let interval = max(visibleEnd.timeIntervalSince(visibleStart), 1)
        let ratio = date.timeIntervalSince(visibleStart) / interval
        return plotRect.minX + plotRect.width * CGFloat(ratio)
    }

    func y(for value: Double) -> CGFloat {
        let range = max(yMax - yMin, 0.0001)
        let ratio = (value - yMin) / range
        return plotRect.maxY - plotRect.height * CGFloat(ratio)
    }

    func sample(at xPosition: CGFloat) -> ChartSample? {
        let clampedX = min(max(xPosition, plotRect.minX), plotRect.maxX)
        let ratio = Double((clampedX - plotRect.minX) / plotRect.width)
        let targetDate = visibleStart.addingTimeInterval(visibleEnd.timeIntervalSince(visibleStart) * ratio)

        let values = series.compactMap { item -> ChartSampleValue? in
            guard let point = nearestPoint(in: visiblePoints(for: item), to: targetDate) else {
                return nil
            }
            return ChartSampleValue(series: item, point: point)
        }

        guard !values.isEmpty else {
            return nil
        }

        let averageDate = values.map { $0.point.date.timeIntervalSince1970 }.reduce(0, +) / Double(values.count)
        let date = Date(timeIntervalSince1970: averageDate)
        return ChartSample(date: date, x: clampedX, values: values)
    }

    func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func nearestPoint(in points: [ChartPoint], to date: Date) -> ChartPoint? {
        points.min { left, right in
            abs(left.date.timeIntervalSince(date)) < abs(right.date.timeIntervalSince(date))
        }
    }
}

struct GraphInteractionOverlay: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void
    let onMagnify: (CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingView {
        TrackingView(onHover: onHover, onMagnify: onMagnify)
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onHover = onHover
        nsView.onMagnify = onMagnify
    }

    final class TrackingView: NSView {
        var onHover: (CGPoint?) -> Void
        var onMagnify: (CGFloat) -> Void

        init(onHover: @escaping (CGPoint?) -> Void, onMagnify: @escaping (CGFloat) -> Void) {
            self.onHover = onHover
            self.onMagnify = onMagnify
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onHover(nil)
        }

        override func magnify(with event: NSEvent) {
            onMagnify(event.magnification)
        }
    }
}

struct UnsupportedCard: View {
    let card: LovelaceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(card.title ?? "Unsupported Card")
            Text(card.type)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
            Text("Native renderer not implemented yet.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.45))
        }
        .cardStyle()
    }
}

struct MarkdownCard: View {
    let card: LovelaceCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = card.title {
                CardTitle(title)
            }

            Text(card.content ?? "")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.74))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .cardStyle()
    }
}

struct EntityDetailSheet: View {
    @EnvironmentObject private var model: DashboardViewModel
    @Environment(\.presentationMode) private var presentationMode
    let entityID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                DomainIcon(entityID: entityID)
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName(for: entityID))
                        .font(.system(size: 22, weight: .semibold))
                    Text(entityID)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.52))
                        .textSelection(.enabled)
                }

                Spacer()

                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(22)

            Divider()
                .background(Color.white.opacity(0.08))

            if let state = model.states[entityID] {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("State")
                                .foregroundColor(.white.opacity(0.55))
                            Spacer()
                            Text(model.displayState(for: entityID))
                                .font(.system(size: 18, weight: .semibold))
                        }

                        if model.canToggle(entityID: entityID) {
                            Toggle("Power", isOn: Binding(
                                get: { model.isOn(entityID: entityID) },
                                set: { model.setPower(entityID: entityID, isOn: $0) }
                            ))
                            .toggleStyle(.switch)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            detailRow("Last changed", model.detailTime(state.lastChanged))
                            detailRow("Last updated", model.detailTime(state.lastUpdated))
                        }

                        VStack(alignment: .leading, spacing: 9) {
                            Text("Attributes")
                                .font(.system(size: 15, weight: .semibold))

                            ForEach(state.attributes.keys.sorted(), id: \.self) { key in
                                if let value = state.attributes[key] {
                                    detailRow(key, model.stringValue(value))
                                }
                            }
                        }
                    }
                    .padding(22)
                }
            } else {
                Text("Entity is unavailable")
                    .foregroundColor(.white.opacity(0.62))
                    .padding(22)
            }
        }
        .frame(width: 520, height: 620)
        .background(Color(red: 0.09, green: 0.095, blue: 0.1))
        .foregroundColor(.white)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.52))
            Spacer(minLength: 24)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.82))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
    }
}

struct CardTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 21, weight: .medium))
            .lineLimit(1)
            .foregroundColor(.white.opacity(0.86))
    }
}

struct DomainIcon: View {
    let entityID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(color.opacity(0.13))
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(color)
        }
    }

    private var domain: String {
        String(entityID.split(separator: ".").first ?? "")
    }

    private var symbol: String {
        switch domain {
        case "sensor":
            if entityID.contains("temperature") {
                return "thermometer"
            }
            if entityID.contains("humidity") {
                return "drop.fill"
            }
            return "waveform.path.ecg"
        case "binary_sensor":
            return "circle"
        case "switch", "input_boolean":
            return "power"
        case "fan":
            return "fanblades"
        case "person", "device_tracker":
            return "person.fill"
        case "weather":
            return "cloud.sun.fill"
        case "climate":
            return "thermometer.medium"
        default:
            return "smallcircle.filled.circle"
        }
    }

    private var color: Color {
        switch domain {
        case "sensor":
            return Color(red: 0.2, green: 0.58, blue: 0.86)
        case "binary_sensor":
            return Color(red: 0.2, green: 0.58, blue: 0.86)
        case "switch", "input_boolean":
            return Color(red: 0.2, green: 0.72, blue: 0.38)
        case "fan":
            return Color(red: 0.2, green: 0.58, blue: 0.86)
        case "person", "device_tracker":
            return Color(red: 0.2, green: 0.58, blue: 0.86)
        case "weather":
            return Color.yellow
        case "climate":
            return Color.orange
        default:
            return Color.white.opacity(0.75)
        }
    }
}

extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(Color(red: 0.095, green: 0.1, blue: 0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .cornerRadius(8)
    }
}

func color(for entityID: String) -> Color {
    let palette: [Color] = [
        Color(red: 0.26, green: 0.47, blue: 0.95),
        Color(red: 0.93, green: 0.66, blue: 0.22),
        Color(red: 0.4, green: 0.86, blue: 0.82),
        Color(red: 0.95, green: 0.32, blue: 0.5),
        Color(red: 0.66, green: 0.42, blue: 0.92),
        Color(red: 0.45, green: 0.76, blue: 0.32),
    ]

    let hash = abs(entityID.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) })
    return palette[hash % palette.count]
}
