import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Standards/PdfAColorTests.cs: the same cases.

final class PdfAColorTests: XCTestCase {
    private let noIntent = ""

    func test_deviceRgbWithoutAnOutputIntentIsReportedForEachPart() throws {
        let file = StandardsKit.compliant(intents: noIntent)
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a2b), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(file, .a1b), "6.2.3.3")
    }

    func test_aDefaultSpaceTakesTheOutputIntentsPlace() throws {
        let file = StandardsKit.compliant(resources: "/ColorSpace <</DefaultRGB [/ICCBased 7 0 R]>>", intents: noIntent)
        StandardsKit.assertLacks(try StandardsKit.clauses(file), "6.2.4.3")
    }

    func test_deviceCmykNeedsACmykIntentWhileGrayOnlyNeedsOne() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "0 0 0 1 k 0 0 10 10 re f")), "6.2.4.3")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(content: "0.5 g 0 0 10 10 re f")), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "0.5 g 0 0 10 10 re f", intents: noIntent)), "6.2.4.3")
    }

    func test_colourInAnImageAndAFormIsFoundThroughTheInterpreter() throws {
        let file = StandardsKit.compliant(content: "q 0 0 1 rg /Fm Do Q".replacingOccurrences(of: "0 0 1 rg", with: "0.5 g"), resources: "/XObject <</Fm 9 0 R>>", extra: { pdf in
            pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10]", "1 0 0 RG 0 0 5 5 re S")
        }, intents: noIntent)
        let issues = try StandardsKit.check(file).issues.filter { $0.clause == "6.2.4.3" }
        StandardsKit.assertHas(issues) { $0.message.contains("DeviceRGB") }
    }

    private func profile(_ document: PdfDocument) throws -> PdfStream {
        let intents = try XCTUnwrap(document.array(document.catalog, "OutputIntents"))
        let intent = try XCTUnwrap(document.resolve(intents.items[0]) as? PdfDictionary)
        return try XCTUnwrap(document.resolve(intent["DestOutputProfile"]) as? PdfStream)
    }

    private func altered(_ change: (inout [UInt8]) -> Void) -> [UInt8] {
        var copy = PdfASrgb.srgbProfile
        change(&copy)
        return copy
    }

    func test_anIntentProfileThatIsTooNewOrDoesNotMatchIsReported() throws {
        let version3 = try StandardsKit.edited(StandardsKit.compliant()) { d in try self.profile(d).data = self.altered { $0[8] = 3 } }
        StandardsKit.assertHas(try StandardsKit.check(version3, .a1b).issues) { $0.clause == "6.2.2" && $0.where == "Output intent" }
        StandardsKit.assertNone(try StandardsKit.check(version3).issues) { $0.where == "Output intent" }

        let version5 = try StandardsKit.edited(StandardsKit.compliant()) { d in try self.profile(d).data = self.altered { $0[8] = 5 } }
        StandardsKit.assertHas(try StandardsKit.check(version5).issues) { $0.clause == "6.2.3" && $0.where == "Output intent" }

        let wrongSpace = try StandardsKit.edited(StandardsKit.compliant()) { d in try self.profile(d).data = self.altered { $0[16] = UInt8(ascii: "C") } }
        StandardsKit.assertHas(try StandardsKit.check(wrongSpace).issues) { $0.where == "Output intent" }

        let garbage = try StandardsKit.edited(StandardsKit.compliant()) { d in try self.profile(d).data = [UInt8](repeating: 0, count: 200) }
        StandardsKit.assertHas(try StandardsKit.check(garbage).issues) { $0.where == "Output intent" }
    }

    func test_anIccBasedSpaceInTheContentIsCheckedTheSameWay() throws {
        let spaces = "/ColorSpace <</CS0 [/ICCBased 9 0 R]>>"
        let bad = StandardsKit.compliant(resources: spaces, extra: { pdf in pdf.stream(9, "/N 3", [UInt8](repeating: 0, count: 200)) })
        StandardsKit.assertHas(try StandardsKit.check(bad).issues) { $0.clause == "6.2.4.2" }
        StandardsKit.assertHas(try StandardsKit.check(bad, .a1b).issues) { $0.clause == "6.2.3.2" }
        let good = StandardsKit.compliant(resources: spaces, extra: { pdf in pdf.stream(9, "/N 3", PdfASrgb.srgbProfile) })
        StandardsKit.assertNone(try StandardsKit.check(good).issues) { $0.clause == "6.2.4.2" }
        let mismatch = StandardsKit.compliant(resources: spaces, extra: { pdf in pdf.stream(9, "/N 1", PdfASrgb.srgbProfile) })
        StandardsKit.assertHas(try StandardsKit.check(mismatch).issues) { $0.clause == "6.2.4.2" }
    }

    func test_aDifferentProfileInASecondIntentIsReported() throws {
        let file = StandardsKit.compliant(extra: { pdf in
            pdf.obj(9, "<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (x) /DestOutputProfile 10 0 R>>").stream(10, "/N 3", PdfASrgb.srgbProfile)
        }, intents: "/OutputIntents [6 0 R 9 0 R]")
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.message.contains("different profiles") }
    }

    func test_anOutputIntentWithoutAProfileIsReported() throws {
        let file = StandardsKit.compliant(extra: { pdf in
            pdf.obj(9, "<</Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (x)>>")
        }, intents: "/OutputIntents [9 0 R]")
        StandardsKit.assertHas(try StandardsKit.check(file).issues) { $0.message.contains("DestOutputProfile") }
    }

    func test_aSeparationNamedTwiceWithDifferentAlternatesIsReported() throws {
        let spaces = "/ColorSpace <</A [/Separation /Gold /DeviceGray 9 0 R] /B [/Separation /Gold /DeviceGray 10 0 R]>>"
        let two = StandardsKit.compliant(resources: spaces, extra: { pdf in
            pdf.stream(9, "/FunctionType 4 /Domain [0 1] /Range [0 1]", "{}").stream(10, "/FunctionType 4 /Domain [0 1] /Range [0 1]", "{1 exch sub}")
        })
        StandardsKit.assertContains(try StandardsKit.clauses(two), "6.2.4.4")
        let same = StandardsKit.compliant(resources: spaces.replacingOccurrences(of: "10 0 R", with: "9 0 R"), extra: { pdf in
            pdf.stream(9, "/FunctionType 4 /Domain [0 1] /Range [0 1]", "{}")
        })
        StandardsKit.assertLacks(try StandardsKit.clauses(same), "6.2.4.4")
    }

    func test_anUnknownRenderingIntentIsReported() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "/Fancy ri 0 0 1 rg 0 0 5 5 re f")), "6.2.6")
        StandardsKit.assertLacks(try StandardsKit.clauses(StandardsKit.compliant(content: "/Perceptual ri 0 0 1 rg 0 0 5 5 re f")), "6.2.6")
    }

    func test_anUndefinedOperatorIsReportedEvenInsideCompatibilityBrackets() throws {
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(content: "BX 1 2 frob EX")), "6.2.2")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1b, content: "BX 1 2 frob EX"), .a1b), "6.2.10")
    }

    func test_anIndexedSpaceOverADeviceBaseIsAUseOfIt() throws {
        let file = StandardsKit.compliant(content: "/CS0 cs 0 sc 0 0 5 5 re f", resources: "/ColorSpace <</CS0 [/Indexed /DeviceRGB 1 <000000FFFFFF>]>>", intents: noIntent)
        StandardsKit.assertContains(try StandardsKit.clauses(file), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(StandardsKit.compliant(.a1b, content: "/CS0 cs 0 sc 0 0 5 5 re f",
                                                                                   resources: "/ColorSpace <</CS0 [/Indexed /DeviceRGB 1 <000000FFFFFF>]>>", intents: noIntent), .a1b), "6.2.3.3")
        let unpainted = StandardsKit.compliant(content: "", resources: "/ColorSpace <</CS0 [/Indexed /DeviceRGB 1 <000000FFFFFF>]>>", intents: noIntent)
        StandardsKit.assertLacks(try StandardsKit.clauses(unpainted), "6.2.4.3")
    }

    func test_shadingsPatternsAndGroupsCountOnlyWhenPainted() throws {
        let shading = "<</ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 10 0] /Function <</FunctionType 2 /Domain [0 1] /C0 [0 0 0] /C1 [1 1 1] /N 1>>>>"
        let resources = "/Shading <</Sh0 " + shading + ">> /Pattern <</P0 <</PatternType 2 /Shading " + shading + ">>>> /XObject <</Fm 9 0 R>>"
        func page(_ content: String) -> [UInt8] {
            StandardsKit.compliant(content: content, resources: resources, extra: { pdf in
                pdf.stream(9, "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Group <</S /Transparency /CS /DeviceRGB>>", "")
            }, intents: self.noIntent)
        }
        StandardsKit.assertLacks(try StandardsKit.clauses(page("")), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(page("/Sh0 sh")), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(page("/Pattern cs /P0 scn 0 0 10 10 re f")), "6.2.4.3")
        StandardsKit.assertContains(try StandardsKit.clauses(page("/Fm Do")), "6.2.4.3")
    }
}
