import Foundation
import UIKit

enum PDFExporter {
    /// Date, Start, End, Miles, Classification, Reimbursement — sums to the 540pt printable width.
    private static let columnWidths: [CGFloat] = [52, 125, 125, 38, 78, 122]
    private static let columnGap: CGFloat = 6
    private static let rowSpacing: CGFloat = 5

    private static let headerFont = UIFont.boldSystemFont(ofSize: 10)
    private static let bodyFont = UIFont.systemFont(ofSize: 9)

    static func export(trips: [Trip], filter: ExportFilter, rate: ReimbursementRate) throws -> URL {
        let pageWidth: CGFloat = 612 // US Letter, 72 dpi
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 36
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let bottom = pageHeight - margin

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ExportNaming.fileBaseName(filter: filter))
            .appendingPathExtension("pdf")

        let headers = ExportColumns.titles(rate: rate)

        try renderer.writePDF(to: url) { context in
            context.beginPage()
            var y = drawTitle(filter: filter, margin: margin, y: margin) + 16
            drawRow(headers, font: headerFont, margin: margin, y: &y)

            for trip in trips {
                let values = [
                    Formatters.shortDate.string(from: trip.startDate),
                    trip.startAddress ?? "",
                    trip.endAddress ?? "",
                    String(format: "%.1f", Reimbursement.displayedMiles(trip.distanceMiles)),
                    trip.classification.displayName,
                    rate.format(Reimbursement.amount(miles: trip.distanceMiles, rate: rate.perMile)),
                ]
                if y + rowHeight(values, font: bodyFont) > bottom {
                    context.beginPage()
                    y = margin
                    drawRow(headers, font: headerFont, margin: margin, y: &y)
                }
                drawRow(values, font: bodyFont, margin: margin, y: &y)
            }

            let totals = [
                "Total", "", "",
                String(format: "%.1f", ExportFetcher.totalMiles(trips)),
                "",
                rate.format(Reimbursement.total(trips, rate: rate.perMile)),
            ]
            if y + 8 + rowHeight(totals, font: headerFont) > bottom {
                context.beginPage()
                y = margin
            }
            y += 8
            drawRow(totals, font: headerFont, margin: margin, y: &y)
        }

        return url
    }

    private static func drawTitle(filter: ExportFilter, margin: CGFloat, y: CGFloat) -> CGFloat {
        let title = "Miles Pro Sync — \(filter.monthTitle) (\(filter.classificationLabel))"
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 16)]
        (title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attributes)
        return y + 22
    }

    /// Height of the tallest cell once text wraps within its column.
    private static func rowHeight(_ values: [String], font: UIFont) -> CGFloat {
        values.enumerated().map { index, value in
            textHeight(value, width: columnWidths[index] - columnGap, font: font)
        }.max() ?? 0
    }

    private static func textHeight(_ value: String, width: CGFloat, font: UIFont) -> CGFloat {
        let bounds = (value as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return max(ceil(bounds.height), ceil(font.lineHeight))
    }

    private static func drawRow(_ values: [String], font: UIFont, margin: CGFloat, y: inout CGFloat) {
        let height = rowHeight(values, font: font)
        var x = margin
        for (index, value) in values.enumerated() {
            let width = columnWidths[index]
            let rect = CGRect(x: x, y: y, width: width - columnGap, height: height)
            (value as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            )
            x += width
        }
        y += height + rowSpacing
    }
}
