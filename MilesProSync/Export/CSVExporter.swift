import Foundation

enum CSVExporter {
    static func makeCSV(trips: [Trip], rate: ReimbursementRate, fixedAmount: Double = 0) -> String {
        var lines = [
            ExportColumns.titles(rate: rate)
                .map(csvField)
                .joined(separator: ","),
        ]

        for trip in trips {
            let fields = [
                Formatters.shortDate.string(from: trip.startDate),
                trip.startAddress ?? "",
                trip.endAddress ?? "",
                String(format: "%.1f", Reimbursement.displayedMiles(trip.distanceMiles)),
                trip.classification.displayName,
                trip.purpose ?? "",
                String(format: "%.2f", Reimbursement.amount(for: trip, rate: rate)),
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }

        let total = ExportFetcher.totalMiles(trips)
        let totalAmount = Reimbursement.total(trips, rate: rate) + fixedAmount
        lines.append("")
        if fixedAmount > 0 {
            lines.append([
                csvField("Fixed monthly amount (FAVR)"), "", "", "", "", "", String(format: "%.2f", fixedAmount),
            ].joined(separator: ","))
        }
        lines.append([
            csvField("Total"), "", "", String(format: "%.1f", total), "", "", String(format: "%.2f", totalAmount),
        ].joined(separator: ","))

        return lines.joined(separator: "\r\n")
    }

    static func export(trips: [Trip], filter: ExportFilter, rate: ReimbursementRate) throws -> URL {
        let fixed = Reimbursement.fixedAmount(trips: trips, filter: filter, rate: rate)
        let csv = makeCSV(trips: trips, rate: rate, fixedAmount: fixed)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ExportNaming.fileBaseName(filter: filter))
            .appendingPathExtension("csv")
        try Data(csv.utf8).write(to: url, options: .atomic)
        return url
    }

    private static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
