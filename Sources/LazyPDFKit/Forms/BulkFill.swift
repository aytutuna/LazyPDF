import Foundation

// Twin of windows/LazyPDF.Core/Forms/BulkFill.cs: one form and a CSV file of values give one PDF per data row. The first CSV
// row names the fields; a column no field has is listed in `unmatchedColumns` and skipped. An empty cell empties its field.
// Each PDF is made from the form's original bytes, so rows do not affect each other.

public final class BulkFill {
    private let form: [UInt8]
    private let password: String?
    private let fonts: FontSource?
    private let table: [[String]]

    public let columns: [String]
    public let unmatchedColumns: [String]

    private init(_ form: [UInt8], _ password: String?, _ fonts: FontSource?, _ columns: [String], _ rows: [[String]], _ unmatched: [String]) {
        self.form = form
        self.password = password
        self.fonts = fonts
        self.columns = columns
        table = rows
        unmatchedColumns = unmatched
    }

    public var rows: Int { table.count }

    /// Reads the form and the CSV text. Throws `PdfReadException` as `PdfDocument.open` does and for a dynamic XFA form.
    public static func create(_ form: [UInt8], _ csv: String, _ fonts: FontSource? = nil, _ password: String? = nil) throws -> BulkFill {
        let table = FormCsv.read(csv)
        let columns = table.first ?? []
        let probe = PdfForm.read(try PdfDocument.open(form, password: password), fonts)
        if probe.xfa == .dynamic { throw PdfReadException(.unsupported, FormText.dynamicXfa) }
        var unmatched: [String] = []
        for column in columns where !column.isEmpty && probe.find(column) == nil && !unmatched.containsOrdinal(column) {
            unmatched.append(column)
        }
        return BulkFill(form, password, fonts, columns, Array(table.dropFirst()), unmatched)
    }

    /// The PDF for data row `row` (from 0), written as an incremental update of the form, so a signature on it is kept;
    /// flattened when asked.
    public func fill(_ row: Int, flatten: Bool = false) throws -> [UInt8] {
        precondition(row >= 0 && row < table.count, "row")
        var values: [(String, String?)] = []
        for i in 0..<min(columns.count, table[row].count) where !columns[i].isEmpty && !unmatchedColumns.containsOrdinal(columns[i]) {
            values.append((columns[i], table[row][i]))
        }
        let document = try PdfDocument.open(form, password: password)
        let filled = PdfForm.read(document, fonts)
        try filled.setValues(values)
        if flatten { try filled.flatten() }
        return try document.saveIncremental()
    }
}
