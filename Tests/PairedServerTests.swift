import XCTest
import NocturneKit

final class PairedServerTests: XCTestCase {
    private func invitation(_ name: String, secret: UInt8, host: String = "10.0.0.2") throws -> PairingInvitation {
        try PairingInvitation(host: host, name: name, secret: Data(repeating: secret, count: 32))
    }

    func testPairingSeveralMacsKeepsEachAndActivatesTheNewest() throws {
        var list = PairedServerList()
        let studio = try invitation("Studio", secret: 1), office = try invitation("Office", secret: 2)
        list.pair(studio)
        list.pair(office)
        XCTAssertEqual(list.servers.map(\.name), ["Studio", "Office"])
        XCTAssertEqual(list.active?.name, "Office")
        XCTAssertEqual(list.servers[0].id, WorkspaceIdentity.fingerprint(studio.secret))
        XCTAssertNotEqual(list.servers[0].id, list.servers[1].id)

        list.activate(list.servers[0].id)
        XCTAssertEqual(list.active?.name, "Studio")
        list.activate("unknown")
        XCTAssertEqual(list.active?.name, "Studio")
    }

    func testRescanningAMacRefreshesItInPlaceAndKeepsItsVideoLink() throws {
        var list = PairedServerList()
        let studio = try invitation("Studio", secret: 1)
        list.pair(studio); list.pair(try invitation("Office", secret: 2))
        let id = WorkspaceIdentity.fingerprint(studio.secret)
        _ = list.link(streamingHostID: "studio-video", to: id)
        list.pair(try studio.replacingAddress(host: "10.0.0.9"))
        XCTAssertEqual(list.servers.count, 2)
        XCTAssertEqual(list[id]?.invitation.host, "10.0.0.9")
        XCTAssertEqual(list[id]?.streamingHostID, "studio-video")
        XCTAssertEqual(list.active?.id, id)

        list.update(try studio.replacingAddress(host: "10.0.0.10"))
        XCTAssertEqual(list[id]?.invitation.host, "10.0.0.10")
        list.update(try invitation("Stranger", secret: 9))
        XCTAssertEqual(list.servers.count, 2, "Refreshing an address must never add a pairing")
    }

    func testAVideoHostBelongsToOnlyOneMac() throws {
        var list = PairedServerList()
        let old = try invitation("Studio", secret: 1), reset = try invitation("Studio", secret: 3)
        list.pair(old); list.pair(try invitation("Office", secret: 2)); list.pair(reset)
        let oldID = WorkspaceIdentity.fingerprint(old.secret), resetID = WorkspaceIdentity.fingerprint(reset.secret)
        XCTAssertTrue(list.link(streamingHostID: "studio-video", to: oldID).isEmpty)
        // Resetting pairing on the Mac rotates its key; the fresh pairing supersedes the stale one.
        let superseded = list.link(streamingHostID: "studio-video", to: resetID)
        XCTAssertEqual(superseded.map(\.id), [oldID])
        XCTAssertNil(list[oldID])
        XCTAssertEqual(list.server(linkedTo: "studio-video")?.id, resetID)
        XCTAssertNil(list.server(linkedTo: "unknown"))
        XCTAssertTrue(list.link(streamingHostID: "other", to: "missing").isEmpty)
        XCTAssertNil(list.server(linkedTo: "other"))
    }

    func testForgettingTheActiveMacFallsBackToAnotherPairing() throws {
        var list = PairedServerList()
        let studio = try invitation("Studio", secret: 1), office = try invitation("Office", secret: 2)
        list.pair(studio); list.pair(office)
        XCTAssertEqual(list.remove(WorkspaceIdentity.fingerprint(office.secret))?.name, "Office")
        XCTAssertEqual(list.active?.name, "Studio")
        list.pair(office); list.activate(WorkspaceIdentity.fingerprint(studio.secret))
        XCTAssertEqual(list.remove(WorkspaceIdentity.fingerprint(office.secret))?.name, "Office")
        XCTAssertEqual(list.active?.name, "Studio", "Forgetting another Mac keeps the current one")
        XCTAssertNil(list.remove("missing"))
        _ = list.remove(WorkspaceIdentity.fingerprint(studio.secret))
        XCTAssertNil(list.active)
        XCTAssertTrue(list.servers.isEmpty)
    }

    func testSavedListRoundTripsAndRepairsAMissingActiveMac() throws {
        var list = PairedServerList()
        let studio = try invitation("Studio", secret: 1)
        list.pair(studio); list.pair(try invitation("Office", secret: 2))
        _ = list.link(streamingHostID: "studio-video", to: WorkspaceIdentity.fingerprint(studio.secret))
        XCTAssertEqual(try JSONDecoder().decode(PairedServerList.self, from: JSONEncoder().encode(list)), list)

        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any])
        fields["activeID"] = "forgotten"
        let repaired = try JSONDecoder().decode(PairedServerList.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(repaired.active?.name, "Studio")
        let duplicate = list.servers + list.servers
        fields["servers"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(duplicate))
        XCTAssertEqual(try JSONDecoder().decode(PairedServerList.self, from: JSONSerialization.data(withJSONObject: fields)).servers.count, 2)
    }

    func testSingleMacPairingMigratesWithItsVideoLink() throws {
        let legacy = try invitation("Studio", secret: 1)
        let migrated = PairedServerList(legacy: legacy, streamingHostID: "studio-video")
        XCTAssertEqual(migrated.servers.map(\.invitation), [legacy])
        XCTAssertEqual(migrated.active?.streamingHostID, "studio-video")
        XCTAssertNil(PairedServerList(legacy: nil, streamingHostID: "orphan").active)
    }
}
