import Foundation
import ZIPFoundation

/// Hand-built minimal OOXML (.xlsx) writer. Uses inline strings instead of a shared-strings
/// table to keep the format simple, at a negligible file-size cost for trip-log-sized exports.
enum XLSXExporter {
    static func export(trips: [Trip], filter: ExportFilter, rate: ReimbursementRate) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(ExportNaming.fileBaseName(filter: filter))
            .appendingPathExtension("xlsx")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        } catch {
            throw ExportError.archiveCreationFailed
        }

        try addEntry(to: archive, path: "[Content_Types].xml", contents: contentTypesXML)
        try addEntry(to: archive, path: "_rels/.rels", contents: rootRelsXML)
        try addEntry(to: archive, path: "xl/workbook.xml", contents: workbookXML)
        try addEntry(to: archive, path: "xl/_rels/workbook.xml.rels", contents: workbookRelsXML)
        try addEntry(to: archive, path: "xl/worksheets/sheet1.xml", contents: worksheetXML(trips: trips, rate: rate))

        return url
    }

    private static func addEntry(to archive: Archive, path: String, contents: String) throws {
        let data = Data(contents.utf8)
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
            provider: { position, size in
                data.subdata(in: Int(position)..<(Int(position) + size))
            }
        )
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
    <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """

    private static let rootRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """

    private static let workbookXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
    <sheets>
    <sheet name="Trips" sheetId="1" r:id="rId1"/>
    </sheets>
    </workbook>
    """

    private static let workbookRelsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """

    static func worksheetXML(trips: [Trip], rate: ReimbursementRate) -> String {
        var rows: [String] = [headerRow(rate: rate)]

        var rowIndex = 2
        for trip in trips {
            rows.append(dataRow(
                rowIndex: rowIndex,
                date: Formatters.shortDate.string(from: trip.startDate),
                start: trip.startAddress ?? "",
                end: trip.endAddress ?? "",
                miles: Reimbursement.displayedMiles(trip.distanceMiles),
                classification: trip.classification.displayName,
                amount: Reimbursement.amount(miles: trip.distanceMiles, rate: rate.perMile)
            ))
            rowIndex += 1
        }

        let total = ExportFetcher.totalMiles(trips)
        rows.append(totalRow(rowIndex: rowIndex, total: total, totalAmount: Reimbursement.total(trips, rate: rate.perMile)))

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <sheetData>
        \(rows.joined(separator: "\n"))
        </sheetData>
        </worksheet>
        """
    }

    private static func headerRow(rate: ReimbursementRate) -> String {
        let cells = ExportColumns.titles(rate: rate)
            .enumerated()
            .map { index, title in inlineStringCell(column: columnLetter(index), row: 1, value: title) }
            .joined()
        return "<row r=\"1\">\(cells)</row>"
    }

    private static func dataRow(rowIndex: Int, date: String, start: String, end: String, miles: Double, classification: String, amount: Double) -> String {
        var cells = ""
        cells += inlineStringCell(column: "A", row: rowIndex, value: date)
        cells += inlineStringCell(column: "B", row: rowIndex, value: start)
        cells += inlineStringCell(column: "C", row: rowIndex, value: end)
        cells += numberCell(column: "D", row: rowIndex, value: miles, decimals: 1)
        cells += inlineStringCell(column: "E", row: rowIndex, value: classification)
        cells += numberCell(column: "F", row: rowIndex, value: amount)
        return "<row r=\"\(rowIndex)\">\(cells)</row>"
    }

    private static func totalRow(rowIndex: Int, total: Double, totalAmount: Double) -> String {
        var cells = ""
        cells += inlineStringCell(column: "A", row: rowIndex, value: "Total")
        cells += numberCell(column: "D", row: rowIndex, value: total, decimals: 1)
        cells += numberCell(column: "F", row: rowIndex, value: totalAmount)
        return "<row r=\"\(rowIndex)\">\(cells)</row>"
    }

    private static func columnLetter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index)))
    }

    private static func inlineStringCell(column: String, row: Int, value: String) -> String {
        "<c r=\"\(column)\(row)\" t=\"inlineStr\"><is><t>\(xmlEscape(value))</t></is></c>"
    }

    private static func numberCell(column: String, row: Int, value: Double, decimals: Int = 2) -> String {
        "<c r=\"\(column)\(row)\"><v>\(String(format: "%.\(decimals)f", value))</v></c>"
    }

    private static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}
