import Foundation

enum CSVExporter {
    static func makeCSV(trips: [Trip], rate: ReimbursementRate) -> String {
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
                String(format: "%.2f", Reimbursement.amount(miles: trip.distanceMiles, rate: rate.perMile)),
            ]
            lines.append(fields.map(csvField).joined(separator: ","))
        }

        let total = ExportFetcher.totalMiles(trips)
        let totalAmount = Reimbursement.total(trips, rate: rate.perMile)
        lines.append("")
        lines.append([
            csvField("Total"), "", "", String(format: "%.1f", total), "", String(format: "%.2f", totalAmount),
        ].joined(separator: ","))

        return lines.joined(separator: "\r\n")
    }

    static func export(trips: [Trip], filter: ExportFilter, rate: ReimbursementRate) throws -> URL {
        let csv = makeCSV(trips: trips, rate: rate)
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
