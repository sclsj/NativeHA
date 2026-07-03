import Foundation
import NativeHACore

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var selectedGraphHours = AppConfig.defaultGraphHours
    @Published var views: [LovelaceView] = []
    @Published var states: [String: HAState] = [:]
    @Published var histories: [String: [HAHistorySeries]] = [:]
    @Published var status = "Starting"
    @Published var errorMessage: String?
    @Published var activeBaseURL: URL?
    @Published var showEntityIDs = AppConfig.showEntityIDsByDefault
    @Published var selectedEntityID: String?

    private var restClient: HomeAssistantRESTClient?
    private var webSocketClient: HomeAssistantWebSocketClient?
    private var hasStarted = false
    private var pendingStates: [String: HAState] = [:]
    private var isStateFlushScheduled = false
    private let isoFormatter = ISO8601DateFormatter()
    private let fractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var homeView: LovelaceView? {
        views.first(where: { $0.path == "default_view" }) ?? views.first
    }

    var homeCards: [LovelaceCard] {
        guard let cards = homeView?.cards else {
            return []
        }

        return cleanCards(flatten(cards))
    }

    var dashboardColumns: [[LovelaceCard]] {
        var columns = Array(repeating: [LovelaceCard](), count: AppConfig.dashboardColumnCount)
        var unplaced: [LovelaceCard] = []

        for card in homeCards {
            if let rule = AppConfig.cardColumnRules.first(where: { $0.matches(card) }) {
                let index = min(max(rule.column, 0), columns.count - 1)
                columns[index].append(card)
            } else {
                unplaced.append(card)
            }
        }

        for card in unplaced {
            let index = columns.enumerated().min(by: { $0.element.count < $1.element.count })?.offset ?? 0
            columns[index].append(card)
        }

        return columns
    }

    func start() {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        Task {
            await load()
        }
    }

    func setGraphHours(_ hours: Int) {
        guard selectedGraphHours != hours else {
            return
        }

        selectedGraphHours = hours
        Task {
            await loadHistories()
        }
    }

    func displayName(for entityID: String) -> String {
        if
            let nameValue = states[entityID]?.attributes["friendly_name"],
            case let .string(name) = nameValue
        {
            return name
        }

        return entityID
            .split(separator: ".")
            .last
            .map { String($0).replacingOccurrences(of: "_", with: " ").capitalized }
            ?? entityID
    }

    func displayState(for entityID: String) -> String {
        guard let state = states[entityID] else {
            return "Unavailable"
        }

        var value = state.state
        if let numeric = Double(value) {
            value = formatNumber(numeric)
        }

        if let unit = unit(for: entityID), !unit.isEmpty {
            return "\(value) \(unit)"
        }

        return value.replacingOccurrences(of: "_", with: " ")
    }

    func unit(for entityID: String) -> String? {
        guard
            let unitValue = states[entityID]?.attributes["unit_of_measurement"],
            case let .string(unit) = unitValue
        else {
            return nil
        }

        return unit
    }

    func isOn(entityID: String) -> Bool {
        states[entityID]?.state == "on"
    }

    func canToggle(entityID: String) -> Bool {
        switch domain(for: entityID) {
        case "switch", "fan", "input_boolean", "automation":
            return true
        default:
            return false
        }
    }

    func setPower(entityID: String, isOn: Bool) {
        guard canToggle(entityID: entityID) else {
            return
        }

        performPowerCall(entityID: entityID, isOn: isOn)
    }

    func setPower(entityIDs: [String], isOn: Bool) {
        for entityID in entityIDs where canToggle(entityID: entityID) {
            performPowerCall(entityID: entityID, isOn: isOn)
        }
    }

    func allOn(entityIDs: [String]) -> Bool {
        let toggleable = entityIDs.filter { canToggle(entityID: $0) }
        guard !toggleable.isEmpty else {
            return false
        }
        return toggleable.allSatisfy { isOn(entityID: $0) }
    }

    func refreshHistories() {
        Task {
            await loadHistories()
        }
    }

    func historyKey(for card: LovelaceCard) -> String {
        let entities = historyEntityIDs(for: card)
        return "\(selectedGraphHours):\(entities.joined(separator: ","))"
    }

    func historySeries(for card: LovelaceCard) -> [HAHistorySeries]? {
        histories[historyKey(for: card)]
    }

    func historyEntityIDs(for card: LovelaceCard) -> [String] {
        (card.entities?.compactMap(\.entity) ?? [])
            .filter { !AppConfig.hiddenEntityIDs.contains($0) }
    }

    func openDetails(entityID: String) {
        selectedEntityID = entityID
    }

    func closeDetails() {
        selectedEntityID = nil
    }

    func domain(for entityID: String) -> String {
        String(entityID.split(separator: ".").first ?? "")
    }

    func date(from point: HAHistoryPoint) -> Date? {
        if let lastChanged = point.lastChanged, let date = parseDate(lastChanged) {
            return date
        }

        if let lastUpdated = point.lastUpdated, let date = parseDate(lastUpdated) {
            return date
        }

        return nil
    }

    func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    func detailTime(_ value: String?) -> String {
        guard let value = value, let date = parseDate(value) else {
            return "Unknown"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    func weatherSummary(_ state: String) -> String {
        switch state {
        case "partlycloudy":
            return "Partly cloudy"
        default:
            return state.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func stringValue(_ value: JSONValue) -> String {
        switch value {
        case let .string(value):
            return value
        case let .int(value):
            return "\(value)"
        case let .double(value):
            return formatNumber(value)
        case let .bool(value):
            return value ? "true" : "false"
        case .object:
            return "{...}"
        case .array:
            return "[...]"
        case .null:
            return "null"
        }
    }

    private func load() async {
        do {
            status = "Reading token"
            let token = try loadToken()

            status = "Connecting"
            let connection = try await firstWorkingConnection(token: token)
            activeBaseURL = connection.baseURL
            restClient = connection.restClient

            status = "Loading states"
            let stateList = try await connection.restClient.fetchStates()
            states = Dictionary(uniqueKeysWithValues: stateList.map { ($0.entityId, $0) })

            status = "Loading dashboard"
            let webSocket = HomeAssistantWebSocketClient(configuration: connection.configuration)
            try await webSocket.connect()
            let config = try await webSocket.fetchLovelaceConfig()
            views = config.views
            webSocketClient = webSocket

            status = "Live"
            try await webSocket.subscribeToStateChanges()

            Task { [weak self] in
                await self?.loadHistories()
            }

            Task { [weak self, webSocket] in
                do {
                    try await webSocket.receiveStateChanges { [weak self] state in
                        self?.queueStateUpdate(state)
                    }
                } catch {
                    await MainActor.run {
                        self?.status = "Disconnected"
                        self?.errorMessage = "WebSocket disconnected: \(error.localizedDescription)"
                    }
                }
            }
        } catch {
            status = "Error"
            errorMessage = error.localizedDescription
        }
    }

    private func parseDate(_ value: String) -> Date? {
        fractionalISOFormatter.date(from: value) ?? isoFormatter.date(from: value)
    }

    private func queueStateUpdate(_ state: HAState) {
        pendingStates[state.entityId] = state

        guard !isStateFlushScheduled else {
            return
        }

        isStateFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.flushPendingStates()
        }
    }

    private func flushPendingStates() {
        guard !pendingStates.isEmpty else {
            isStateFlushScheduled = false
            return
        }

        for (entityID, state) in pendingStates {
            states[entityID] = state
        }
        pendingStates.removeAll()
        isStateFlushScheduled = false
    }

    private func loadHistories() async {
        guard let restClient = restClient else {
            return
        }

        do {
            let requests = historyRequests()
            var nextHistories: [String: [HAHistorySeries]] = histories

            for request in requests {
                let series = try await restClient.fetchHistory(
                    entityIDs: request.entityIDs,
                    hoursToShow: request.hoursToShow
                )
                nextHistories[request.key] = downsample(series, maxPoints: 700)
            }

            histories = nextHistories
        } catch {
            errorMessage = "History refresh failed: \(error.localizedDescription)"
        }
    }

    private func historyRequests() -> [HistoryRequest] {
        var requests: [HistoryRequest] = []
        collectHistoryRequests(from: homeCards, into: &requests)
        return requests.removingDuplicates()
    }

    private func collectHistoryRequests(from cards: [LovelaceCard], into requests: inout [HistoryRequest]) {
        for card in cards {
            if card.type == "history-graph" {
                let entities = historyEntityIDs(for: card)
                if !entities.isEmpty {
                    requests.append(HistoryRequest(entityIDs: entities, hoursToShow: selectedGraphHours))
                }
            }

            if let nestedCards = card.cards {
                collectHistoryRequests(from: nestedCards, into: &requests)
            }
        }
    }

    private func flatten(_ cards: [LovelaceCard]) -> [LovelaceCard] {
        cards.flatMap { card -> [LovelaceCard] in
            if card.type == "vertical-stack", let nestedCards = card.cards {
                return flatten(nestedCards)
            }
            return [card]
        }
    }

    private func cleanCards(_ cards: [LovelaceCard]) -> [LovelaceCard] {
        cards.compactMap { card in
            let cleanedEntities = card.entities?.filter { entityRef in
                guard let entity = entityRef.entity else {
                    return true
                }
                return !AppConfig.hiddenEntityIDs.contains(entity)
            }

            let cleanedNestedCards = card.cards.map { cleanCards($0) }

            if card.entities != nil, cleanedEntities?.isEmpty == true {
                return nil
            }

            if card.type == "history-graph", cleanedEntities?.isEmpty == true {
                return nil
            }

            return LovelaceCard(
                type: card.type,
                title: card.title,
                entity: card.entity,
                entities: cleanedEntities,
                cards: cleanedNestedCards,
                hoursToShow: selectedGraphHours,
                showForecast: card.showForecast,
                content: card.content
            )
        }
    }

    private func firstWorkingConnection(token: String) async throws -> Connection {
        var lastError: Error?

        for baseURL in AppConfig.baseURLs {
            let configuration = HomeAssistantConfiguration(baseURL: baseURL, accessToken: token)
            let client = HomeAssistantRESTClient(configuration: configuration)

            do {
                _ = try await client.fetchConfig()
                return Connection(
                    baseURL: baseURL,
                    configuration: configuration,
                    restClient: client
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? URLError(.cannotConnectToHost)
    }

    private func loadToken() throws -> String {
        try String(contentsOfFile: AppConfig.tokenFilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func performPowerCall(entityID: String, isOn: Bool) {
        guard let restClient = restClient else {
            return
        }

        let service = isOn ? "turn_on" : "turn_off"
        let domain = domain(for: entityID)
        applyOptimisticState(entityID: entityID, state: isOn ? "on" : "off")

        Task {
            do {
                _ = try await restClient.callService(
                    domain: domain,
                    service: service,
                    data: ["entity_id": .string(entityID)]
                )
            } catch {
                self.errorMessage = "Service call failed for \(entityID): \(error.localizedDescription)"
            }
        }
    }

    private func downsample(_ series: [HAHistorySeries], maxPoints: Int) -> [HAHistorySeries] {
        series.map { item in
            guard item.points.count > maxPoints else {
                return item
            }

            let stride = max(item.points.count / maxPoints, 1)
            var points = item.points.enumerated().compactMap { index, point in
                index % stride == 0 ? point : nil
            }

            if let last = item.points.last, points.last != last {
                points.append(last)
            }

            return HAHistorySeries(entityID: item.entityID, points: points)
        }
    }

    private func applyOptimisticState(entityID: String, state: String) {
        guard let old = states[entityID] else {
            return
        }

        states[entityID] = HAState(
            entityId: old.entityId,
            state: state,
            attributes: old.attributes,
            lastChanged: old.lastChanged,
            lastUpdated: old.lastUpdated
        )
    }

    private func formatNumber(_ value: Double) -> String {
        if abs(value) >= 100 {
            return String(format: "%.0f", value)
        }

        if abs(value) >= 10 {
            return String(format: "%.1f", value)
        }

        return String(format: "%.2f", value)
    }
}

private struct Connection {
    let baseURL: URL
    let configuration: HomeAssistantConfiguration
    let restClient: HomeAssistantRESTClient
}

struct HistoryRequest: Hashable {
    let entityIDs: [String]
    let hoursToShow: Int

    var key: String {
        "\(hoursToShow):\(entityIDs.joined(separator: ","))"
    }
}

private extension Array where Element == HistoryRequest {
    func removingDuplicates() -> [HistoryRequest] {
        var seen = Set<String>()
        return filter { request in
            seen.insert(request.key).inserted
        }
    }
}
