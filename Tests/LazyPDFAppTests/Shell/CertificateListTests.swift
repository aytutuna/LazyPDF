import XCTest
@testable import LazyPDFApp

@MainActor
final class CertificateListTests: XCTestCase {
    private func choice(_ name: String) -> CertificateChoice {
        CertificateChoice(id: name, name: name, issuer: "Test", expires: Date(), isValidNow: true)
    }

    private final class Store {
        var held: [CertificateChoice]
        var stuck: Set<String> = []
        var next: CertificateChoice?

        init(_ held: [CertificateChoice]) { self.held = held }
    }

    private func model(_ store: Store) -> CertificateListModel {
        CertificateListModel(list: { store.held }, delete: { choice in
            if store.stuck.contains(choice.id) { return false }
            store.held.removeAll { $0.id == choice.id }
            return true
        }, add: {
            if let made = store.next { store.held.append(made) }
            return store.next
        })
    }

    func test_listsWhatTheStoreHolds() {
        let store = Store([choice("a"), choice("b")])

        XCTAssertEqual(model(store).items.map(\.id), ["a", "b"])
    }

    func test_removingDeletesAndRefreshes() {
        let store = Store([choice("a"), choice("b"), choice("c")])
        let list = model(store)

        list.remove(at: IndexSet([0, 2]))

        XCTAssertEqual(list.items.map(\.id), ["b"])
        XCTAssertEqual(store.held.map(\.id), ["b"])
        XCTAssertEqual(list.note, "")
    }

    func test_aFailedRemovalStaysListedAndSaysSo() {
        let store = Store([choice("a"), choice("b")])
        store.stuck = ["a"]
        let list = model(store)

        list.remove(at: IndexSet([0, 1]))

        XCTAssertEqual(list.items.map(\.id), ["a"])
        XCTAssertFalse(list.note.isEmpty)
    }

    func test_importingAddsToTheList() async {
        let store = Store([choice("a")])
        store.next = choice("b")
        let list = model(store)

        await list.importOne()

        XCTAssertEqual(list.items.map(\.id), ["a", "b"])
    }

    func test_giveUpLeavesTheListAlone() async {
        let store = Store([choice("a")])
        let list = model(store)

        await list.importOne()

        XCTAssertEqual(list.items.map(\.id), ["a"])
    }

    func test_removingOutOfRangeIsIgnored() {
        let store = Store([choice("a")])
        let list = model(store)

        list.remove(at: IndexSet([5]))

        XCTAssertEqual(list.items.map(\.id), ["a"])
    }
}
