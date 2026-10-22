import SwiftUI
import Charts
import Security
import AppKit

private enum LinkySection: String, CaseIterable, Identifiable {
    case dashboard = "Vue d’ensemble"
    case history = "Historique"
    case connection = "Connexion"
    case preferences = "Préférences"
    case developer = "Développement"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "rectangle.grid.2x2.fill"
        case .history: "chart.xyaxis.line"
        case .connection: "link"
        case .preferences: "slider.horizontal.3"
        case .developer: "wrench.and.screwdriver.fill"
        }
    }
}

private enum ConsumptionPeriod: String, CaseIterable, Identifiable {
    case week = "7"
    case month = "30"
    case quarter = "90"

    var id: String { rawValue }
    var days: Int { Int(rawValue) ?? 30 }
    var label: String { "\(days) jours" }
}

struct ContentView: View {
    @State private var selection: LinkySection? = .dashboard
    @State private var shiftPreferencesClick = false
    @StateObject private var model = LinkyModel()

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.linkyGreen.gradient)
                            .frame(width: 38, height: 38)
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Linky Monitor").font(.system(size: 14, weight: .bold))
                        Text("SUIVI ÉNERGIE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.top, 20)
                .padding(.bottom, 24)

                Text("ESPACE PERSONNEL")
                    .font(.system(size: 9, weight: .bold)).tracking(1.2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 19)
                    .padding(.bottom, 7)

                List(selection: $selection) {
                    ForEach(LinkySection.allCases.filter { $0 != .developer }) { section in
                        NavigationLink(value: section) {
                            Label(section.rawValue, systemImage: section.symbol)
                                .font(.system(size: 13, weight: .medium))
                                .padding(.vertical, 3)
                                .simultaneousGesture(TapGesture().onEnded {
                                    shiftPreferencesClick = section == .preferences && NSEvent.modifierFlags.contains(.shift)
                                })
                        }
                        .tag(section)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Circle().fill(model.isConnected ? Color.linkyGreen : Color.gray.opacity(0.55)).frame(width: 7, height: 7)
                    Text(model.isConnected ? "Connexion configurée" : "Aucune connexion")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 19).padding(.bottom, 17)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationSplitViewColumnWidth(min: 205, ideal: 225, max: 260)
        } detail: {
            Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardView(model: model)
                case .history: HistoryView(model: model)
                case .connection: ConnectionView(model: model)
                case .preferences: PreferencesView()
                case .developer: DeveloperView(model: model)
                }
            }
            .frame(minWidth: 600, minHeight: 500)
            .background(Color.pageBackground)
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { newValue in
            if newValue == .preferences && shiftPreferencesClick {
                shiftPreferencesClick = false
                selection = .developer
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

@MainActor
private final class LinkyModel: ObservableObject {
    @Published var samples: [ConsumptionSample] = []
    @Published var isLoading = false
    @Published var message: String?
    @Published var lastUpdated: Date?
    @Published var lastRequestStatus = "Aucun échange pour le moment"
    @Published var lastRequestAt: Date?
    @Published var isConnected = KeychainToken.read() != nil

    var prm: String { UserDefaults.standard.string(forKey: "linky.prm") ?? "" }
    var latestDailyValue: Double? { samples.last?.value }
    var periodTotal: Double { samples.reduce(0) { $0 + $1.value } }

    func saveToken(_ token: String) {
        KeychainToken.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
        isConnected = KeychainToken.read() != nil
    }

    func disconnect() {
        KeychainToken.delete()
        isConnected = false
        samples = []
        lastUpdated = nil
        message = nil
    }

    func refresh() async {
        guard let token = KeychainToken.read() else {
            message = "Ajoute ton token Conso API dans la page Connexion."
            return
        }
        guard prm.count == 14, prm.allSatisfy(\.isNumber) else {
            message = "Renseigne ton PRM à 14 chiffres dans la page Connexion."
            return
        }
        isLoading = true
        message = nil
        lastRequestAt = Date()
        lastRequestStatus = "Requête en cours…"
        defer { isLoading = false }
        do {
            let result = try await ConsoAPI.fetchDaily(token: token, prm: prm, days: 180)
            samples = result
            lastUpdated = Date()
            isConnected = true
            if result.isEmpty {
                message = "Aucune consommation disponible sur cette période."
                lastRequestStatus = "Réponse reçue, aucune mesure disponible"
            } else {
                lastRequestStatus = "Connexion réussie · \(result.count) mesures reçues"
            }
        } catch {
            message = error.localizedDescription
            lastRequestStatus = "Échec · \(error.localizedDescription)"
        }
    }
}

private struct ConsumptionSample: Identifiable {
    let date: Date
    let value: Double
    var id: Date { date }
}

private enum ConsoAPI {
    static func fetchDaily(token: String, prm: String, days: Int) async throws -> [ConsumptionSample] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        // dateFin is exclusive; use today so the request never includes a future day.
        let end = Calendar.current.startOfDay(for: Date())
        let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end.addingTimeInterval(Double(-days) * 86_400)
        guard var components = URLComponents(string: "https://conso.boris.sh/api/consommation_quotidienne") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "pointId", value: prm),
            URLQueryItem(name: "dateDebut", value: formatter.string(from: start)),
            URLQueryItem(name: "dateFin", value: formatter.string(from: end))
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Linky Monitor macOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.unexpectedResponse }
        guard http.statusCode == 200 else {
            let detail = responseDetail(from: data, token: token, prm: prm)
            throw APIError.status(http.statusCode, detail)
        }
        return parseSamples(from: data)
    }

    private static func responseDetail(from data: Data, token: String, prm: String) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data)
        let detail = findErrorMessage(in: object)
            ?? String(data: data, encoding: .utf8)
        guard let detail, !detail.isEmpty else { return nil }
        let redacted = detail
            .replacingOccurrences(of: token, with: "[token masqué]")
            .replacingOccurrences(of: prm, with: "[PRM masqué]")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(redacted.prefix(240))
    }

    private static func findErrorMessage(in value: Any?) -> String? {
        guard let value else { return nil }
        if let object = value as? [String: Any] {
            for key in ["error_description", "description", "detail", "message"] {
                if let message = object[key] as? String, !message.isEmpty { return message }
            }
            for child in object.values {
                if let message = findErrorMessage(in: child) { return message }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let message = findErrorMessage(in: child) { return message }
            }
        }
        return nil
    }

    private static func parseSamples(from data: Data) -> [ConsumptionSample] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let object = root as? [String: Any],
           let groups = object["grandeur"] as? [[String: Any]] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd"
            let apiSamples = groups.flatMap { group -> [ConsumptionSample] in
                let unit = (group["unite"] as? String ?? "").lowercased()
                let points = group["points"] as? [[String: Any]] ?? []
                return points.compactMap { point in
                    guard let rawDate = point["d"] as? String,
                          let date = formatter.date(from: String(rawDate.prefix(10))),
                          let rawValue = numericValue(point["v"]), rawValue >= 0 else { return nil }
                    let value = unit == "wh" ? rawValue / 1000 : rawValue
                    return ConsumptionSample(date: date, value: value)
                }
            }
            if !apiSamples.isEmpty {
                return Dictionary(grouping: apiSamples, by: \.date).compactMap { $0.value.first }.sorted { $0.date < $1.date }
            }
        }
        var rows: [[String: Any]] = []
        collectRows(root, into: &rows)
        let formatter = ISO8601DateFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let dateKeys = ["date", "dateMesure", "date_mesure", "dateDebut", "date_debut", "jour", "timestamp"]
        let valueKeys = ["valeur", "value", "valeurBrute", "valeur_brute", "consommation", "quantity", "energie"]
        let samples = rows.compactMap { row -> ConsumptionSample? in
            guard let rawDate = dateKeys.compactMap({ row[$0] as? String }).first,
                  let rawValue = valueKeys.compactMap({ numericValue(row[$0]) }).first else { return nil }
            let date = dayFormatter.date(from: String(rawDate.prefix(10)))
                ?? formatter.date(from: rawDate)
                ?? ISO8601DateFormatter().date(from: rawDate)
            guard let date, rawValue >= 0 else { return nil }
            let unit = (row["unite"] as? String ?? row["unit"] as? String ?? "").lowercased()
            let kWh = unit.contains("wh") && !unit.contains("kwh") ? rawValue / 1000 : rawValue
            return ConsumptionSample(date: date, value: kWh)
        }
        return Dictionary(grouping: samples, by: \.date).compactMap { $0.value.first }.sorted { $0.date < $1.date }
    }

    private static func numericValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    private static func collectRows(_ value: Any, into rows: inout [[String: Any]]) {
        if let array = value as? [Any] {
            for item in array { collectRows(item, into: &rows) }
        } else if let object = value as? [String: Any] {
            rows.append(object)
            for child in object.values { collectRows(child, into: &rows) }
        }
    }

    private enum APIError: LocalizedError {
        case invalidURL, unexpectedResponse, status(Int, String?)
        var errorDescription: String? {
            switch self {
            case .invalidURL: "L’adresse du service est invalide."
            case .unexpectedResponse: "Le service n’a pas renvoyé de réponse exploitable."
            case .status(401, _): "Token refusé. Vérifie le token dans Connexion."
            case .status(403, _): "Accès refusé pour ce compteur. Vérifie le consentement Enedis."
            case .status(404, let detail):
                if detail?.localizedCaseInsensitiveContains("no_data_found") == true || detail?.localizedCaseInsensitiveContains("no measure found") == true {
                    "Enedis ne renvoie pas encore de mesure. Vérifie dans ton espace Enedis que l’enregistrement et la collecte de la consommation horaire sont activés, puis réessaie demain."
                } else { "Compteur introuvable ou données indisponibles. Vérifie le PRM." }
            case .status(400, let detail):
                if let detail { "Requête refusée (400) : \(detail)" }
                else { "Requête refusée (400). Vérifie le PRM et les dates demandées." }
            case .status(let code, let detail):
                if let detail { "Erreur \(code) : \(detail)" }
                else { "Le service a répondu avec l’erreur \(code). Réessaie plus tard." }
            }
        }
    }
}

private enum KeychainToken {
    private static let service = "fr.yanis.LinkyMonitor"
    private static let account = "conso-api-token"

    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        delete()
        guard !token.isEmpty, let data = token.data(using: .utf8) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

private struct DashboardView: View {
    @ObservedObject var model: LinkyModel
    @AppStorage("linky.prm") private var prm = ""
    @AppStorage("linky.refreshOnOpen") private var refreshOnOpen = true
    @AppStorage("linky.selectedPeriod") private var selectedPeriod = ConsumptionPeriod.month.rawValue
    @AppStorage("linky.pricePerKWh") private var pricePerKWh = 0.0

    private var period: ConsumptionPeriod { ConsumptionPeriod(rawValue: selectedPeriod) ?? .month }
    private var windows: (current: [ConsumptionSample], previous: [ConsumptionSample]) {
        guard let last = model.samples.last else { return ([], []) }
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: last.date)
        let currentStart = calendar.date(byAdding: .day, value: -(period.days - 1), to: end) ?? end
        let previousStart = calendar.date(byAdding: .day, value: -period.days, to: currentStart) ?? currentStart
        let current = model.samples.filter { $0.date >= currentStart && $0.date <= end }
        let previous = model.samples.filter { $0.date >= previousStart && $0.date < currentStart }
        return (current, previous)
    }
    private var currentTotal: Double { windows.current.reduce(0) { $0 + $1.value } }
    private var previousTotal: Double { windows.previous.reduce(0) { $0 + $1.value } }
    private var estimatedCost: Double? { pricePerKWh > 0 ? currentTotal * pricePerKWh : nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 20) {
                    PageHeading(eyebrow: "SUIVI ÉNERGIE", title: "Vue d’ensemble", subtitle: "Un aperçu clair de ta consommation électrique.")
                    Spacer(minLength: 8)
                    PeriodPicker(selection: $selectedPeriod)
                }
                MainPowerCard(value: model.latestDailyValue)
                HStack(spacing: 12) {
                    MetricCard(title: "CONSOMMATION · \(period.label.uppercased())", value: model.samples.isEmpty ? nil : currentTotal, symbol: "calendar", tint: .blue)
                    CostEstimateCard(amount: estimatedCost, unitPrice: pricePerKWh)
                    ComparisonCard(current: currentTotal, previous: previousTotal, currentCount: windows.current.count, previousCount: windows.previous.count, period: period)
                }
                ConsumptionChart(samples: windows.current, title: "Consommation · \(period.label)")
                if let message = model.message { InlineNotice(message: message, isError: model.samples.isEmpty) }
                HStack {
                    Label(model.isConnected ? "Connexion configurée" : "Mode aperçu", systemImage: model.isConnected ? "checkmark.circle.fill" : "info.circle")
                    Spacer()
                    if let date = model.lastUpdated { Text("Mis à jour à \(date.formatted(date: .omitted, time: .shortened))") }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 3)
            }
            .padding(28)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: {
                    Label(model.isLoading ? "Actualisation…" : "Actualiser", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
        .task(id: model.isConnected) {
            if refreshOnOpen && model.isConnected && !prm.isEmpty && model.samples.isEmpty { await model.refresh() }
        }
    }
}

private struct PeriodPicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("Période", selection: $selection) {
            ForEach(ConsumptionPeriod.allCases) { period in
                Text(period.label).tag(period.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 255)
        .labelsHidden()
        .help("Choisir la période affichée")
    }
}

private struct CostEstimateCard: View {
    let amount: Double?
    let unitPrice: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("COÛT ESTIMÉ", systemImage: "eurosign.circle")
                .font(.system(size: 9, weight: .bold)).tracking(0.45).foregroundStyle(.secondary).lineLimit(1)
            if let amount {
                Text(amount.formatted(.currency(code: "EUR")))
                    .font(.system(size: 23, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.75)
                Text("Hors abonnement").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text("—").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Règle ton prix au kWh").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .help(unitPrice > 0 ? "Calculé avec le prix du kWh défini dans Préférences" : "Ajoute ton tarif dans Préférences")
    }
}

private struct ComparisonCard: View {
    let current: Double
    let previous: Double
    let currentCount: Int
    let previousCount: Int
    let period: ConsumptionPeriod

    private var percentChange: Double? {
        let minimumCount = max(3, Int(ceil(Double(period.days) * 0.7)))
        guard currentCount >= minimumCount, previousCount >= minimumCount, previous > 0 else { return nil }
        return (current - previous) / previous * 100
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("COMPARAISON", systemImage: "arrow.left.arrow.right")
                .font(.system(size: 9, weight: .bold)).tracking(0.45).foregroundStyle(.secondary).lineLimit(1)
            if let percentChange {
                HStack(spacing: 5) {
                    Image(systemName: percentChange > 0 ? "arrow.up.right" : "arrow.down.right")
                    Text(abs(percentChange).formatted(.number.precision(.fractionLength(0))) + "%")
                }
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle(percentChange > 0 ? Color.orange : Color.linkyGreen)
                Text("vs les \(period.label) précédents").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("—").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("Historique insuffisant").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 94, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct MainPowerCard: View {
    let value: Double?
    @AppStorage("linky.showUnit") private var showUnit = true
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("DERNIÈRE JOURNÉE DISPONIBLE", systemImage: "bolt.fill")
                    .font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.white.opacity(0.82))
                Spacer()
                Image(systemName: "waveform.path.ecg").font(.system(size: 20, weight: .medium)).foregroundStyle(.white.opacity(0.85))
            }
            Spacer(minLength: 26)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                    .font(.system(size: 56, weight: .semibold, design: .rounded)).tracking(-2)
                if showUnit { Text("kWh").font(.system(size: 19, weight: .medium)).foregroundStyle(.white.opacity(0.8)) }
            }
            Text(value == nil ? "Connecte ton compteur pour charger tes mesures." : "Énergie consommée")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.8)).padding(.top, 7)
            Spacer(minLength: 22)
            HStack {
                Text("LINKY MONITOR")
                Spacer()
                Image(systemName: "bolt.horizontal.circle.fill")
            }
            .font(.system(size: 9, weight: .bold)).tracking(1.1).foregroundStyle(.white.opacity(0.75))
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 232, alignment: .leading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color.linkyGreen, Color(red: 0.08, green: 0.49, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct MetricCard: View {
    let title: String
    var value: Double? = nil
    var count: Int? = nil
    let symbol: String
    let tint: Color
    @AppStorage("linky.showUnit") private var showUnit = true
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.system(size: 9, weight: .bold)).tracking(0.45).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(count.map(String.init) ?? value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                if value != nil && showUnit { Text("kWh").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
            }
            Capsule().fill(tint.opacity(0.2)).frame(height: 4).overlay(alignment: .leading) { Capsule().fill(tint).frame(width: count == nil ? 58 : 92, height: 4) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct ConsumptionChart: View {
    let samples: [ConsumptionSample]
    var title: String = "Historique"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text("Consommation quotidienne en kWh").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chart.xyaxis.line").foregroundStyle(Color.linkyGreen)
            }
            if samples.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "chart.bar.xaxis").font(.system(size: 25)).foregroundStyle(.secondary)
                    Text("Aucune donnée").font(.system(size: 13, weight: .semibold))
                    Text("Les mesures apparaîtront ici après la connexion.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                Chart(samples) { sample in
                    AreaMark(x: .value("Jour", sample.date), y: .value("kWh", sample.value))
                        .foregroundStyle(LinearGradient(colors: [Color.linkyGreen.opacity(0.25), Color.linkyGreen.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Jour", sample.date), y: .value("kWh", sample.value))
                        .foregroundStyle(Color.linkyGreen).lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .interpolationMethod(.catmullRom)
                    PointMark(x: .value("Jour", sample.date), y: .value("kWh", sample.value))
                        .foregroundStyle(Color.linkyGreen).symbolSize(18)
                }
                .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine().foregroundStyle(Color.primary.opacity(0.07)); AxisValueLabel().foregroundStyle(.secondary) } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { value in AxisGridLine().foregroundStyle(Color.primary.opacity(0.04)); AxisValueLabel(format: .dateTime.day().month(.abbreviated)).foregroundStyle(.secondary) } }
                .frame(height: 190)
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct HistoryView: View {
    @ObservedObject var model: LinkyModel
    @AppStorage("linky.showUnit") private var showUnit = true
    @AppStorage("linky.selectedPeriod") private var selectedPeriod = ConsumptionPeriod.month.rawValue
    private var period: ConsumptionPeriod { ConsumptionPeriod(rawValue: selectedPeriod) ?? .month }
    private var visibleSamples: [ConsumptionSample] {
        guard let last = model.samples.last else { return [] }
        let end = Calendar.current.startOfDay(for: last.date)
        let start = Calendar.current.date(byAdding: .day, value: -(period.days - 1), to: end) ?? end
        return model.samples.filter { $0.date >= start && $0.date <= end }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 20) {
                    PageHeading(eyebrow: "MES MESURES", title: "Historique", subtitle: "Tes consommations quotidiennes récentes.")
                    Spacer(minLength: 8)
                    PeriodPicker(selection: $selectedPeriod)
                }
                ConsumptionChart(samples: visibleSamples, title: "Derniers \(period.label)")
                if !visibleSamples.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("JOUR PAR JOUR").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary).padding(16)
                        ForEach(visibleSamples.reversed()) { sample in
                            HStack {
                                Text(sample.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(sample.value.formatted(.number.precision(.fractionLength(2))) + (showUnit ? " kWh" : ""))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 11)
                            if sample.id != visibleSamples.first?.id { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
                }
            }.padding(28)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await model.refresh() } } label: { Label("Actualiser", systemImage: "arrow.clockwise") } } }
    }
}

private struct ConnectionView: View {
    @ObservedObject var model: LinkyModel
    @AppStorage("linky.prm") private var prm = ""
    @State private var token = ""
    @State private var showSaved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeading(eyebrow: "ACCÈS AUX DONNÉES", title: "Connexion", subtitle: "Relie ton espace Linky à l’application.")
                VStack(alignment: .leading, spacing: 19) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.shield.fill").font(.system(size: 24)).foregroundStyle(Color.linkyGreen)
                            .frame(width: 48, height: 48).background(Color.linkyGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.isConnected ? "Token enregistré sur ce Mac" : "Connexion Conso API")
                                .font(.system(size: 15, weight: .semibold))
                            Text("Le token est conservé dans le Trousseau macOS.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.isConnected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.linkyGreen) }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PRM / PDL").font(.system(size: 12, weight: .semibold))
                        TextField("14 chiffres", text: $prm).textFieldStyle(.roundedBorder).frame(maxWidth: 330)
                            .onChange(of: prm) { newValue in prm = String(newValue.filter { $0 >= "0" && $0 <= "9" }.prefix(14)) }
                        Text("Il reste enregistré uniquement sur ce Mac.").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TOKEN CONSO API").font(.system(size: 12, weight: .semibold))
                        SecureField("Colle ton token ici", text: $token).textFieldStyle(.roundedBorder).frame(maxWidth: 480)
                        Text("Le token ne sera pas affiché après enregistrement.").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 10) {
                        Button {
                            guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            model.saveToken(token)
                            token = ""
                            showSaved = true
                            Task { await model.refresh() }
                        } label: {
                            Label(model.isLoading ? "Connexion…" : "Enregistrer et tester", systemImage: "link")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent).tint(Color.linkyGreen).disabled(token.isEmpty || model.isLoading || prm.count != 14)
                        if model.isConnected {
                            Button("Déconnecter", role: .destructive) { model.disconnect() }.buttonStyle(.bordered)
                        }
                    }
                    if showSaved { Text("Token enregistré dans le Trousseau macOS.").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.linkyGreen) }
                    if let message = model.message { InlineNotice(message: message, isError: true) }
                }
                .padding(22)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                VStack(alignment: .leading, spacing: 10) {
                    Label("Comment obtenir le token ?", systemImage: "questionmark.circle").font(.system(size: 13, weight: .semibold))
                    Text("Dans Conso API, lance le consentement et valide le partage depuis Enedis. À la fin, copie le token affiché puis colle-le dans le champ ci-dessus.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Link(destination: URL(string: "https://conso.boris.sh/")!) { Label("Ouvrir Conso API", systemImage: "arrow.up.right.square") }.font(.system(size: 12, weight: .medium))
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.linkyGreen.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
            }.padding(28)
        }
    }
}

private struct PreferencesView: View {
    @AppStorage("linky.refreshOnOpen") private var refreshOnOpen = true
    @AppStorage("linky.showUnit") private var showUnit = true
    @AppStorage("linky.pricePerKWh") private var pricePerKWh = 0.0
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(eyebrow: "PERSONNALISATION", title: "Préférences", subtitle: "Adapte l’application à ta façon de suivre l’énergie.")
            VStack(alignment: .leading, spacing: 0) {
                ToggleRow(title: "Actualiser à l’ouverture", subtitle: "Charger les dernières données disponibles", isOn: $refreshOnOpen)
                Divider().padding(.leading, 18)
                ToggleRow(title: "Afficher l’unité kWh", subtitle: "Afficher les unités à côté des valeurs", isOn: $showUnit)
                Divider().padding(.leading, 18)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Prix du kWh").font(.system(size: 12, weight: .medium))
                        Text("Utilisé pour calculer le coût estimé, hors abonnement.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    TextField("0,00", value: $pricePerKWh, format: .number.precision(.fractionLength(2...4)))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 115)
                    Text("€/kWh").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 14)
                .onChange(of: pricePerKWh) { newValue in
                    if newValue < 0 { pricePerKWh = 0 }
                }
            }
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .padding(28)
    }
}

private struct DeveloperView: View {
    @ObservedObject var model: LinkyModel
    @AppStorage("linky.prm") private var prm = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeading(eyebrow: "OUTILS INTERNES", title: "Développement", subtitle: "Diagnostics locaux de la connexion Linky.")
            VStack(spacing: 0) {
                DiagnosticRow(title: "Token Conso API", value: model.isConnected ? "Enregistré · masqué" : "Absent", symbol: model.isConnected ? "checkmark.circle.fill" : "xmark.circle")
                Divider()
                DiagnosticRow(title: "Compteur", value: prm.isEmpty ? "Non configuré" : "Configuré · masqué", symbol: prm.isEmpty ? "minus.circle" : "checkmark.circle.fill")
                Divider()
                DiagnosticRow(title: "Mesures chargées", value: String(model.samples.count), symbol: "chart.bar.xaxis")
                Divider()
                DiagnosticRow(title: "Dernière requête", value: model.lastRequestAt?.formatted(date: .abbreviated, time: .shortened) ?? "Aucune", symbol: "clock")
                Divider()
                DiagnosticRow(title: "État API", value: model.lastRequestStatus, symbol: model.lastRequestStatus.hasPrefix("Échec") ? "exclamationmark.triangle" : "network")
            }
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 12) {
                Button { Task { await model.refresh() } } label: {
                    Label(model.isLoading ? "Test en cours…" : "Tester la connexion", systemImage: "arrow.trianglehead.2.clockwise")
                }
                .buttonStyle(.borderedProminent).tint(Color.linkyGreen).disabled(model.isLoading)
                Link("Documentation Conso API", destination: URL(string: "https://conso.boris.sh/documentation/")!)
            }
            Text("Les diagnostics indiquent seulement si les identifiants sont présents. Ils n’affichent jamais le token ni le numéro du compteur.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(28)
    }
}

private struct DiagnosticRow: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.linkyGreen).frame(width: 18)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 13)
    }
}

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(title, isOn: $isOn).labelsHidden()
        }.padding(.vertical, 14)
    }
}

private struct PageHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(Color.linkyGreen)
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).tracking(-0.6)
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(.bottom, 2)
    }
}

private struct InlineNotice: View {
    let message: String
    let isError: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? Color.orange : Color.blue)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background((isError ? Color.orange : Color.blue).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private extension Color {
    static let linkyGreen = Color(red: 0.13, green: 0.62, blue: 0.42)
    static let pageBackground = Color(nsColor: .windowBackgroundColor).opacity(0.78)
}
