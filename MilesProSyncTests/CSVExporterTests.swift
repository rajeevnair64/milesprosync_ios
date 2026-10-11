import Foundation
import Testing
@testable import MilesProSync

struct CSVExporterTests {
    @Test func includesHeaderRowsAndTotal() {
        let trip = Trip(
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 600),
            distanceMiles: 12.34, startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            startAddress: "123 Main St", endAddress: "456 Oak Ave", classification: .business
        )

        let csv = CSVExporter.makeCSV(trips: [trip], rate: ReimbursementRate(perMile: 0.725))

        #expect(csv.contains("Date,Start,End,Miles,Classification,Purpose,Reimbursement ($0.725/mi)"))
        #expect(csv.contains("123 Main St"))
        #expect(csv.contains("456 Oak Ave"))
        #expect(csv.contains("12.3"))
        #expect(csv.contains("Business"))
        #expect(csv.contains("Total"))
    }

    @Test func quotesFieldsContainingCommas() {
        let trip = Trip(
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 600),
            distanceMiles: 1, startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            startAddress: "123 Main St, Suite 4", endAddress: "456 Oak Ave"
        )

        let csv = CSVExporter.makeCSV(trips: [trip], rate: ReimbursementRate(perMile: 0.725))

        #expect(csv.contains("\"123 Main St, Suite 4\""))
    }

    @Test func escapesEmbeddedQuotes() {
        let trip = Trip(
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 600),
            distanceMiles: 1, startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            startAddress: "The \"Old\" Mill Rd", endAddress: "456 Oak Ave"
        )

        let csv = CSVExporter.makeCSV(trips: [trip], rate: ReimbursementRate(perMile: 0.725))

        #expect(csv.contains("\"The \"\"Old\"\" Mill Rd\""))
    }

    @Test func reimbursementColumnMultipliesMilesByRate() {
        let trip = Trip(
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 600),
            distanceMiles: 10, startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            startAddress: "A", endAddress: "B", classification: .business
        )
        let other = Trip(
            startDate: Date(timeIntervalSince1970: 0), endDate: Date(timeIntervalSince1970: 600),
            distanceMiles: 4, startLatitude: 0, startLongitude: 0, endLatitude: 0, endLongitude: 0,
            startAddress: "B", endAddress: "A", classification: .business
        )

        let lines = CSVExporter.makeCSV(trips: [trip, other], rate: ReimbursementRate(perMile: 0.5)).components(separatedBy: "\r\n")

        #expect(lines[0].hasSuffix("Reimbursement ($0.50/mi)"))
        #expect(lines[1].hasSuffix(",10.0,Business,,5.00"))
        #expect(lines[2].hasSuffix(",4.0,Business,,2.00"))
        #expect(lines.last == "Total,,,14.0,,,7.00")
    }
}
