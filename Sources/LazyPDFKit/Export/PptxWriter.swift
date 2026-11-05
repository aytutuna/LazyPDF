import Foundation

// Twin of windows/LazyPDF.Core/Export/PptxWriter.cs: the PowerPoint file (.pptx) of an `ExportDocument`: a slide for each
// page, sized as the first page, with its pictures in place and every text line in a box of its own at its position, so
// the slide looks like the page and each line can still be edited.

private typealias Xml = ExportXml

public enum PptxWriter {
    private static let a = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let p = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let relNs = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let minSlide = 914400, maxSlide = 51206400

    // Slides are held as strings until the package is made, then copied to bytes; a picture adds a relationship to its slide besides its markup.
    private static let maxSlideChars = 1 << 27
    private static let relChars = 256
    private static let fixedEntries = 9

    public static func make(_ document: ExportDocument) throws -> [UInt8] {
        let first = document.pages.first
        let width = first.map { $0.width > 0 ? min(max(Xml.emu($0.width), minSlide), maxSlide) : 9144000 } ?? 9144000
        let height = first.map { $0.height > 0 ? min(max(Xml.emu($0.height), minSlide), maxSlide) : 6858000 } ?? 6858000

        var media: [ExportImage] = []
        var mediaIndex: [ObjectIdentifier: Int] = [:]
        try ExportZip.checkCount(fixedEntries + 2 * document.pages.count)
        var slides: [(xml: String, images: [Int])] = []
        var held = 0
        for page in document.pages {
            let slide = try self.slide(page, width, height, &media, &mediaIndex, held)
            slides.append((slide.xml, slide.images))
            held += slide.length + relChars * slide.images.count
        }
        try ExportZip.checkCount(fixedEntries + 2 * slides.count + media.count)

        var types = Xml.header
        types += "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        if media.contains(where: { $0.isJpeg }) { types += "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>" }
        if media.contains(where: { !$0.isJpeg }) { types += "<Default Extension=\"png\" ContentType=\"image/png\"/>" }
        types += "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/>"
            + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/>"
            + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
            + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        for i in 0..<slides.count {
            types += "<Override PartName=\"/ppt/slides/slide\(Xml.i(i + 1)).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        types += "</Types>"

        var presentation = Xml.header
        presentation += "<p:presentation xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)"
            + "\"><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
        var presentationRels = Xml.header
        presentationRels += "<Relationships xmlns=\"\(relNs)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideMaster\" Target=\"slideMasters/slideMaster1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(r)/theme\" Target=\"theme/theme1.xml\"/>"
        if !slides.isEmpty { presentation += "<p:sldIdLst>" }
        for i in 0..<slides.count {
            presentation += "<p:sldId id=\"\(Xml.i(256 + i))\" r:id=\"rId\(Xml.i(i + 3))\"/>"
            presentationRels += "<Relationship Id=\"rId\(Xml.i(i + 3))\" Type=\"\(r)/slide\" Target=\"slides/slide\(Xml.i(i + 1)).xml\"/>"
        }
        if !slides.isEmpty { presentation += "</p:sldIdLst>" }
        presentation += "<p:sldSz cx=\"\(Xml.i(width))\" cy=\"\(Xml.i(height))\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
        presentationRels += "</Relationships>"

        let rootRels = Xml.header + "<Relationships xmlns=\"\(relNs)\"><Relationship Id=\"rId1\" Type=\"\(r)/officeDocument\" Target=\"ppt/presentation.xml\"/></Relationships>"
        var masterRels = Xml.header
        masterRels += "<Relationships xmlns=\"\(relNs)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            + "<Relationship Id=\"rId2\" Type=\"\(r)/theme\" Target=\"../theme/theme1.xml\"/></Relationships>"
        let layoutRels = Xml.header + "<Relationships xmlns=\"\(relNs)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideMaster\" Target=\"../slideMasters/slideMaster1.xml\"/></Relationships>"

        var entries: [ExportZipEntry] = [
            ExportZipEntry("[Content_Types].xml", Xml.utf8(types)),
            ExportZipEntry("_rels/.rels", Xml.utf8(rootRels)),
            ExportZipEntry("ppt/presentation.xml", Xml.utf8(presentation)),
            ExportZipEntry("ppt/_rels/presentation.xml.rels", Xml.utf8(presentationRels)),
            ExportZipEntry("ppt/slideMasters/slideMaster1.xml", Xml.utf8(master)),
            ExportZipEntry("ppt/slideMasters/_rels/slideMaster1.xml.rels", Xml.utf8(masterRels)),
            ExportZipEntry("ppt/slideLayouts/slideLayout1.xml", Xml.utf8(layout)),
            ExportZipEntry("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Xml.utf8(layoutRels)),
            ExportZipEntry("ppt/theme/theme1.xml", Xml.utf8(theme)),
        ]
        for i in 0..<slides.count {
            var rels = Xml.header
            rels += "<Relationships xmlns=\"\(relNs)\"><Relationship Id=\"rId1\" Type=\"\(r)/slideLayout\" Target=\"../slideLayouts/slideLayout1.xml\"/>"
            for m in 0..<slides[i].images.count {
                let image = media[slides[i].images[m] - 1]
                rels += "<Relationship Id=\"rId\(Xml.i(m + 2))\" Type=\"\(r)/image\" Target=\"../media/image\(Xml.i(slides[i].images[m])).\(image.extension)\"/>"
            }
            rels += "</Relationships>"
            entries.append(ExportZipEntry("ppt/slides/slide\(i + 1).xml", Xml.utf8(slides[i].xml)))
            entries.append(ExportZipEntry("ppt/slides/_rels/slide\(i + 1).xml.rels", Xml.utf8(rels)))
        }
        for i in 0..<media.count { entries.append(ExportZipEntry("ppt/media/image\(i + 1).\(media[i].extension)", media[i].data)) }
        return try ExportZip.make(entries)
    }

    private static func slide(_ page: ExportPage, _ width: Int, _ height: Int, _ media: inout [ExportImage], _ mediaIndex: inout [ObjectIdentifier: Int],
                              _ held: Int) throws -> (xml: String, length: Int, images: [Int]) {
        let emu = Double(Xml.emuPerPoint)
        var scale = nanMin(Double(width) / (page.width * emu), Double(height) / (page.height * emu))
        if !(scale > 0) || scale.isInfinite { scale = 1 }
        let offsetX = (Double(width) - page.width * emu * scale) / 2, offsetY = (Double(height) - page.height * emu * scale) / 2
        func frame(_ rect: DisplayRect, _ grow: Double = 0) -> String {
            let x = ExportString.round(offsetX + rect.x * emu * scale), y = ExportString.round(offsetY + rect.y * emu * scale)
            let cx = max(1, ExportString.round((rect.width + grow) * emu * scale)), cy = max(1, ExportString.round(rect.height * emu * scale))
            return "<a:xfrm><a:off x=\"\(Xml.i(x))\" y=\"\(Xml.i(y))\"/><a:ext cx=\"\(Xml.i(cx))\" cy=\"\(Xml.i(cy))\"/></a:xfrm>"
        }

        var images: [Int] = []
        let sb = ExportBuilder(Xml.header)
        sb.append("<p:sld xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)")
            .append("\"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>")
        var id = 1
        for picture in page.pictures {
            try Xml.checkLength(sb, held + relChars, maxSlideChars)
            var number = mediaIndex[ObjectIdentifier(picture.image)] ?? 0
            if number == 0 {
                media.append(picture.image)
                number = media.count
                mediaIndex[ObjectIdentifier(picture.image)] = number
            }
            images.append(number)
            let name = ExportText.image(images.count)
            id += 1
            sb.append("<p:pic><p:nvPicPr><p:cNvPr id=\"\(Xml.i(id))\" name=\"\(name)\" descr=\"\(name)")
                .append("\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"rId\(Xml.i(images.count + 1))")
                .append("\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>").append(frame(picture.bounds)).append("<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>")
        }
        for line in page.lines {
            try Xml.checkLength(sb, held, maxSlideChars)
            id += 1
            sb.append("<p:sp><p:nvSpPr><p:cNvPr id=\"\(Xml.i(id))\" name=\"Text \(Xml.i(id))\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>")
                .append(frame(line.bounds, line.bounds.height * 0.5)).append("<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/></p:spPr>")
                .append("<p:txBody><a:bodyPr wrap=\"none\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" rtlCol=\"0\" anchor=\"t\"><a:noAutofit/></a:bodyPr><a:lstStyle/><a:p>")
            for run in line.runs {
                let wanted = (run.size * scale * 100).rounded(.toNearestOrEven)
                let size = Int(saturating32: wanted < 100 ? 100 : wanted > 400000 ? 400000 : wanted)
                sb.append("<a:r><a:rPr sz=\"\(Xml.i(size))\"")
                if run.bold { sb.append(" b=\"1\"") }
                if run.italic { sb.append(" i=\"1\"") }
                sb.append(" dirty=\"0\"/><a:t>").append(Xml.escape(ExportString.replace(run.text, "\t", " "))).append("</a:t></a:r>")
            }
            sb.append("</a:p></p:txBody></p:sp>")
        }
        sb.append("</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>")
        try Xml.checkLength(sb, held, maxSlideChars)
        return (sb.text, sb.length, images)
    }

    private static let empty = "<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"

    private static let master: String = {
        var s = Xml.header
        s += "<p:sldMaster xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\">" + empty
        s += "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        s += "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>"
        return s
    }()

    private static let layout: String = {
        var s = Xml.header
        s += "<p:sldLayout xmlns:a=\"\(a)\" xmlns:r=\"\(r)\" xmlns:p=\"\(p)\" type=\"blank\" preserve=\"1\">"
        s += "<p:cSld name=\"Blank\"><p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        return s
    }()

    private static let theme: String = {
        var s = Xml.header
        s += "<a:theme xmlns:a=\"\(a)\" name=\"Office\"><a:themeElements><a:clrScheme name=\"Office\">"
        s += "<a:dk1><a:srgbClr val=\"000000\"/></a:dk1><a:lt1><a:srgbClr val=\"FFFFFF\"/></a:lt1><a:dk2><a:srgbClr val=\"44546A\"/></a:dk2><a:lt2><a:srgbClr val=\"E7E6E6\"/></a:lt2>"
        s += "<a:accent1><a:srgbClr val=\"4472C4\"/></a:accent1><a:accent2><a:srgbClr val=\"ED7D31\"/></a:accent2><a:accent3><a:srgbClr val=\"A5A5A5\"/></a:accent3><a:accent4><a:srgbClr val=\"FFC000\"/></a:accent4>"
        s += "<a:accent5><a:srgbClr val=\"5B9BD5\"/></a:accent5><a:accent6><a:srgbClr val=\"70AD47\"/></a:accent6><a:hlink><a:srgbClr val=\"0563C1\"/></a:hlink><a:folHlink><a:srgbClr val=\"954F72\"/></a:folHlink></a:clrScheme>"
        s += "<a:fontScheme name=\"Office\"><a:majorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont><a:minorFont><a:latin typeface=\"Calibri\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
        s += "<a:fmtScheme name=\"Office\"><a:fillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:fillStyleLst>"
        s += "<a:lnStyleLst><a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"12700\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln><a:ln w=\"19050\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln></a:lnStyleLst>"
        s += "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
        s += "<a:bgFillStyleLst><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>"
        s += "</a:themeElements></a:theme>"
        return s
    }()
}
