import SwiftUI

/// Shows the exact items about to be moved, with the planned total, and
/// requires an explicit "Move to Trash" confirmation.
struct CleanupConfirmationView: View {
    let plan: CleanupPlan
    let viewModel: AnalysisFlowViewModel

    @Environment(\.dismiss) private var dismiss

    private var selectedCandidates: [CleanupCandidate] {
        plan.allCandidates.filter { viewModel.selectedCandidateIDs.contains($0.id) }
    }

    private var totalBytes: Int64 {
        selectedCandidates.reduce(0) { $0 + $1.allocatedSize }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Move to Trash")
                .font(DT.text(13, weight: .medium))
                .foregroundStyle(DT.fg)
                .padding(.vertical, 14)

            Rectangle().fill(DT.line).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(selectedCandidates) { candidate in
                        HStack(spacing: 10) {
                            Text(candidate.displayPath)
                                .font(DT.text(12))
                                .foregroundStyle(DT.fg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(SizeFormatter.string(candidate.allocatedSize))
                                .font(DT.mono(11))
                                .foregroundStyle(DT.fgMuted)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 8)
            }

            Rectangle().fill(DT.line).frame(height: 1)

            HStack(spacing: 12) {
                Text("\(selectedCandidates.count) items · \(SizeFormatter.string(totalBytes))")
                    .font(DT.mono(11, weight: .medium))
                    .foregroundStyle(DT.fg)
                    .monospacedDigit()
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(QuietButtonStyle(variant: .secondary))
                Button("Move to Trash") {
                    viewModel.executeCleanup()
                    dismiss()
                }
                .buttonStyle(QuietButtonStyle(variant: .primary))
            }
            .padding(16)
        }
        .frame(width: 520, height: 500)
        .background(DT.bg)
    }
}
