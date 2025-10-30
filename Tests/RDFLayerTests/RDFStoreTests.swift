import Testing
import Foundation
import FoundationDB
@testable import RDFLayer

@Suite("RDF Store Tests")
struct RDFStoreTests {

    // MARK: - Setup

    private static func createStore() async throws -> RDFStore {
        // Initialize FoundationDB (ignore error if already initialized)
        do {
            try await FDBClient.initialize()
        } catch {
            // Already initialized, ignore
        }

        let database = try FDBClient.openDatabase()

        // Create RDF store with unique prefix for this test run
        let prefix = "test-\(UUID().uuidString.prefix(8))"
        return try await RDFStore(database: database, rootPrefix: prefix)
    }

    // MARK: - Basic Operations

    @Test("Insert and query single triple")
    func insertAndQuerySingle() async throws {
        let store = try await Self.createStore()

        let triple = RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        )

        // Insert
        try await store.insert(triple)

        // Query by subject
        let results = try await store.query(
            subject: "http://example.org/alice",
            predicate: nil,
            object: nil
        )

        #expect(results.count == 1)
        #expect(results[0] == triple)
    }

    @Test("Insert duplicate triple is idempotent")
    func insertDuplicate() async throws {
        let store = try await Self.createStore()

        let triple = RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        )

        // Insert twice
        try await store.insert(triple)
        try await store.insert(triple)

        // Should still have only one triple
        let count = try await store.count()
        #expect(count == 1)
    }

    @Test("Delete triple")
    func deleteTriple() async throws {
        let store = try await Self.createStore()

        let triple = RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        )

        // Insert and verify
        try await store.insert(triple)
        #expect(try await store.count() == 1)

        // Delete and verify
        try await store.delete(triple)
        #expect(try await store.count() == 0)
    }

    @Test("Query by subject")
    func queryBySubject() async throws {
        let store = try await Self.createStore()

        // Insert multiple triples
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        ))
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/charlie"
        ))
        try await store.insert(RDFTriple(
            subject: "http://example.org/bob",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/alice"
        ))

        // Query by subject
        let results = try await store.query(
            subject: "http://example.org/alice",
            predicate: nil,
            object: nil
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.subject == "http://example.org/alice" })
    }

    @Test("Query by predicate")
    func queryByPredicate() async throws {
        let store = try await Self.createStore()

        // Insert triples with different predicates
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        ))
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/name",
            object: "Alice"
        ))

        // Query by predicate
        let results = try await store.query(
            subject: nil,
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: nil
        )

        #expect(results.count == 1)
        #expect(results[0].predicate == "http://xmlns.com/foaf/0.1/knows")
    }

    @Test("Query by object")
    func queryByObject() async throws {
        let store = try await Self.createStore()

        // Insert triples pointing to the same object
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        ))
        try await store.insert(RDFTriple(
            subject: "http://example.org/charlie",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        ))

        // Query by object
        let results = try await store.query(
            subject: nil,
            predicate: nil,
            object: "http://example.org/bob"
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.object == "http://example.org/bob" })
    }

    @Test("Query with multiple bounds")
    func queryMultipleBounds() async throws {
        let store = try await Self.createStore()

        // Insert triples
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        ))
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/charlie"
        ))
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/name",
            object: "Alice"
        ))

        // Query with subject and predicate bound
        let results = try await store.query(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: nil
        )

        #expect(results.count == 2)
        #expect(results.allSatisfy {
            $0.subject == "http://example.org/alice" &&
            $0.predicate == "http://xmlns.com/foaf/0.1/knows"
        })
    }

    @Test("Batch insert")
    func batchInsert() async throws {
        let store = try await Self.createStore()

        // Create 100 triples
        var triples: [RDFTriple] = []
        for i in 0..<100 {
            triples.append(RDFTriple(
                subject: "http://example.org/person\(i)",
                predicate: "http://xmlns.com/foaf/0.1/knows",
                object: "http://example.org/person\(i + 1)"
            ))
        }

        // Batch insert
        try await store.insertBatch(triples)

        // Verify count
        let count = try await store.count()
        #expect(count == 100)
    }

    @Test("Contains check")
    func containsCheck() async throws {
        let store = try await Self.createStore()

        let triple = RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        )

        // Should not contain before insert
        #expect(try await store.contains(triple) == false)

        // Insert
        try await store.insert(triple)

        // Should contain after insert
        #expect(try await store.contains(triple) == true)

        // Delete
        try await store.delete(triple)

        // Should not contain after delete
        #expect(try await store.contains(triple) == false)
    }

    @Test("Query non-existent URI")
    func queryNonExistent() async throws {
        let store = try await Self.createStore()

        // Insert one triple
        try await store.insert(RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        ))

        // Query for non-existent URI
        let results = try await store.query(
            subject: "http://example.org/nonexistent",
            predicate: nil,
            object: nil
        )

        #expect(results.isEmpty)
    }
}
