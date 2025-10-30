import Foundation
import FoundationDB

// MARK: - RDF Error

/// Errors that can occur in RDF operations
public enum RDFError: Error, Sendable {
    case invalidURI(String)
    case tripleNotFound
    case dictionaryLookupFailed(uri: String)
    case indexNotReady(IndexType)
    case transactionTooLarge
    case maxRetriesExceeded
    case internalError(String)
}

extension RDFError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidURI(let uri):
            return "Invalid URI: \(uri)"
        case .tripleNotFound:
            return "Triple not found"
        case .dictionaryLookupFailed(let uri):
            return "Failed to lookup URI in dictionary: \(uri)"
        case .indexNotReady(let indexType):
            return "Index not ready: \(indexType)"
        case .transactionTooLarge:
            return "Transaction size exceeded 10MB limit"
        case .maxRetriesExceeded:
            return "Maximum retry attempts exceeded"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}

// MARK: - RDF Triple

/// An RDF triple consisting of subject, predicate, and object URIs
public struct RDFTriple: Sendable, Hashable, Codable {
    public let subject: String
    public let predicate: String
    public let object: String

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}

extension RDFTriple: CustomStringConvertible {
    public var description: String {
        "<\(subject)> <\(predicate)> <\(object)>"
    }
}

// MARK: - Index Type

/// The four index types used in the RDF store (v2.0 design)
public enum IndexType: String, Sendable, CaseIterable {
    case spo = "spo"  // Subject-Predicate-Object
    case pso = "pso"  // Predicate-Subject-Object
    case pos = "pos"  // Predicate-Object-Subject
    case osp = "osp"  // Object-Subject-Predicate
}

extension IndexType: CustomStringConvertible {
    public var description: String {
        rawValue.uppercased()
    }
}

// MARK: - Index Status

/// Status of an index
enum IndexStatus: UInt8, Sendable {
    case ready = 0     // Index is ready for read/write
    case building = 1  // Index is being built
}

// MARK: - Query Pattern

/// Represents a triple query pattern with optional components
struct QueryPattern: Sendable {
    let subject: String?
    let predicate: String?
    let object: String?

    init(subject: String? = nil, predicate: String? = nil, object: String? = nil) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }

    /// Returns the optimal index type for this query pattern
    func optimalIndex() -> IndexType {
        switch (subject != nil, predicate != nil, object != nil) {
        case (true, _, _):    return .spo  // Subject is bound
        case (false, true, true):  return .pos  // Predicate and Object are bound
        case (false, true, false): return .pso  // Only Predicate is bound
        case (false, false, true): return .osp  // Only Object is bound
        case (false, false, false): return .spo // Full scan, any index works
        }
    }

    /// Returns true if this is a full scan query (?, ?, ?)
    var isFullScan: Bool {
        subject == nil && predicate == nil && object == nil
    }
}
