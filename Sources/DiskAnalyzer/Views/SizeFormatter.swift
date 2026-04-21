import Foundation

enum SizeFormatter {
    private static let byteCountFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.includesUnit = true
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        byteCountFormatter.string(fromByteCount: bytes)
    }

    static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let value = Double(part) / Double(whole) * 100
        if value >= 10 { return String(format: "%.0f%%", value) }
        if value >= 1 { return String(format: "%.1f%%", value) }
        return String(format: "%.2f%%", value)
    }
}
