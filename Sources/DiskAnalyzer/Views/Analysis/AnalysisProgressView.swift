import SwiftUI

/// Renders every non-reviewing flow state: analyzing, preflighting, cleaning,
/// completed (placeholder until the result view lands), and failed.
struct AnalysisProgressView: View {
    @ObservedObject var viewModel: AnalysisFlowViewModel

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Spacer()

            switch viewModel.state {
            case .analyzing:
                ProgressView()
                    .controlSize(.small)
                statusText("Analyzing your disk…")
            case .preflighting:
                ProgressView()
                    .controlSize(.small)
                statusText("Checking files…")
            case .cleaning(let progress):
                ProgressView(
                    value: Double(progress.completedItems),
                    total: Double(max(1, progress.totalItems))
                )
                .frame(width: 240)
                statusText("Cleaning… \(progress.completedItems) of \(progress.totalItems)")
            case .completed(let result):
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(DT.fg)
                statusText("Done — \(result.movedCount) moved, \(result.skippedCount) skipped, \(result.failedCount) failed")
            case .failed(let error):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(DT.accent)
                statusText(error.message)
            default:
                ProgressView()
                    .controlSize(.small)
                statusText("Preparing…")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(DT.text(13))
            .foregroundStyle(DT.fgMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
    }
}
