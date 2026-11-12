import Foundation

// Twin of windows/LazyPDF.Core/Redaction/PdfRedactor.Values.cs: rewrites the matched text in annotation contents and field
// values; a value that no longer reads as it did when found is left alone. The text found is looked for in the output like
// any other removed text.

extension PdfRedactor {
    private struct ValueKey: Hashable {
        let page: Int
        let annotation: Int
    }

    func rewriteValues(_ work: PdfDocument, _ values: [RedactionValueMatch], _ options: RedactionOptions, _ needles: inout NeedleSet) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        let replacement = options.overlayText ?? ""
        let writer = PdfAnnotationWriter(work, fonts)
        var groups: [ValueKey: [RedactionValueMatch]] = [:]
        for v in values where v.page >= 0 && v.page < work.pages.count && v.length > 0 {
            groups[ValueKey(page: v.page, annotation: v.annotation), default: []].append(v)
        }
        // Annotations are looked up before anything is removed, because a removal shifts the indexes after it.
        var pages: [Int: [PdfAnnotation]] = [:]
        var targets: [(key: ValueKey, annotation: PdfAnnotation)] = []
        for key in groups.keys.sorted(by: { ($0.page, $0.annotation) < ($1.page, $1.annotation) }) {
            if pages[key.page] == nil { pages[key.page] = PdfAnnotations.read(work, work.pages[key.page]) }
            guard let annotations = pages[key.page], key.annotation >= 0, key.annotation < annotations.count else { continue }
            targets.append((key, annotations[key.annotation]))
        }
        for (key, annotation) in targets {
            let hits = (groups[key] ?? []).sorted { $0.start > $1.start }
            let done = annotation.type == .widget
                ? rewriteField(work, annotation, hits, replacement, &needles)
                : rewriteComment(work, writer, annotation, hits, replacement, &needles)
            if done { counts[key.page, default: 0] += 1 }
        }
        return counts
    }

    private static func rewritten(_ current: String?, _ hits: [RedactionValueMatch], _ replacement: String) -> String? {
        guard let current else { return nil }
        let before = Array(current.utf16)
        var text = before
        var limit = text.count
        for hit in hits {
            let found = Array(hit.text.utf16)
            if found.count != hit.length || hit.start < 0 || hit.start + hit.length > limit || Array(text[hit.start..<hit.start + hit.length]) != found { continue }
            text.replaceSubrange(hit.start..<hit.start + hit.length, with: Array(replacement.utf16))
            limit = hit.start
        }
        return text == before ? nil : String(units: text)
    }

    private static func replacing(_ text: String, _ hits: [RedactionValueMatch], _ replacement: String) -> String {
        hits.reduce(text) { $0.replacingOccurrences(of: $1.text, with: replacement, options: .literal) }
    }

    private func rewriteComment(_ work: PdfDocument, _ writer: PdfAnnotationWriter, _ annotation: PdfAnnotation, _ hits: [RedactionValueMatch],
                                _ replacement: String, _ needles: inout NeedleSet) -> Bool {
        guard let text = Self.rewritten(annotation.contents, hits, replacement) else { return false }
        for hit in hits { Self.addNeedle(&needles, hit.text) }
        do {
            _ = try writer.setContents(annotation, text)
        } catch {
            // A free text box that cannot be drawn again with the new text goes whole.
            return writer.delete(annotation)
        }
        // Rich text and the subject can repeat the words; neither is drawn.
        annotation.dictionary.remove("RC")
        if let subject = PdfText.read(work, annotation.dictionary, "Subject") {
            let changed = Self.replacing(subject, hits, replacement)
            if changed != subject { annotation.dictionary["Subject"] = PdfText.toObject(changed) }
        }
        return true
    }

    private func rewriteField(_ work: PdfDocument, _ widget: PdfAnnotation, _ hits: [RedactionValueMatch], _ replacement: String,
                              _ needles: inout NeedleSet) -> Bool {
        let form = PdfForm.read(work, fonts)
        guard let field = RedactionValues.fieldOf(form, widget.dictionary), RedactionValues.isText(field),
              let text = Self.rewritten(field.value, hits, replacement) else { return false }
        for hit in hits { Self.addNeedle(&needles, hit.text) }
        do {
            if try !form.setValue(field.name, text).rejected.isEmpty { _ = try form.setValue(field.name, "") }
        } catch {
            do { try form.remove(field) } catch { return false }
            return true
        }
        // The default value and the rich value can repeat the words; neither is drawn from the value.
        field.dictionary.remove("RV")
        if let dv = field.defaultValue {
            let changed = Self.replacing(dv, hits, replacement)
            if changed != dv { field.dictionary["DV"] = PdfText.toObject(changed) }
        }
        return true
    }
}
