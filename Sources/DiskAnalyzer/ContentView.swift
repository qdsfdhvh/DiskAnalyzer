import SwiftUI
import AppKit

// MARK: - Tab navigation

enum NavTab: String, CaseIterable {
    case analyze = "Analyze"
    case apps = "Apps"

    var icon: String {
        switch self {
        case .analyze: return "magnifyingglass"
        case .apps: return "square.grid.2x2"
        }
    }
}

// MARK: - Root view with left nav

struct ContentView: View {
    @StateObject private var app = AppViewModel()
    @State private var selectedTab: NavTab = .analyze

    var body: some View {
        HStack(spacing: 0) {
            navBar
            Rectangle().fill(DT.line).frame(width: 1)
            content
        }
        .frame(minWidth: 720, minHeight: 500)
        .preferredColorScheme(.light)
    }

    // MARK: Left nav bar

    private var navBar: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 16)

            ForEach(NavTab.allCases, id: \.self) { tab in
                navButton(tab: tab)
                Spacer().frame(height: 4)
            }

            Spacer()
        }
        .frame(width: 64)
        .background(DT.surface)
    }

    private func navButton(tab: NavTab) -> some View {
        let active = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.icon)
                    .font(.system(size: 17, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DT.accent : DT.fgMuted)
                    .frame(width: 28, height: 28)
                    .background(active ? DT.accentSoft : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(tab.rawValue)
                    .font(DT.text(9, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? DT.fg : DT.fgSubtle)
            }
            .frame(width: 56)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Content area

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .analyze:
            analyzeView
        case .apps:
            AppsView(app: app)
        }
    }

    // MARK: Analyze

    @ViewBuilder
    private var analyzeView: some View {
        if let session = app.selectedSession {
            ScanDetailView(session: session, app: app)
        } else {
            AnalysisStartView(app: app)
        }
    }
}

// MARK: - Quick chip pill

struct QuickChip: View {
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(DT.text(11, weight: .medium))
                .foregroundStyle(hover ? DT.accent : DT.fg)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(hover ? DT.accentSoft : DT.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(hover ? DT.accent.opacity(0.3) : DT.lineStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
