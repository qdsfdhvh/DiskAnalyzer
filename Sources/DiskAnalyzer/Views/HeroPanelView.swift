import SwiftUI

/// Quiet summary header. No giant serif, no stacked bar chart — one big
/// restrained number, a short factual subline, and the volume meter on the
/// right showing used-of-total as a single thin bar.
struct HeroPanelView: View {
    let root: FileNode
    let volumeTotal: Int64?
    let volumeFree: Int64?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            totalBlock
                .layoutPriority(1)
            Spacer(minLength: 16)
            volumeBlock
                .frame(maxWidth: 280, alignment: .trailing)
                .layoutPriority(0)
        }
        .padding(.horizontal, DT.gutter)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalBlock: some View {
        let parts = SizeFormatter.split(root.size)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.number)
                    .font(DT.text(40, weight: .light))
                    .foregroundStyle(DT.fg)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(parts.unit)
                    .font(DT.text(15, weight: .regular))
                    .foregroundStyle(DT.fgMuted)
            }

            Text(root.name)
                .font(DT.text(12))
                .foregroundStyle(DT.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var volumeBlock: some View {
        if let total = volumeTotal, total > 0, let free = volumeFree {
            let used = max(0, total - free)
            let usedFraction = min(1, max(0, Double(used) / Double(total)))
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    Text("\(Int(round(usedFraction * 100)))%")
                        .font(DT.mono(12, weight: .medium))
                        .foregroundStyle(DT.fg)
                        .monospacedDigit()
                    Text("of \(SizeFormatter.string(total)) volume")
                        .font(DT.text(11))
                        .foregroundStyle(DT.fgMuted)
                        .lineLimit(1)
                }

                // Thin volume meter — volume used (total − free) as a share of
                // the disk. Matches what "About This Mac" / Finder report.
                // Width flexes with the block; no fixed 260pt so it can't overflow.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DT.line)
                        Capsule()
                            .fill(usedFraction > 0.85 ? DT.accent : DT.fg)
                            .frame(width: max(2, geo.size.width * usedFraction))
                    }
                }
                .frame(maxWidth: 260, minHeight: 3, maxHeight: 3)

                Text("Scanned \(SizeFormatter.string(root.size)) of \(SizeFormatter.string(used)) used · \(SizeFormatter.string(free)) free")
                    .font(DT.mono(10))
                    .foregroundStyle(DT.fgSubtle)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else {
            EmptyView()
        }
    }
}
