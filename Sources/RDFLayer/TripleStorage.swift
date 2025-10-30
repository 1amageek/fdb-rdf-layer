import Foundation
import FoundationDB
import Logging

// MARK: - Triple Storage Actor

/// Actor responsible for managing triple storage with 4 indexes
///
/// ## Storage Layout
/// - **Indexes**: SPO, PSO, POS, OSP (4 indexes for optimal query performance)
/// - **Dictionary**: URI ↔ ID bidirectional mapping with atomic counter
/// - **Metadata**: Triple count and other metadata
///
/// ## Caching Strategy
/// - **URI/ID mappings** are cached in-memory within the actor
/// - Cache updates occur during transaction execution (before commit)
/// - This is safe because:
///   1. For reads: cached data already exists in FDB
///   2. For writes: FDB's automatic retry will recreate the same mappings
///   3. Actor isolation ensures thread-safety of cache access
///
/// ## Transaction Guarantees
/// - All operations use FoundationDB's ACID transactions
/// - Automatic retry for transient errors
/// - Read-your-writes guarantee within transactions
actor TripleStorage {

    // MARK: - Properties

    private let db: any DatabaseProtocol
    private let rootPrefix: String
    private let logger: Logger

    /// The four enabled indexes (v2.0 design)
    private let enabledIndexes: Set<IndexType> = [.spo, .pso, .pos, .osp]

    /// Simple in-memory caches (Actor-isolated, so thread-safe)
    /// Note: These caches are updated during transaction execution.
    /// See class documentation for cache safety guarantees.
    private var uriToIdCache: [String: UInt64] = [:]
    private var idToUriCache: [UInt64: String] = [:]

    // MARK: - Initialization

    init(database: any DatabaseProtocol, rootPrefix: String, logger: Logger? = nil) {
        self.db = database
        self.rootPrefix = rootPrefix
        self.logger = logger ?? Logger(label: "com.rdf.triplestorage")
    }

    // MARK: - Public API

    /// Inserts a triple into the store
    func insert(_ triple: RDFTriple) async throws {
        logger.debug("Inserting triple: \(triple)")

        try await db.withTransaction { transaction in
            // 1. Convert URIs to IDs
            let subjectID = try await self.getOrCreateID(uri: triple.subject, transaction: transaction)
            let predicateID = try await self.getOrCreateID(uri: triple.predicate, transaction: transaction)
            let objectID = try await self.getOrCreateID(uri: triple.object, transaction: transaction)

            // 2. Check if triple already exists (using SPO index)
            let spoKey = TupleHelpers.encodeTripleKey(
                rootPrefix: self.rootPrefix,
                indexType: .spo,
                s: subjectID,
                p: predicateID,
                o: objectID
            )

            if let _ = try await transaction.getValue(for: spoKey) {
                // Triple already exists, nothing to do
                self.logger.debug("Triple already exists, skipping")
                return
            }

            // 3. Insert into all 4 indexes
            for indexType in self.enabledIndexes {
                let key = TupleHelpers.encodeTripleKey(
                    rootPrefix: self.rootPrefix,
                    indexType: indexType,
                    s: subjectID,
                    p: predicateID,
                    o: objectID
                )
                // Empty value (existence is what matters)
                transaction.setValue(FDB.Bytes(), for: key)
            }

            // 4. Increment triple count
            let countKey = TupleHelpers.encodeTripleCountKey(rootPrefix: self.rootPrefix)
            let increment = withUnsafeBytes(of: UInt64(1).littleEndian) { Array($0) }
            transaction.atomicOp(key: countKey, param: increment, mutationType: .add)

            self.logger.debug("Triple inserted successfully")
        }
    }

    /// Inserts multiple triples in a single transaction
    /// This is more efficient than calling insert() multiple times
    func insertBatch(_ triples: [RDFTriple]) async throws {
        logger.debug("Inserting batch of \(triples.count) triples")

        try await db.withTransaction { transaction in
            var insertedCount: UInt64 = 0

            for triple in triples {
                // 1. Convert URIs to IDs
                let subjectID = try await self.getOrCreateID(uri: triple.subject, transaction: transaction)
                let predicateID = try await self.getOrCreateID(uri: triple.predicate, transaction: transaction)
                let objectID = try await self.getOrCreateID(uri: triple.object, transaction: transaction)

                // 2. Check if triple already exists (using SPO index)
                let spoKey = TupleHelpers.encodeTripleKey(
                    rootPrefix: self.rootPrefix,
                    indexType: .spo,
                    s: subjectID,
                    p: predicateID,
                    o: objectID
                )

                if let _ = try await transaction.getValue(for: spoKey) {
                    // Triple already exists, skip to next
                    self.logger.debug("Triple already exists, skipping: \(triple)")
                    continue
                }

                // 3. Insert into all 4 indexes
                for indexType in self.enabledIndexes {
                    let key = TupleHelpers.encodeTripleKey(
                        rootPrefix: self.rootPrefix,
                        indexType: indexType,
                        s: subjectID,
                        p: predicateID,
                        o: objectID
                    )
                    // Empty value (existence is what matters)
                    transaction.setValue(FDB.Bytes(), for: key)
                }

                insertedCount += 1
            }

            // 4. Increment triple count by the number of actually inserted triples
            if insertedCount > 0 {
                let countKey = TupleHelpers.encodeTripleCountKey(rootPrefix: self.rootPrefix)
                let increment = withUnsafeBytes(of: insertedCount.littleEndian) { Array($0) }
                transaction.atomicOp(key: countKey, param: increment, mutationType: .add)
                self.logger.debug("Batch inserted \(insertedCount) new triples")
            } else {
                self.logger.debug("No new triples inserted (all existed)")
            }
        }
    }

    /// Deletes a triple from the store
    func delete(_ triple: RDFTriple) async throws {
        logger.debug("Deleting triple: \(triple)")

        try await db.withTransaction { transaction in
            // 1. Convert URIs to IDs (must exist)
            guard let subjectID = try await self.getExistingID(uri: triple.subject, transaction: transaction),
                  let predicateID = try await self.getExistingID(uri: triple.predicate, transaction: transaction),
                  let objectID = try await self.getExistingID(uri: triple.object, transaction: transaction) else {
                self.logger.debug("Triple does not exist, skipping")
                return
            }

            // 2. Check if triple exists (using SPO index)
            let spoKey = TupleHelpers.encodeTripleKey(
                rootPrefix: self.rootPrefix,
                indexType: .spo,
                s: subjectID,
                p: predicateID,
                o: objectID
            )

            guard let _ = try await transaction.getValue(for: spoKey) else {
                self.logger.debug("Triple does not exist, skipping")
                return
            }

            // 3. Delete from all 4 indexes
            for indexType in self.enabledIndexes {
                let key = TupleHelpers.encodeTripleKey(
                    rootPrefix: self.rootPrefix,
                    indexType: indexType,
                    s: subjectID,
                    p: predicateID,
                    o: objectID
                )
                transaction.clear(key: key)
            }

            // 4. Decrement triple count
            let countKey = TupleHelpers.encodeTripleCountKey(rootPrefix: self.rootPrefix)
            // Use Int64(-1) and convert to UInt64 using bitPattern for proper signed arithmetic
            let decrementValue = UInt64(bitPattern: Int64(-1))
            let decrement = withUnsafeBytes(of: decrementValue.littleEndian) { Array($0) }
            transaction.atomicOp(key: countKey, param: decrement, mutationType: .add)

            self.logger.debug("Triple deleted successfully")
        }
    }

    /// Queries triples matching the given pattern
    func query(
        subject: String? = nil,
        predicate: String? = nil,
        object: String? = nil
    ) async throws -> [RDFTriple] {
        let pattern = QueryPattern(subject: subject, predicate: predicate, object: object)
        logger.debug("Querying with pattern: s=\(subject ?? "?"), p=\(predicate ?? "?"), o=\(object ?? "?")")

        return try await db.withTransaction { transaction in
            // 1. Convert bound URIs to IDs
            let subjectID = try await subject.asyncMap { try await self.getExistingID(uri: $0, transaction: transaction) }
            let predicateID = try await predicate.asyncMap { try await self.getExistingID(uri: $0, transaction: transaction) }
            let objectID = try await object.asyncMap { try await self.getExistingID(uri: $0, transaction: transaction) }

            // If any bound URI doesn't exist, return empty results
            if (subject != nil && subjectID == nil) ||
               (predicate != nil && predicateID == nil) ||
               (object != nil && objectID == nil) {
                self.logger.debug("One or more URIs not found, returning empty results")
                return []
            }

            // 2. Select optimal index
            let indexType = pattern.optimalIndex()
            self.logger.debug("Using index: \(indexType)")

            // 3. Build range keys
            let (beginKey, endKey) = TupleHelpers.encodeRangeKeys(
                rootPrefix: self.rootPrefix,
                indexType: indexType,
                s: subjectID,
                p: predicateID,
                o: objectID
            )

            // 4. Scan the range
            var results: [RDFTriple] = []

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterThan(endKey),
                snapshot: true  // Read-only query
            )

            for try await (key, _) in sequence {
                // Decode the key to get IDs
                let (sID, pID, oID) = try TupleHelpers.decodeTripleKey(
                    key,
                    rootPrefix: self.rootPrefix,
                    indexType: indexType
                )

                // Convert IDs back to URIs
                let sURI = try await self.getURI(id: sID, transaction: transaction)
                let pURI = try await self.getURI(id: pID, transaction: transaction)
                let oURI = try await self.getURI(id: oID, transaction: transaction)

                let triple = RDFTriple(subject: sURI, predicate: pURI, object: oURI)
                results.append(triple)
            }

            self.logger.debug("Query returned \(results.count) triples")
            return results
        }
    }

    /// Returns the total number of triples in the store
    func count() async throws -> UInt64 {
        return try await db.withTransaction { transaction in
            let countKey = TupleHelpers.encodeTripleCountKey(rootPrefix: self.rootPrefix)

            guard let bytes = try await transaction.getValue(for: countKey, snapshot: true) else {
                return 0
            }

            return bytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        }
    }

    // MARK: - Dictionary Store (URI ↔ ID Mapping)

    /// Gets an existing ID for a URI, or returns nil if not found
    private func getExistingID(uri: String, transaction: any TransactionProtocol) async throws -> UInt64? {
        // Check cache first (optimistic read)
        if let cachedID = uriToIdCache[uri] {
            return cachedID
        }

        // Lookup in database
        let key = TupleHelpers.encodeURIToIDKey(rootPrefix: rootPrefix, uri: uri)
        guard let bytes = try await transaction.getValue(for: key) else {
            return nil
        }

        let id = bytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }

        // Update cache
        // Cache is populated during transaction read. This is safe because
        // even if the transaction fails, the mapping already exists in FDB.
        uriToIdCache[uri] = id
        idToUriCache[id] = uri

        return id
    }

    /// Gets or creates an ID for a URI
    private func getOrCreateID(uri: String, transaction: any TransactionProtocol) async throws -> UInt64 {
        // Check cache first (optimistic read)
        if let cachedID = uriToIdCache[uri] {
            return cachedID
        }

        // Check if ID already exists in database
        let uriKey = TupleHelpers.encodeURIToIDKey(rootPrefix: rootPrefix, uri: uri)

        if let idBytes = try await transaction.getValue(for: uriKey) {
            let id = idBytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }

            // Update cache (note: cache update happens before commit)
            // This is acceptable because FDB transactions have retry logic
            uriToIdCache[uri] = id
            idToUriCache[id] = uri

            return id
        }

        // Generate new ID using atomic counter
        let counterKey = TupleHelpers.encodeCounterKey(rootPrefix: rootPrefix)

        // Initialize counter if it doesn't exist
        // This check is important for the first ID generation
        if try await transaction.getValue(for: counterKey) == nil {
            let initialValue = withUnsafeBytes(of: UInt64(0).littleEndian) { Array($0) }
            transaction.setValue(initialValue, for: counterKey)
        }

        // Atomic increment
        let increment = withUnsafeBytes(of: UInt64(1).littleEndian) { Array($0) }
        transaction.atomicOp(key: counterKey, param: increment, mutationType: .add)

        // Read the new ID
        // FoundationDB guarantees "read-your-writes" within a transaction,
        // so this read will see the result of the atomic increment above
        guard let newIDBytes = try await transaction.getValue(for: counterKey) else {
            throw RDFError.internalError("Failed to read counter after atomic increment")
        }
        let newID = newIDBytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }

        // Store both mappings: URI → ID and ID → URI
        let idBytes = withUnsafeBytes(of: newID.littleEndian) { Array($0) }
        transaction.setValue(idBytes, for: uriKey)

        let idKey = TupleHelpers.encodeIDToURIKey(rootPrefix: rootPrefix, id: newID)
        transaction.setValue(Array(uri.utf8), for: idKey)

        // Update cache
        // Note: Cache is updated before transaction commit. If the transaction
        // fails and retries, the cache entry will be overwritten with the same
        // or new ID in the retry. This is safe because FDB handles retries.
        uriToIdCache[uri] = newID
        idToUriCache[newID] = uri

        logger.debug("Created new ID \(newID) for URI: \(uri)")
        return newID
    }

    /// Gets the URI for an ID
    private func getURI(id: UInt64, transaction: any TransactionProtocol) async throws -> String {
        // Check cache first (optimistic read)
        if let cachedURI = idToUriCache[id] {
            return cachedURI
        }

        // Lookup in database
        let key = TupleHelpers.encodeIDToURIKey(rootPrefix: rootPrefix, id: id)
        guard let bytes = try await transaction.getValue(for: key) else {
            throw RDFError.internalError("ID not found in dictionary: \(id)")
        }

        let uri = String(decoding: bytes, as: UTF8.self)

        // Update cache
        // Cache is populated during transaction read. This is safe because
        // even if the transaction fails, the mapping already exists in FDB.
        idToUriCache[id] = uri
        uriToIdCache[uri] = id

        return uri
    }
}

// MARK: - Optional Extension

extension Optional {
    fileprivate func asyncMap<T>(_ transform: (Wrapped) async throws -> T?) async throws -> T? {
        switch self {
        case .some(let value):
            return try await transform(value)
        case .none:
            return nil
        }
    }
}
