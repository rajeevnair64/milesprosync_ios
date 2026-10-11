import Foundation
import PDFKit
import Testing
@testable import MilesProSync

struct ExportFileTests {
    private let filter = ExportFilter(year: 2026, month: 3)
    private let rate = ReimbursementRate(perMile: 0.725)

    private func trip(miles: Double, start: String, end: String) -> Trip {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        return Trip(
            startDate: date, endDate: date, distanceMiles: miles,
            startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            startAddress: start, endAddress: end, classification: .business
        )
    }

    @Test func pdfKeepsFullWrappedAddresses() throws {
        let start = "4059 Some Very Long Boulevard Name, South San Francisco, CA"
        let end = "500 Market St, San Francisco, CA"
        let url = try PDFExporter.export(trips: [trip(miles: 7.15, start: start, end: end)], filter: filter, rate: rate)

        let text = try #require(PDFDocument(url: url)?.string)
        let flattened = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        #expect(flattened.contains("South San Francisco, CA"))
        #expect(flattened.contains("San Francisco, CA"))
        #expect(flattened.contains("$5.22"))
        #expect(flattened.contains("Reimbursement ($0.725/mi)"))
    }

    @Test func pdfPaginatesLongMonths() throws {
        let trips = (0..<80).map { trip(miles: Double($0), start: "123 Elm St, San Francisco, CA", end: "500 Market St, San Francisco, CA") }
        let url = try PDFExporter.export(trips: trips, filter: filter, rate: rate)
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount > 1)
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("Total") == true)
    }

    @Test func xlsxExportIsCreated() throws {
        let url = try XLSXExporter.export(trips: [trip(miles: 7.15, start: "A", end: "B")], filter: filter, rate: rate)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect((size ?? 0) > 0)
    }

    @Test func xlsxMilesMatchReimbursementColumn() {
        let xml = XLSXExporter.worksheetXML(trips: [trip(miles: 7.15, start: "A", end: "B")], rate: rate)
        #expect(xml.contains("<c r=\"D2\"><v>7.2</v></c>")) // 7.2 × 0.725 = 5.22
        #expect(xml.contains("<c r=\"G2\"><v>5.22</v></c>"))
        #expect(xml.contains("Reimbursement ($0.725/mi)"))
    }
}
