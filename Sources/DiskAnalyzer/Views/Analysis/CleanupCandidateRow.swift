import SwiftUI
import AppKit

/// One cleanup candidate row: approval/checkbox, name + reason, size, risk,
/// evidence disclosure, and Reveal in Finder. High-risk items show an
/// explicit "Approve" affordance instead of a checkbox until approved.
struct CleanupCandidateRow: View {
    let candidate: CleanupCandidate
    let isSelected: Bool
    let isApproved: Bool
    let onToggle: () -> Void
    let onApproveHighRisk: () -> Void

    @State private var isHovering = false
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                selectionControl
                    .frame(width: 74, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayPath)
                        .font(DT.text(13, weight: candidate.risk == .high ? .medium : .regular))
                        .foregroundStyle(DT.fg)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(reason)
                        .font(DT.text(11))
                        .foregroundStyle(DT.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(riskLabel)
                    .font(DT.text(10, weight: .medium))
                    .foregroundStyle(riskColor)

                Text(SizeFormatter.string(candidate.allocatedSize))
                    .font(DT.mono(12, weight: candidate.risk == .high ? .semibold : .regular))
                    .foregroundStyle(candidate.risk == .high ? DT.accent : DT.fg)
                    .monospacedDigit()
                    .frame(width: 92, alignment: .trailing)

                if !candidate.evidence.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) { showEvidence.toggle() }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DT.fgSubtle)
                            .rotationEffect(.degrees(showEvidence ? 90 : 0))
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, DT.rowVPadding)

            if showEvidence {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidate.evidence, id: \.self) { evidence in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(evidence.kind.rawValue)
                                .font(DT.mono(10))
                                .foregroundStyle(DT.fgSubtle)
                            Text(evidence.summary)
                                .font(DT.text(11))
                                .foregroundStyle(DT.fgMuted)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .padding(.leading, 6)
            }
        }
        .background(isHovering ? DT.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([candidate.url])
            }
            Button("Copy Path") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(candidate.url.path, forType: .string)
            }
        }
    }

    // MARK: Subviews

    private var selectionControl: some View {
        Button {
            if candidate.risk == .high && !isApproved {
                onApproveHighRisk()
            } else {
                onToggle()
            }
        } label: {
            if candidate.risk == .high && !isApproved {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 10))
                    Text("Approve")
                        .font(DT.text(11, weight: .medium))
                }
                .foregroundStyle(DT.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DT.accentSoft)
                .clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? DT.fg : DT.fgSubtle)
                    Text(isSelected ? "Selected" : "")
                        .font(DT.text(10))
                        .foregroundStyle(DT.fgSubtle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
    }

    private var reason: String {
        candidate.evidence.map(\.summary).joined(separator: " · ")
    }

    private var riskLabel: String {
        switch candidate.risk {
        case .low: return "Low risk"
        case .medium: return "Review"
        case .high: return "High risk"
        }
    }

    private var riskColor: Color {
        switch candidate.risk {
        case .low: return DT.fgSubtle
        case .medium: return DT.fgMuted
        case .high: return DT.accent
        }
    }
}
