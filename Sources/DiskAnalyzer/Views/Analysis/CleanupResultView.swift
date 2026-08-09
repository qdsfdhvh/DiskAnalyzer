import SwiftUI

/// Post-cleanup summary: moved/skipped/failed counts and per-item detail for
/// anything that did not move. Uses "moved to Trash", never "deleted".
struct CleanupResultView: View {
    let result: CleanupResult
    let bytesMoved: Int64
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Image(systemName: result.failedCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(result.failedCount == 0 ? DT.fg : DT.accent)
                Text("\(result.movedCount) moved to Trash · \(SizeFormatter.string(bytesMoved))")
                    .font(DT.text(13, weight: .medium))
                    .foregroundStyle(DT.fg)
                if result.skippedCount > 0 || result.failedCount > 0 {
                    Text("\(result.skippedCount) skipped · \(result.failedCount) failed")
                        .font(DT.text(12))
                        .foregroundStyle(DT.fgMuted)
                }
            }
            .padding(.vertical, 20)

            Rectangle().fill(DT.line).frame(height: 1)

            if !details.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(detail.status)
                                    .font(DT.mono(10))
                                    .foregroundStyle(detail.status == "Failed" ? DT.accent : DT.fgSubtle)
                                    .frame(width: 60, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(detail.path)
                                        .font(DT.text(11))
                                        .foregroundStyle(DT.fg)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let message = detail.message {
                                        Text(message)
                                            .font(DT.text(10))
                                            .foregroundStyle(DT.fgMuted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 5)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Spacer(minLength: 0)
            Rectangle().fill(DT.line).frame(height: 1)
            HStack {
                Spacer()
                Button("Back to plan") { onDone() }
                    .buttonStyle(QuietButtonStyle(variant: .ghost))
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DT.bg)
    }

    // MARK: Details

    private struct DetailRow {
        let status: String
        let path: String
        let message: String?
    }

    private var details: [DetailRow] {
        result.outcomes.compactMap { outcome in
            switch outcome {
            case .movedToTrash:
                return nil
            case .skipped(let displayPath, let reason):
                switch reason {
                case .cancelled:
                    return DetailRow(status: "Cancelled", path: displayPath, message: nil)
                case .rejected(let rejection):
                    return DetailRow(status: "Skipped", path: displayPath, message: rejection.errorDescription)
                }
            case .failed(let displayPath, let message):
                return DetailRow(status: "Failed", path: displayPath, message: message)
            }
        }
    }
}
