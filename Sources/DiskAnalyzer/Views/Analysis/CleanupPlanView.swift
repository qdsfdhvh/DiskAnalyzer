import SwiftUI

/// Renders the reviewing state: plan summary, selection totals, risk groups,
/// and candidate rows. Execution (confirmation/result) lands in a later task.
struct CleanupPlanView: View {
    @ObservedObject var viewModel: AnalysisFlowViewModel
    let plan: CleanupPlan

    @State private var showConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Rectangle().fill(DT.line).frame(height: 1)

            if plan.allCandidates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(plan.groups) { group in
                            groupSection(group)
                        }
                    }
                    .padding(.horizontal, DT.gutter - 8)
                    .padding(.vertical, 10)
                }
                .background(DT.bg)
            }
        }
        .sheet(isPresented: $showConfirmation) {
            CleanupConfirmationView(plan: plan, viewModel: viewModel)
        }
    }

    // MARK: Summary

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Recommendations")
                    .font(DT.text(13, weight: .medium))
                    .foregroundStyle(DT.fg)
                Spacer()
                Text("\(plan.allCandidates.count) items · \(SizeFormatter.string(totalBytes))")
                    .font(DT.mono(11))
                    .foregroundStyle(DT.fgMuted)
                    .monospacedDigit()
                Text("Selected: \(selectedCount) · \(SizeFormatter.string(selectedBytes))")
                    .font(DT.mono(11, weight: .medium))
                    .foregroundStyle(DT.fg)
                    .monospacedDigit()
                Button("Clean Selected…") {
                    if selectedCount > 0 { showConfirmation = true }
                }
                .buttonStyle(QuietButtonStyle(variant: .primary))
                .disabled(selectedCount == 0)
            }

            if let notice = viewModel.notice {
                Text(notice)
                    .font(DT.text(11))
                    .foregroundStyle(DT.fgMuted)
            }
        }
        .padding(.horizontal, DT.gutter)
        .padding(.vertical, 12)
        .background(DT.bg)
    }

    private var emptyState: some View {
        VStack(alignment: .center, spacing: 0) {
            Spacer()
            VStack(spacing: 10) {
                Text("Nothing to suggest")
                    .font(DT.text(22, weight: .semibold))
                    .foregroundStyle(DT.fg)
                Text("No clear cleanup candidates were found in this folder.")
                    .font(DT.text(13))
                    .foregroundStyle(DT.fgMuted)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    // MARK: Groups

    private func groupSection(_ group: CleanupPlanGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title)
                .font(DT.text(13, weight: .medium))
                .foregroundStyle(DT.fg)
            Text(group.explanation)
                .font(DT.text(11))
                .foregroundStyle(DT.fgMuted)
                .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(group.candidates) { candidate in
                    CleanupCandidateRow(
                        candidate: candidate,
                        isSelected: viewModel.selectedCandidateIDs.contains(candidate.id),
                        isApproved: viewModel.explicitlyApprovedIDs.contains(candidate.id),
                        onToggle: {
                            viewModel.setSelection(
                                candidate.id,
                                isSelected: !viewModel.selectedCandidateIDs.contains(candidate.id),
                                plan: plan
                            )
                        },
                        onApproveHighRisk: {
                            viewModel.approveHighRisk(candidate.id)
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.vertical, 10)
    }

    // MARK: Totals

    private var totalBytes: Int64 {
        plan.allCandidates.reduce(0) { $0 + $1.allocatedSize }
    }

    private var selectedBytes: Int64 {
        plan.allCandidates
            .filter { viewModel.selectedCandidateIDs.contains($0.id) }
            .reduce(0) { $0 + $1.allocatedSize }
    }

    private var selectedCount: Int {
        viewModel.selectedCandidateIDs.count
    }
}

// MARK: - State switch

/// Renders whatever the analysis flow is currently doing.
struct AnalysisFlowView: View {
    @ObservedObject var viewModel: AnalysisFlowViewModel

    var body: some View {
        switch viewModel.state {
        case .reviewing(let plan):
            CleanupPlanView(viewModel: viewModel, plan: plan)
        case .completed(let result):
            CleanupResultView(
                result: result,
                bytesMoved: viewModel.lastExecutedBytes,
                onDone: { viewModel.returnToPlan() }
            )
        default:
            AnalysisProgressView(viewModel: viewModel)
        }
    }
}
