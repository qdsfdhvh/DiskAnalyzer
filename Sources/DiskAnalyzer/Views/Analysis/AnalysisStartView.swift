import SwiftUI

/// Primary start experience: pick a folder to analyze and an optional space
/// goal that shapes the recommendations.
struct AnalysisStartView: View {
    @ObservedObject var app: AppViewModel

    private let gb = Int64(1024 * 1024 * 1024)

    var body: some View {
        ZStack {
            DT.bg.ignoresSafeArea()

            VStack(alignment: .center, spacing: 0) {
                Spacer()

                VStack(spacing: 10) {
                    Text("Find space to reclaim")
                        .font(DT.text(22, weight: .semibold))
                        .foregroundStyle(DT.fg)
                    Text("Scan a folder, then review cleanup recommendations before anything moves to Trash.")
                        .font(DT.text(13))
                        .foregroundStyle(DT.fgMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(.bottom, 26)

                HStack(spacing: 10) {
                    Button("Scan Home") { app.addHome() }
                        .buttonStyle(QuietButtonStyle(variant: .primary))
                    Button("Choose Folder…") { app.pickAndAdd() }
                        .buttonStyle(QuietButtonStyle(variant: .secondary))
                }
                .padding(.bottom, 26)

                VStack(spacing: 10) {
                    Text("Goal")
                        .font(DT.text(11, weight: .medium))
                        .foregroundStyle(DT.fgMuted)
                    HStack(spacing: 6) {
                        goalChip("No target", bytes: nil)
                        goalChip("5 GB", bytes: 5 * gb)
                        goalChip("20 GB", bytes: 20 * gb)
                        goalChip("50 GB", bytes: 50 * gb)
                    }
                }
                .padding(.bottom, 34)

                VStack(spacing: 14) {
                    Text("Quick scan")
                        .font(DT.text(11, weight: .medium))
                        .foregroundStyle(DT.fgMuted)
                    HStack(spacing: 6) {
                        ForEach(AppViewModel.quickLocations, id: \.label) { loc in
                            QuickChip(label: loc.label) {
                                let path = (loc.path as NSString).expandingTildeInPath
                                app.addSession(url: URL(fileURLWithPath: path))
                            }
                        }
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private func goalChip(_ label: String, bytes: Int64?) -> some View {
        let selected = app.targetBytes == bytes
        return Button {
            app.targetBytes = bytes
        } label: {
            Text(label)
                .font(DT.text(11, weight: .medium))
                .foregroundStyle(selected ? DT.accent : DT.fg)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(selected ? DT.accentSoft : DT.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(selected ? DT.accent.opacity(0.3) : DT.lineStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 999, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
