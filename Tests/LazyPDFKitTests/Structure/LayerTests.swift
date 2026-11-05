import XCTest
@testable import LazyPDFKit

// Mirrors windows/LazyPDF.Core.Tests/Structure/LayerTests.cs: the same cases.

final class LayerTests: XCTestCase {
    private func sample(_ config: String = "/OFF [31 0 R] /Locked [32 0 R] /Order [30 0 R (Group) [31 0 R 32 0 R]]") throws -> PdfDocument {
        try StructureFixtures.file("/OCProperties <</OCGs [30 0 R 31 0 R 32 0 R 33 0 R] /D <<\(config)>>>>") { pdf in
            pdf.obj(30, "<</Type /OCG /Name (Background) /Intent /View>>")
            pdf.obj(31, "<</Type /OCG /Name <FEFF0416> /Intent [/Design /View]>>")
            pdf.obj(32, "<</Type /OCG>>")
            pdf.obj(33, "<</Type /OCG /Name (Extra)>>")
        }
    }

    func test_readsLayersWithStateLockAndIntent() throws {
        let set = PdfLayers.read(try sample())
        XCTAssertEqual(set.layers.map { $0.name }, ["Background", "Ж", StructureText.unnamedLayer, "Extra"])
        XCTAssertEqual(set.layers.map { $0.isOn }, [true, false, true, true])
        XCTAssertEqual(set.layers.map { $0.locked }, [false, false, true, false])
        XCTAssertEqual(set.layers.map { $0.intent }, ["View", "Design", nil, nil])
        XCTAssertEqual(set.layers[0].reference.number, 30)
    }

    func test_orderTreeHasLabelsChildrenAndStragglers() throws {
        let order = PdfLayers.read(try sample()).order
        XCTAssertEqual(order.count, 3)
        XCTAssertEqual(order[0].layer?.name, "Background")
        XCTAssertEqual(order[1].label, "Group")
        XCTAssertNil(order[1].layer)
        XCTAssertEqual(order[1].children.map { $0.layer?.name }, ["Ж", StructureText.unnamedLayer])
        XCTAssertEqual(order[2].layer?.name, "Extra")
    }

    func test_layerFollowedByAnArrayOwnsIt() throws {
        let order = PdfLayers.read(try sample("/Order [30 0 R [31 0 R] [32 0 R]]")).order
        XCTAssertEqual(order[0].layer?.name, "Background")
        XCTAssertEqual(order[0].children.count, 1)
        XCTAssertEqual(order[0].children[0].layer?.name, "Ж")
        XCTAssertNil(order[1].layer)
        XCTAssertEqual(order[1].children.count, 1)
        XCTAssertEqual(order[1].children[0].layer?.name, StructureText.unnamedLayer)
    }

    func test_noOrderListsEveryLayer() throws {
        let set = PdfLayers.read(try sample(""))
        XCTAssertEqual(set.order.count, 4)
        for layer in set.layers { XCTAssertTrue(layer.isOn) }
    }

    func test_baseStateOffUsesOn() throws {
        let set = PdfLayers.read(try sample("/BaseState /OFF /ON [30 0 R 33 0 R]"))
        XCTAssertEqual(set.layers.map { $0.isOn }, [true, false, false, true])
        let unchanged = PdfLayers.read(try sample("/BaseState /Unchanged /OFF [33 0 R]"))
        XCTAssertEqual(unchanged.layers.map { $0.isOn }, [true, true, true, false])
    }

    func test_noLayersNoSet() throws {
        let set = PdfLayers.read(try StructureFixtures.open())
        XCTAssertTrue(set.layers.isEmpty)
        XCTAssertTrue(set.order.isEmpty)
    }

    func test_hidingAndShowingSurviveASave() throws {
        let document = try sample()
        XCTAssertTrue(PdfLayers.setVisible(document, PdfReference(30, 0), false))
        XCTAssertTrue(PdfLayers.setVisible(document, PdfReference(31, 0), true))
        let reopened = try StructureFixtures.reopen(document)
        let set = PdfLayers.read(reopened)
        XCTAssertEqual(set.layers.map { $0.isOn }, [false, true, true, true])
        let config = try XCTUnwrap(reopened.dict(reopened.dict(reopened.catalog, "OCProperties"), "D"))
        XCTAssertNil(config["BaseState"])
        XCTAssertNil(config["ON"])
        XCTAssertEqual(config["OFF"]?.description, "[30 0 R]")
        XCTAssertNotNil(config["Order"])
        XCTAssertNotNil(config["Locked"])
    }

    func test_baseStateOffIsRewrittenAsOnWithAnOffList() throws {
        let document = try sample("/BaseState /OFF /ON [30 0 R]")
        PdfLayers.setVisible(document, PdfReference(33, 0), true)
        let set = PdfLayers.read(try StructureFixtures.reopen(document))
        XCTAssertEqual(set.layers.map { $0.isOn }, [true, false, false, true])
    }

    func test_noOffLayersRemovesTheList() throws {
        let document = try sample()
        PdfLayers.setVisible(document, PdfReference(31, 0), true)
        XCTAssertNil(document.dict(document.dict(document.catalog, "OCProperties"), "D")?["OFF"])
    }

    func test_configIsMadeWhenMissing() throws {
        let document = try StructureFixtures.file("/OCProperties <</OCGs [30 0 R]>>") { $0.obj(30, "<</Type /OCG /Name (Only)>>") }
        PdfLayers.setVisible(document, PdfReference(30, 0), false)
        XCTAssertEqual(PdfLayers.read(try StructureFixtures.reopen(document)).layers.map { $0.isOn }, [false])
    }

    func test_radioButtonGroupTurnsTheOthersOff() throws {
        let document = try sample("/OFF [30 0 R] /RBGroups [[30 0 R 31 0 R 33 0 R]]")
        PdfLayers.setVisible(document, PdfReference(31, 0), true)
        XCTAssertEqual(PdfLayers.read(document).layers.map { $0.isOn }, [false, true, true, false])
        PdfLayers.setVisible(document, PdfReference(30, 0), true)
        XCTAssertEqual(PdfLayers.read(document).layers.map { $0.isOn }, [true, false, true, false])
        PdfLayers.setVisible(document, PdfReference(33, 0), false)
        XCTAssertEqual(PdfLayers.read(document).layers.map { $0.isOn }, [true, false, true, false])
    }

    func test_unknownLayerIsRefused() throws {
        let document = try sample()
        XCTAssertFalse(PdfLayers.setVisible(document, PdfReference(99, 0), false))
        XCTAssertFalse(PdfLayers.setVisible(try StructureFixtures.open(), PdfReference(30, 0), false))
    }

    func test_anOrderThatListsItselfIsReadOnce() throws {
        let document = try StructureFixtures.file("/OCProperties <</OCGs [30 0 R] /D <</Order 31 0 R>>>>") { pdf in
            pdf.obj(30, "<</Type /OCG /Name (A)>>")
            pdf.obj(31, "[31 0 R 31 0 R 31 0 R 31 0 R 30 0 R]")
        }
        let set = PdfLayers.read(document)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertTrue(set.order.count < 10)
        XCTAssertTrue(set.order.contains { $0.layer != nil })
    }

    func test_junkAndLoopsInOrderAreTolerated() throws {
        let document = try StructureFixtures.file("/OCProperties <</OCGs [30 0 R 30 0 R 5 null 99 0 R] /D <</Order 31 0 R /ON 7>>>>") { pdf in
            pdf.obj(30, "<</Type /OCG /Name (A)>>")
            pdf.obj(31, "[30 0 R 30 0 R 31 0 R (x) 3 [[[[[[[[[[[[[[[[[[[[30 0 R]]]]]]]]]]]]]]]]]]]]]")
        }
        let set = PdfLayers.read(document)
        XCTAssertEqual(set.layers.count, 1)
        XCTAssertFalse(set.order.isEmpty)
    }
}
