import Foundation
import FoundationDB

// MARK: - Tuple Helpers

/// Helper functions for encoding and decoding tuple-based keys
enum TupleHelpers {

    // MARK: - Dictionary Keys

    /// Encodes a key for URI → ID mapping
    /// Format: (rootPrefix, "dict", "u2i", uri)
    static func encodeURIToIDKey(rootPrefix: String, uri: String) -> FDB.Bytes {
        return Tuple(rootPrefix, "dict", "u2i", uri).encode()
    }

    /// Encodes a key for ID → URI mapping
    /// Format: (rootPrefix, "dict", "i2u", id)
    static func encodeIDToURIKey(rootPrefix: String, id: UInt64) -> FDB.Bytes {
        return Tuple(rootPrefix, "dict", "i2u", Int64(bitPattern: id)).encode()
    }

    /// Encodes the ID counter key
    /// Format: (rootPrefix, "dict", "cnt")
    static func encodeCounterKey(rootPrefix: String) -> FDB.Bytes {
        return Tuple(rootPrefix, "dict", "cnt").encode()
    }

    // MARK: - Index Keys

    /// Encodes a triple key for a specific index type
    /// - SPO: (rootPrefix, "idx", "spo", s, p, o)
    /// - PSO: (rootPrefix, "idx", "pso", p, s, o)
    /// - POS: (rootPrefix, "idx", "pos", p, o, s)
    /// - OSP: (rootPrefix, "idx", "osp", o, s, p)
    static func encodeTripleKey(
        rootPrefix: String,
        indexType: IndexType,
        s: UInt64,
        p: UInt64,
        o: UInt64
    ) -> FDB.Bytes {
        let sInt = Int64(bitPattern: s)
        let pInt = Int64(bitPattern: p)
        let oInt = Int64(bitPattern: o)

        switch indexType {
        case .spo:
            return Tuple(rootPrefix, "idx", "spo", sInt, pInt, oInt).encode()
        case .pso:
            return Tuple(rootPrefix, "idx", "pso", pInt, sInt, oInt).encode()
        case .pos:
            return Tuple(rootPrefix, "idx", "pos", pInt, oInt, sInt).encode()
        case .osp:
            return Tuple(rootPrefix, "idx", "osp", oInt, sInt, pInt).encode()
        }
    }

    /// Encodes a prefix key for range queries
    /// Returns (beginKey, endKey) for the specified pattern
    static func encodeRangeKeys(
        rootPrefix: String,
        indexType: IndexType,
        s: UInt64?,
        p: UInt64?,
        o: UInt64?
    ) -> (beginKey: FDB.Bytes, endKey: FDB.Bytes) {
        let sInt = s.map { Int64(bitPattern: $0) }
        let pInt = p.map { Int64(bitPattern: $0) }
        let oInt = o.map { Int64(bitPattern: $0) }

        switch indexType {
        case .spo:
            return encodeRangeSPO(rootPrefix: rootPrefix, s: sInt, p: pInt, o: oInt)
        case .pso:
            return encodeRangePSO(rootPrefix: rootPrefix, p: pInt, s: sInt, o: oInt)
        case .pos:
            return encodeRangePOS(rootPrefix: rootPrefix, p: pInt, o: oInt, s: sInt)
        case .osp:
            return encodeRangeOSP(rootPrefix: rootPrefix, o: oInt, s: sInt, p: pInt)
        }
    }

    // MARK: - Decode Helpers

    /// Decodes a triple key and returns (s, p, o) IDs
    static func decodeTripleKey(
        _ key: FDB.Bytes,
        rootPrefix: String,
        indexType: IndexType
    ) throws -> (s: UInt64, p: UInt64, o: UInt64) {
        let prefixBytes = Tuple(rootPrefix, "idx", indexType.rawValue).encode()

        guard key.starts(with: prefixBytes) else {
            throw RDFError.internalError("Invalid key prefix")
        }

        let suffix = Array(key.dropFirst(prefixBytes.count))
        let elements = try Tuple.decode(from: suffix)

        guard elements.count == 3,
              let first = elements[0] as? Int64,
              let second = elements[1] as? Int64,
              let third = elements[2] as? Int64 else {
            throw RDFError.internalError("Failed to decode triple key")
        }

        switch indexType {
        case .spo:
            return (UInt64(bitPattern: first), UInt64(bitPattern: second), UInt64(bitPattern: third))
        case .pso:
            return (UInt64(bitPattern: second), UInt64(bitPattern: first), UInt64(bitPattern: third))
        case .pos:
            return (UInt64(bitPattern: third), UInt64(bitPattern: first), UInt64(bitPattern: second))
        case .osp:
            return (UInt64(bitPattern: second), UInt64(bitPattern: third), UInt64(bitPattern: first))
        }
    }

    // MARK: - Metadata Keys

    /// Encodes the metadata version key
    /// Format: (rootPrefix, "meta", "ver")
    static func encodeMetadataVersionKey(rootPrefix: String) -> FDB.Bytes {
        return Tuple(rootPrefix, "meta", "ver").encode()
    }

    /// Encodes the triple count key
    /// Format: (rootPrefix, "meta", "cnt")
    static func encodeTripleCountKey(rootPrefix: String) -> FDB.Bytes {
        return Tuple(rootPrefix, "meta", "cnt").encode()
    }

    /// Encodes the index status key
    /// Format: (rootPrefix, "meta", "idx", indexType)
    static func encodeIndexStatusKey(rootPrefix: String, indexType: IndexType) -> FDB.Bytes {
        return Tuple(rootPrefix, "meta", "idx", indexType.rawValue).encode()
    }

    // MARK: - Private Range Encoding

    private static func encodeRangeSPO(
        rootPrefix: String,
        s: Int64?,
        p: Int64?,
        o: Int64?
    ) -> (beginKey: FDB.Bytes, endKey: FDB.Bytes) {
        let prefix = Tuple(rootPrefix, "idx", "spo").encode()

        // Build the begin key based on bound variables
        var beginKey = prefix
        var endKey = prefix + [0xFF]

        if let s = s {
            beginKey = Tuple(rootPrefix, "idx", "spo", s).encode()
            endKey = Tuple(rootPrefix, "idx", "spo", s).encode() + [0xFF]

            if let p = p {
                beginKey = Tuple(rootPrefix, "idx", "spo", s, p).encode()
                endKey = Tuple(rootPrefix, "idx", "spo", s, p).encode() + [0xFF]

                if let o = o {
                    beginKey = Tuple(rootPrefix, "idx", "spo", s, p, o).encode()
                    endKey = Tuple(rootPrefix, "idx", "spo", s, p, o).encode() + [0xFF]
                }
            }
        }

        return (beginKey, endKey)
    }

    private static func encodeRangePSO(
        rootPrefix: String,
        p: Int64?,
        s: Int64?,
        o: Int64?
    ) -> (beginKey: FDB.Bytes, endKey: FDB.Bytes) {
        let prefix = Tuple(rootPrefix, "idx", "pso").encode()

        var beginKey = prefix
        var endKey = prefix + [0xFF]

        if let p = p {
            beginKey = Tuple(rootPrefix, "idx", "pso", p).encode()
            endKey = Tuple(rootPrefix, "idx", "pso", p).encode() + [0xFF]

            if let s = s {
                beginKey = Tuple(rootPrefix, "idx", "pso", p, s).encode()
                endKey = Tuple(rootPrefix, "idx", "pso", p, s).encode() + [0xFF]

                if let o = o {
                    beginKey = Tuple(rootPrefix, "idx", "pso", p, s, o).encode()
                    endKey = Tuple(rootPrefix, "idx", "pso", p, s, o).encode() + [0xFF]
                }
            }
        }

        return (beginKey, endKey)
    }

    private static func encodeRangePOS(
        rootPrefix: String,
        p: Int64?,
        o: Int64?,
        s: Int64?
    ) -> (beginKey: FDB.Bytes, endKey: FDB.Bytes) {
        let prefix = Tuple(rootPrefix, "idx", "pos").encode()

        var beginKey = prefix
        var endKey = prefix + [0xFF]

        if let p = p {
            beginKey = Tuple(rootPrefix, "idx", "pos", p).encode()
            endKey = Tuple(rootPrefix, "idx", "pos", p).encode() + [0xFF]

            if let o = o {
                beginKey = Tuple(rootPrefix, "idx", "pos", p, o).encode()
                endKey = Tuple(rootPrefix, "idx", "pos", p, o).encode() + [0xFF]

                if let s = s {
                    beginKey = Tuple(rootPrefix, "idx", "pos", p, o, s).encode()
                    endKey = Tuple(rootPrefix, "idx", "pos", p, o, s).encode() + [0xFF]
                }
            }
        }

        return (beginKey, endKey)
    }

    private static func encodeRangeOSP(
        rootPrefix: String,
        o: Int64?,
        s: Int64?,
        p: Int64?
    ) -> (beginKey: FDB.Bytes, endKey: FDB.Bytes) {
        let prefix = Tuple(rootPrefix, "idx", "osp").encode()

        var beginKey = prefix
        var endKey = prefix + [0xFF]

        if let o = o {
            beginKey = Tuple(rootPrefix, "idx", "osp", o).encode()
            endKey = Tuple(rootPrefix, "idx", "osp", o).encode() + [0xFF]

            if let s = s {
                beginKey = Tuple(rootPrefix, "idx", "osp", o, s).encode()
                endKey = Tuple(rootPrefix, "idx", "osp", o, s).encode() + [0xFF]

                if let p = p {
                    beginKey = Tuple(rootPrefix, "idx", "osp", o, s, p).encode()
                    endKey = Tuple(rootPrefix, "idx", "osp", o, s, p).encode() + [0xFF]
                }
            }
        }

        return (beginKey, endKey)
    }
}
