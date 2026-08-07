import CCQuotaCore
import SwiftUI

@main
struct CCQuotaApp: App {
    @State private var model = QuotaModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(state: model.state)
        }
        // .window rather than .menu so the popover can host progress bars and
        // per-account controls instead of a flat list of menu items.
        .menuBarExtraStyle(.window)

        Window("CCQuota 설정", id: SettingsWindowID.value) {
            SettingsWindow(model: model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

enum SettingsWindowID {
    static let value = "settings"
}

private struct MenuBarLabel: View {
    let state: SharedStateFile?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbolName)
            if let text = percentText {
                Text(text).font(.system(size: 11, weight: .medium).monospacedDigit())
            }
        }
    }

    private var active: AccountSnapshot? { state?.activeAccount }

    private var percentText: String? {
        active?.compactLabel
    }

    /// The menu bar renders template images monochrome, so the fill level of the
    /// gauge — not colour — has to carry the signal at a glance.
    private var symbolName: String {
        guard let percent = active?.headlinePercent else { return "gauge.with.dots.needle.bottom.50percent" }
        switch percent {
        case ..<34: return "gauge.with.dots.needle.bottom.0percent"
        case ..<67: return "gauge.with.dots.needle.bottom.50percent"
        case ..<100: return "gauge.with.dots.needle.bottom.100percent"
        default: return "exclamationmark.triangle.fill"
        }
    }
}
