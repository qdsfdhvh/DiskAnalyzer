import SwiftUI

/// Quiet summary header. No giant serif, no stacked bar chart — one big
/// restrained number, a short factual subline, and the volume meter on the
/// right showing used-of-total as a single thin bar.
struct HeroPanelView: View {
    let root: FileNode
    let volumeTotal: Int64?
    let volumeFree: Int64?

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            totalBlock
            Spacer(minLength: 24)
            volumeBlock
        }
        .padding(.horizontal, DT.gutter)
        .padding(.top, 28)
        .padding(.bottom, 22)
    }

    private var totalBlock: some View {
        let parts = SizeFormatter.split(root.size)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(parts.number)
                    .font(DT.text(44, weight: .light))
                    .foregroundStyle(DT.fg)
                    .monospacedDigit()
                Text(parts.unit)
                    .font(DT.text(16, weight: .regular))
                    .foregroundStyle(DT.fgMuted)
            }
            .fixedSize()

            Text(root.name)
                .font(DT.text(12))
                .foregroundStyle(DT.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var volumeBlock: some View {
        if let total = volumeTotal, total > 0 {
            let usedFraction = min(1, max(0, Double(root.size) / Double(total)))
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    Text("\(Int(round(usedFraction * 100)))%")
                        .font(DT.mono(12, weight: .medium))
                        .foregroundStyle(DT.fg)
                        .monospacedDigit()
                    Text("of \(SizeFormatter.string(total)) volume")
                        .font(DT.text(11))
                        .foregroundStyle(DT.fgMuted)
                }

                // Thin volume meter — scanned-size as a share of the disk.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DT.line)
                        Capsule()
                            .fill(usedFraction > 0.85 ? DT.accent : DT.fg)
                            .frame(width: max(2, geo.size.width * usedFraction))
                    }
                }
                .frame(width: 260, height: 3)

                if let free = volumeFree {
                    Text("\(SizeFormatter.string(free)) free")
                        .font(DT.mono(10))
                        .foregroundStyle(DT.fgSubtle)
                        .monospacedDigit()
                }
            }
        } else {
            EmptyView()
        }
    }
}
