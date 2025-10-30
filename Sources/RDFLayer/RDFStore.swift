import Foundation
import FoundationDB
import Logging

// MARK: - RDF Store

/// Public API for the RDF Triple Store
///
/// This actor provides a thread-safe interface for inserting, deleting,
/// and querying RDF triples stored in FoundationDB.
///
/// ## Example Usage
///
/// ```swift
/// // Initialize FoundationDB
/// try await FDBClient.initialize()
/// let database = try FDBClient.openDatabase()
///
/// // Create RDF store
/// let store = try await RDFStore(database: database, rootPrefix: "my-app")
///
/// // Insert a triple
/// let triple = RDFTriple(
///     subject: "http://example.org/alice",
///     predicate: "http://xmlns.com/foaf/0.1/knows",
///     object: "http://example.org/bob"
/// )
/// try await store.insert(triple)
///
/// // Query triples
/// let results = try await store.query(
///     subject: "http://example.org/alice",
///     predicate: nil,
///     object: nil
/// )
/// ```
public actor RDFStore {

    // MARK: - Properties

    private let storage: TripleStorage
    private let logger: Logger

    /// The root prefix for all keys in FoundationDB
    public let rootPrefix: String

    // MARK: - Initialization

    /// Creates a new RDF store
    ///
    /// - Parameters:
    ///   - database: The FoundationDB database instance
    ///   - rootPrefix: A unique prefix for this store's keys (e.g., "my-app")
    ///   - logger: Optional custom logger
    public init(
        database: any DatabaseProtocol,
        rootPrefix: String,
        logger: Logger? = nil
    ) async throws {
        self.rootPrefix = rootPrefix
        self.logger = logger ?? Logger(label: "com.rdf.store")
        self.storage = TripleStorage(database: database, rootPrefix: rootPrefix, logger: self.logger)

        self.logger.info("RDF Store initialized with prefix: \(rootPrefix)")
    }

    // MARK: - Public API

    /// Inserts a triple into the store
    ///
    /// If the triple already exists, this operation is idempotent and will not fail.
    ///
    /// - Parameter triple: The triple to insert
    /// - Throws: `RDFError` if the operation fails
    public func insert(_ triple: RDFTriple) async throws {
        logger.info("Insert: \(triple)")
        try await storage.insert(triple)
    }

    /// Inserts multiple triples in batches
    ///
    /// This method automatically batches the inserts to respect FoundationDB's
    /// 10MB transaction limit. Each batch is processed in a single transaction
    /// for optimal performance.
    ///
    /// - Parameter triples: The triples to insert
    /// - Throws: `RDFError` if any operation fails
    public func insertBatch(_ triples: [RDFTriple]) async throws {
        logger.info("Inserting batch of \(triples.count) triples")

        // Insert in batches of 1000 to avoid transaction size limits
        // Each batch is processed in a single transaction for efficiency
        let batchSize = 1000

        for batchIndex in stride(from: 0, to: triples.count, by: batchSize) {
            let endIndex = min(batchIndex + batchSize, triples.count)
            let batch = Array(triples[batchIndex..<endIndex])

            // Use the batch insert method which uses a single transaction
            try await storage.insertBatch(batch)

            logger.debug("Inserted batch \(batchIndex/batchSize + 1)")
        }

        logger.info("Batch insert complete")
    }

    /// Deletes a triple from the store
    ///
    /// If the triple does not exist, this operation is idempotent and will not fail.
    ///
    /// - Parameter triple: The triple to delete
    /// - Throws: `RDFError` if the operation fails
    public func delete(_ triple: RDFTriple) async throws {
        logger.info("Delete: \(triple)")
        try await storage.delete(triple)
    }

    /// Queries triples matching the given pattern
    ///
    /// Use `nil` for any component to match all values. For example:
    /// - `query(subject: "http://example.org/alice", predicate: nil, object: nil)`
    ///   returns all triples where Alice is the subject
    /// - `query(subject: nil, predicate: "knows", object: nil)`
    ///   returns all "knows" relationships
    ///
    /// - Parameters:
    ///   - subject: The subject URI to match, or nil to match all
    ///   - predicate: The predicate URI to match, or nil to match all
    ///   - object: The object URI to match, or nil to match all
    /// - Returns: An array of matching triples
    /// - Throws: `RDFError` if the operation fails
    public func query(
        subject: String? = nil,
        predicate: String? = nil,
        object: String? = nil
    ) async throws -> [RDFTriple] {
        logger.info("Query: s=\(subject ?? "?"), p=\(predicate ?? "?"), o=\(object ?? "?")")
        let results = try await storage.query(subject: subject, predicate: predicate, object: object)
        logger.info("Query returned \(results.count) results")
        return results
    }

    /// Returns the total number of triples in the store
    ///
    /// - Returns: The count of triples
    /// - Throws: `RDFError` if the operation fails
    public func count() async throws -> UInt64 {
        let count = try await storage.count()
        logger.debug("Triple count: \(count)")
        return count
    }

    /// Checks if a specific triple exists in the store
    ///
    /// - Parameter triple: The triple to check
    /// - Returns: `true` if the triple exists, `false` otherwise
    /// - Throws: `RDFError` if the operation fails
    public func contains(_ triple: RDFTriple) async throws -> Bool {
        let results = try await storage.query(
            subject: triple.subject,
            predicate: triple.predicate,
            object: triple.object
        )
        return !results.isEmpty
    }
}

// MARK: - Convenience Extensions

extension RDFStore {
    /// Queries all triples (full scan)
    ///
    /// Warning: This can be expensive for large datasets
    ///
    /// - Returns: All triples in the store
    public func all() async throws -> [RDFTriple] {
        return try await query(subject: nil, predicate: nil, object: nil)
    }

    /// Queries all triples for a given subject
    ///
    /// - Parameter subject: The subject URI
    /// - Returns: All triples with the given subject
    public func triplesForSubject(_ subject: String) async throws -> [RDFTriple] {
        return try await query(subject: subject, predicate: nil, object: nil)
    }

    /// Queries all triples for a given predicate
    ///
    /// - Parameter predicate: The predicate URI
    /// - Returns: All triples with the given predicate
    public func triplesForPredicate(_ predicate: String) async throws -> [RDFTriple] {
        return try await query(subject: nil, predicate: predicate, object: nil)
    }

    /// Queries all triples for a given object
    ///
    /// - Parameter object: The object URI
    /// - Returns: All triples with the given object
    public func triplesForObject(_ object: String) async throws -> [RDFTriple] {
        return try await query(subject: nil, predicate: nil, object: object)
    }
}
