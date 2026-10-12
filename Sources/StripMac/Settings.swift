import Foundation

enum CenterMode: String, CaseIterable, Identifiable {
    case never, onOverflow, always
    var id: String { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .onOverflow: return "When strip overflows"
        case .always: return "Always"
        }
    }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var gap: Double { didSet { d.set(gap, forKey: "gap"); changed() } }
    @Published var defaultWidth: Double { didSet { d.set(defaultWidth, forKey: "defaultWidth"); changed() } }
    @Published var presetsText: String { didSet { d.set(presetsText, forKey: "presets"); changed() } }
    @Published var centerMode: CenterMode { didSet { d.set(centerMode.rawValue, forKey: "centerMode"); changed() } }
    @Published var gesturesEnabled: Bool { didSet { d.set(gesturesEnabled, forKey: "gestures") } }
    @Published var showMinimap: Bool { didSet { d.set(showMinimap, forKey: "minimap") } }
    @Published var excludedBundleIDs: String { didSet { d.set(excludedBundleIDs, forKey: "excluded"); changed() } }
    /// CGDirectDisplayID of the strip's display; 0 = the primary display.
    @Published var stripDisplayID: Int { didSet { d.set(stripDisplayID, forKey: "stripDisplay"); changed() } }

    var onChange: (() -> Void)?

    private init() {
        gap = d.object(forKey: "gap") as? Double ?? 10
        defaultWidth = d.object(forKey: "defaultWidth") as? Double ?? 0.5
        presetsText = d.string(forKey: "presets") ?? "0.33, 0.5, 0.66, 0.75, 1.0"
        centerMode = CenterMode(rawValue: d.string(forKey: "centerMode") ?? "") ?? .onOverflow
        gesturesEnabled = d.object(forKey: "gestures") as? Bool ?? true
        showMinimap = d.object(forKey: "minimap") as? Bool ?? true
        excludedBundleIDs = d.string(forKey: "excluded") ?? "com.apple.calculator, com.apple.systempreferences"
        stripDisplayID = d.integer(forKey: "stripDisplay")
    }

    var presets: [Double] {
        let v = presetsText.split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0.05 && $0 <= 1.0 }
            .sorted()
        return v.isEmpty ? [0.5] : v
    }

    var excluded: Set<String> {
        Set(excludedBundleIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    private func changed() { onChange?() }
}
