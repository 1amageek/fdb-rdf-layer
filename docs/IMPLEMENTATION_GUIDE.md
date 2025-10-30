# fdb-rdf-layer 実装ガイド

**Version:** 1.0
**Date:** 2025-10-30

このドキュメントは、ARCHITECTURE.md で定義された設計を実装するためのステップバイステップガイドです。

---

## 📋 実装フェーズ

### フェーズ 1: 基礎コンポーネント（優先度: 最高）

#### 1.1 RDFTriple データモデル
**ファイル:** `Sources/RDFLayer/RDFTriple.swift`

```swift
public struct RDFTriple: Hashable, Codable, Sendable {
    public let subject: String
    public let predicate: String
    public let object: String

    public init(subject: String, predicate: String, object: String) {
        self.subject = subject
        self.predicate = predicate
        self.object = object
    }
}
```

**テスト:**
- `testTripleEquality`: 同一トリプルの等価性
- `testTripleHashing`: ハッシュ値の一貫性
- `testTripleCodable`: JSON エンコード/デコード

---

#### 1.2 RDFError 定義
**ファイル:** `Sources/RDFLayer/RDFError.swift`

```swift
public enum RDFError: Error, Sendable {
    case invalidURI(String)
    case tripleNotFound(RDFTriple)
    case indexNotAvailable(SubspaceManager.IndexType)
    case encodingError(String)
    case decodingError(String)
    case transactionFailed(FDBError)
}
```

---

#### 1.3 SubspaceManager
**ファイル:** `Sources/RDFLayer/SubspaceManager.swift`

**実装優先度:**
1. ✅ 基本構造とenums定義
2. ✅ Triple key encoding/decoding
3. ✅ Dictionary key encoding
4. ✅ Range key generation

**重要な実装ポイント:**
```swift
import FoundationDB

public struct SubspaceManager: Sendable {
    public let rootPrefix: String

    public enum Subspace: UInt8, Sendable {
        case metadata = 0
        case dictionary = 1
        case triples = 2
        case indexState = 3
    }

    public enum IndexType: UInt8, CaseIterable, Sendable {
        case spo = 0
        case sop = 1
        case pso = 2
        case pos = 3
        case osp = 4
        case ops = 5

        /// クエリパターンに最適なインデックスを選択
        public static func selectOptimal(
            hasSubject: Bool,
            hasPredicate: Bool,
            hasObject: Bool
        ) -> Self {
            switch (hasSubject, hasPredicate, hasObject) {
            case (true, true, true):   return .spo
            case (true, true, false):  return .spo
            case (true, false, true):  return .sop
            case (true, false, false): return .spo
            case (false, true, true):  return .pos
            case (false, true, false): return .pso
            case (false, false, true): return .osp
            case (false, false, false): return .spo
            }
        }
    }

    public init(rootPrefix: String) {
        self.rootPrefix = rootPrefix
    }

    // Triple key encoding
    public func encodeTripleKey(
        indexType: IndexType,
        id1: UInt64,
        id2: UInt64,
        id3: UInt64
    ) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.triples.rawValue,
            indexType.rawValue,
            Int64(id1),  // Tuple は Int64 を使用
            Int64(id2),
            Int64(id3)
        ).encode()
    }

    // Range keys
    public func tripleRangeBegin(indexType: IndexType) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.triples.rawValue,
            indexType.rawValue
        ).encode()
    }

    public func tripleRangeEnd(indexType: IndexType) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.triples.rawValue,
            indexType.rawValue + 1
        ).encode()
    }

    // Dictionary keys
    public func dictionaryURIKey(uri: String) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.dictionary.rawValue,
            "uri_to_id",
            uri
        ).encode()
    }

    public func dictionaryIDKey(id: UInt64) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.dictionary.rawValue,
            "id_to_uri",
            Int64(id)
        ).encode()
    }

    public func dictionaryCounterKey() -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.dictionary.rawValue,
            "counter"
        ).encode()
    }
}
```

**テスト:**
- `testTripleKeyEncoding`: トリプルキーのエンコード検証
- `testRangeKeyGeneration`: レンジキーの正確性
- `testDictionaryKeys`: Dictionary キーの一意性
- `testIndexTypeSelection`: 最適インデックス選択ロジック

---

### フェーズ 2: Dictionary Store（優先度: 高）

#### 2.1 DictionaryStore 実装
**ファイル:** `Sources/RDFLayer/DictionaryStore.swift`

**実装ステップ:**
1. ✅ `getOrCreateID` - URI → ID 変換（新規作成含む）
2. ✅ `getID` - 既存URIのIDのみ取得
3. ✅ `getURI` - ID → URI 逆引き
4. ✅ `allocateNewID` - Atomic increment によるID発行
5. ⏭️ `batchGetOrCreateIDs` - バッチ処理（最適化）

**重要な実装ポイント:**
```swift
import FoundationDB

public actor DictionaryStore {
    private let subspaceManager: SubspaceManager

    public init(subspaceManager: SubspaceManager) {
        self.subspaceManager = subspaceManager
    }

    /// URI → ID 変換（存在しなければ作成）
    public func getOrCreateID(
        uri: String,
        transaction: any TransactionProtocol
    ) async throws -> UInt64 {
        let uriKey = subspaceManager.dictionaryURIKey(uri: uri)

        // 既存のIDを取得
        if let existingData = try await transaction.getValue(uriKey, snapshot: false) {
            return decodeID(existingData)
        }

        // 新規ID発行（atomicインクリメント）
        let newID = try await allocateNewID(transaction: transaction)

        // URI → ID マッピングを保存
        let idData = encodeID(newID)
        transaction.setValue(idData, for: uriKey)

        // ID → URI 逆引きマッピングも保存
        let idKey = subspaceManager.dictionaryIDKey(id: newID)
        transaction.setValue(Data(uri.utf8), for: idKey)

        return newID
    }

    /// ID → URI 逆引き
    public func getURI(
        id: UInt64,
        transaction: any TransactionProtocol
    ) async throws -> String {
        let idKey = subspaceManager.dictionaryIDKey(id: id)

        guard let data = try await transaction.getValue(idKey, snapshot: true) else {
            throw RDFError.invalidURI("ID \(id) not found")
        }

        guard let uri = String(data: data, encoding: .utf8) else {
            throw RDFError.encodingError("Invalid UTF-8 data for ID \(id)")
        }

        return uri
    }

    /// URI が存在する場合のみIDを取得
    public func getID(
        uri: String,
        transaction: any TransactionProtocol
    ) async throws -> UInt64? {
        let uriKey = subspaceManager.dictionaryURIKey(uri: uri)

        guard let data = try await transaction.getValue(uriKey, snapshot: true) else {
            return nil
        }

        return decodeID(data)
    }

    /// 新規IDをアトミックに発行
    private func allocateNewID(
        transaction: any TransactionProtocol
    ) async throws -> UInt64 {
        let counterKey = subspaceManager.dictionaryCounterKey()

        // Atomic increment
        let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Data($0) }
        transaction.atomicOp(
            key: counterKey,
            param: increment,
            mutationType: .add
        )

        // 新しい値を読み取り
        guard let data = try await transaction.getValue(counterKey, snapshot: false) else {
            // カウンターが存在しない場合は1から開始
            let initialValue = encodeID(1)
            transaction.setValue(initialValue, for: counterKey)
            return 1
        }

        return decodeID(data)
    }

    // UInt64 → Data エンコード（リトルエンディアン）
    private func encodeID(_ id: UInt64) -> Data {
        return withUnsafeBytes(of: id.littleEndian) { Data($0) }
    }

    // Data → UInt64 デコード
    private func decodeID(_ data: Data) -> UInt64 {
        return data.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }
}
```

**テスト:**
- `testGetOrCreateID_NewURI`: 新規URI作成
- `testGetOrCreateID_ExistingURI`: 既存URI取得
- `testGetURI`: ID→URI逆引き
- `testAtomicIDAllocation`: 並行ID発行の一意性
- `testURINotFound`: 存在しないIDのエラーハンドリング

---

### フェーズ 3: Index Manager（優先度: 高）

#### 3.1 IndexManager 実装
**ファイル:** `Sources/RDFLayer/IndexManager.swift`

**実装ステップ:**
1. ✅ `insertTriple` - 全6インデックスに追加
2. ✅ `deleteTriple` - 全6インデックスから削除
3. ✅ `reorderIDs` - インデックスタイプに応じた並び替え
4. ⏭️ `loadIndexStates` - インデックス状態の永続化（最適化）
5. ⏭️ `updateIndexState` - インデックス状態の更新（最適化）

**重要な実装ポイント:**
```swift
import FoundationDB

public actor IndexManager {
    private let subspaceManager: SubspaceManager

    public init(subspaceManager: SubspaceManager) {
        self.subspaceManager = subspaceManager
    }

    /// 全インデックスにトリプルを追加
    public func insertTriple(
        subject: UInt64,
        predicate: UInt64,
        object: UInt64,
        transaction: any TransactionProtocol
    ) async throws {
        for indexType in SubspaceManager.IndexType.allCases {
            let (id1, id2, id3) = reorderIDs(
                indexType: indexType,
                s: subject, p: predicate, o: object
            )

            let key = subspaceManager.encodeTripleKey(
                indexType: indexType,
                id1: id1, id2: id2, id3: id3
            )

            // 空の値を設定（存在フラグとして）
            transaction.setValue(Data(), for: key)
        }
    }

    /// トリプルを削除
    public func deleteTriple(
        subject: UInt64,
        predicate: UInt64,
        object: UInt64,
        transaction: any TransactionProtocol
    ) async throws {
        for indexType in SubspaceManager.IndexType.allCases {
            let (id1, id2, id3) = reorderIDs(
                indexType: indexType,
                s: subject, p: predicate, o: object
            )

            let key = subspaceManager.encodeTripleKey(
                indexType: indexType,
                id1: id1, id2: id2, id3: id3
            )

            transaction.clear(key: key)
        }
    }

    /// インデックスタイプに応じてIDを並べ替え
    private func reorderIDs(
        indexType: SubspaceManager.IndexType,
        s: UInt64, p: UInt64, o: UInt64
    ) -> (UInt64, UInt64, UInt64) {
        switch indexType {
        case .spo: return (s, p, o)
        case .sop: return (s, o, p)
        case .pso: return (p, s, o)
        case .pos: return (p, o, s)
        case .osp: return (o, s, p)
        case .ops: return (o, p, s)
        }
    }
}
```

**テスト:**
- `testInsertTriple`: 6インデックスすべてに書き込み
- `testDeleteTriple`: 6インデックスすべてから削除
- `testReorderIDs`: 各インデックスタイプの並び替え正確性

---

### フェーズ 4: Query Planner（優先度: 中）

#### 4.1 QueryPlanner 実装
**ファイル:** `Sources/RDFLayer/QueryPlanner.swift`

**実装ステップ:**
1. ✅ `planQuery` - クエリパターン分析とプラン生成
2. ✅ `buildRange` - レンジキーの構築
3. ⏭️ `estimateCost` - コスト見積もり（最適化）

**重要な実装ポイント:**
```swift
import FoundationDB

public actor QueryPlanner {
    private let subspaceManager: SubspaceManager
    private let dictionary: DictionaryStore

    public struct QueryPlan: Sendable {
        public let indexType: SubspaceManager.IndexType
        public let beginSelector: FDB.KeySelector
        public let endSelector: FDB.KeySelector
        public let needsFiltering: Bool
    }

    public init(
        subspaceManager: SubspaceManager,
        dictionary: DictionaryStore
    ) {
        self.subspaceManager = subspaceManager
        self.dictionary = dictionary
    }

    public func planQuery(
        subject: String?,
        predicate: String?,
        object: String?
    ) async throws -> QueryPlan {
        // 1. インデックス選択
        let indexType = SubspaceManager.IndexType.selectOptimal(
            hasSubject: subject != nil,
            hasPredicate: predicate != nil,
            hasObject: object != nil
        )

        // 2. レンジキーの構築
        let (begin, end) = try await buildRange(
            indexType: indexType,
            subject: subject,
            predicate: predicate,
            object: object
        )

        // 3. 後フィルタリングの必要性判定
        let needsFiltering = false  // 簡易実装では不要

        return QueryPlan(
            indexType: indexType,
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            needsFiltering: needsFiltering
        )
    }

    private func buildRange(
        indexType: SubspaceManager.IndexType,
        subject: String?,
        predicate: String?,
        object: String?
    ) async throws -> (begin: FDB.Bytes, end: FDB.Bytes) {
        // 指定されたURIをIDに変換
        var ids: [UInt64?] = [nil, nil, nil]

        // インデックスタイプに応じて適切な順序で配置
        switch indexType {
        case .spo:
            ids[0] = subject != nil ? try await dictionary.getID(uri: subject!, transaction: /* dummy */ nil) : nil
            ids[1] = predicate != nil ? try await dictionary.getID(uri: predicate!, transaction: /* dummy */ nil) : nil
            ids[2] = object != nil ? try await dictionary.getID(uri: object!, transaction: /* dummy */ nil) : nil
        // ... 他のケース
        default:
            break
        }

        // Range キーの構築
        let begin = buildBeginKey(indexType: indexType, ids: ids)
        let end = buildEndKey(indexType: indexType, ids: ids)

        return (begin, end)
    }

    // ... buildBeginKey, buildEndKey の実装
}
```

**注意:** QueryPlanner の完全実装には、トランザクションコンテキストの整理が必要です。

**テスト:**
- `testPlanQuery_AllSpecified`: 完全一致クエリ
- `testPlanQuery_SubjectOnly`: Subject のみ指定
- `testPlanQuery_PredicateOnly`: Predicate のみ指定
- `testIndexSelection`: 各パターンでの最適インデックス選択

---

### フェーズ 5: RDFStore Public API（優先度: 最高）

#### 5.1 RDFStore 実装
**ファイル:** `Sources/RDFLayer/RDFStore.swift`

**実装ステップ:**
1. ✅ `init` - 初期化とスキーマセットアップ
2. ✅ `insert` - 単一トリプル挿入
3. ✅ `delete` - 単一トリプル削除
4. ✅ `query` - パターンマッチングクエリ
5. ⏭️ `insertBatch` - バッチ挿入（最適化）
6. ⏭️ `deleteBatch` - バッチ削除（最適化）

**最小実装:**
```swift
import FoundationDB
import Logging

public actor RDFStore {
    private let db: any DatabaseProtocol
    private let subspaceManager: SubspaceManager
    private let indexManager: IndexManager
    private let dictionary: DictionaryStore
    private let logger: Logger

    public init(
        database: any DatabaseProtocol,
        rootPrefix: String = "rdf"
    ) async throws {
        self.db = database
        self.subspaceManager = SubspaceManager(rootPrefix: rootPrefix)
        self.dictionary = DictionaryStore(subspaceManager: subspaceManager)
        self.indexManager = IndexManager(subspaceManager: subspaceManager)

        var logger = Logger(label: "com.fdb-rdf-layer.RDFStore")
        logger.logLevel = .info
        self.logger = logger

        try await initializeSchema()
    }

    public func insert(_ triple: RDFTriple) async throws {
        logger.info("Inserting triple", metadata: [
            "subject": "\(triple.subject)",
            "predicate": "\(triple.predicate)",
            "object": "\(triple.object)"
        ])

        try await db.withTransaction { transaction in
            let sID = try await self.dictionary.getOrCreateID(
                uri: triple.subject,
                transaction: transaction
            )
            let pID = try await self.dictionary.getOrCreateID(
                uri: triple.predicate,
                transaction: transaction
            )
            let oID = try await self.dictionary.getOrCreateID(
                uri: triple.object,
                transaction: transaction
            )

            try await self.indexManager.insertTriple(
                subject: sID,
                predicate: pID,
                object: oID,
                transaction: transaction
            )
        }
    }

    public func delete(_ triple: RDFTriple) async throws {
        try await db.withTransaction { transaction in
            guard let sID = try await self.dictionary.getID(
                uri: triple.subject,
                transaction: transaction
            ) else { return }

            guard let pID = try await self.dictionary.getID(
                uri: triple.predicate,
                transaction: transaction
            ) else { return }

            guard let oID = try await self.dictionary.getID(
                uri: triple.object,
                transaction: transaction
            ) else { return }

            try await self.indexManager.deleteTriple(
                subject: sID,
                predicate: pID,
                object: oID,
                transaction: transaction
            )
        }
    }

    public func query(
        subject: String? = nil,
        predicate: String? = nil,
        object: String? = nil
    ) async throws -> [RDFTriple] {
        // 簡易実装: SPOインデックスのみ使用
        let indexType = SubspaceManager.IndexType.selectOptimal(
            hasSubject: subject != nil,
            hasPredicate: predicate != nil,
            hasObject: object != nil
        )

        return try await db.withTransaction { transaction in
            var results: [RDFTriple] = []

            let begin = self.subspaceManager.tripleRangeBegin(indexType: indexType)
            let end = self.subspaceManager.tripleRangeEnd(indexType: indexType)

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(begin),
                endSelector: .firstGreaterOrEqual(end)
            )

            for try await (key, _) in sequence {
                let triple = try await self.decodeTriple(
                    key: key,
                    indexType: indexType,
                    transaction: transaction
                )

                // フィルタリング
                if self.matches(triple, subject: subject, predicate: predicate, object: object) {
                    results.append(triple)
                }
            }

            return results
        }
    }

    private func decodeTriple(
        key: FDB.Bytes,
        indexType: SubspaceManager.IndexType,
        transaction: any TransactionProtocol
    ) async throws -> RDFTriple {
        let elements = try Tuple.decode(from: key)

        guard elements.count >= 6 else {
            throw RDFError.decodingError("Invalid key structure")
        }

        let id1 = UInt64(elements[3] as! Int64)
        let id2 = UInt64(elements[4] as! Int64)
        let id3 = UInt64(elements[5] as! Int64)

        let (sID, pID, oID) = reorderFromIndex(
            indexType: indexType,
            id1: id1, id2: id2, id3: id3
        )

        let subject = try await dictionary.getURI(id: sID, transaction: transaction)
        let predicate = try await dictionary.getURI(id: pID, transaction: transaction)
        let object = try await dictionary.getURI(id: oID, transaction: transaction)

        return RDFTriple(subject: subject, predicate: predicate, object: object)
    }

    private func reorderFromIndex(
        indexType: SubspaceManager.IndexType,
        id1: UInt64, id2: UInt64, id3: UInt64
    ) -> (s: UInt64, p: UInt64, o: UInt64) {
        switch indexType {
        case .spo: return (id1, id2, id3)
        case .sop: return (id1, id3, id2)
        case .pso: return (id2, id1, id3)
        case .pos: return (id3, id1, id2)
        case .osp: return (id2, id3, id1)
        case .ops: return (id3, id2, id1)
        }
    }

    private func matches(
        _ triple: RDFTriple,
        subject: String?,
        predicate: String?,
        object: String?
    ) -> Bool {
        if let s = subject, triple.subject != s { return false }
        if let p = predicate, triple.predicate != p { return false }
        if let o = object, triple.object != o { return false }
        return true
    }

    private func initializeSchema() async throws {
        try await db.withTransaction { transaction in
            let metadataKey = Tuple(
                self.subspaceManager.rootPrefix,
                SubspaceManager.Subspace.metadata.rawValue,
                "version"
            ).encode()

            transaction.setValue(Data("1.0".utf8), for: metadataKey)
        }
    }
}
```

**テスト:**
- `testInsertAndQuery`: 基本的な挿入とクエリ
- `testDelete`: トリプル削除
- `testQueryWithPatterns`: 各種パターンのクエリ
- `testConcurrentInserts`: 並行挿入の正確性

---

## 🧪 テスト戦略

### 単体テスト

各コンポーネントごとに独立したテストを作成。

```swift
import XCTest
@testable import RDFLayer
import FoundationDB

final class RDFStoreTests: XCTestCase {
    var db: any DatabaseProtocol!
    var store: RDFStore!
    var testPrefix: String!

    override func setUp() async throws {
        FDB.selectAPIVersion(710)
        db = try await FDB.openDatabase()

        testPrefix = "test-\(UUID().uuidString)"
        store = try await RDFStore(database: db, rootPrefix: testPrefix)
    }

    override func tearDown() async throws {
        // テストデータをクリーンアップ
        try await db.withTransaction { transaction in
            let clearBegin = Tuple(testPrefix).encode()
            let clearEnd = clearBegin + [0xFF]

            transaction.clearRange(begin: clearBegin, end: clearEnd)
        }
    }

    func testBasicInsertAndQuery() async throws {
        let triple = RDFTriple(
            subject: "http://example.org/alice",
            predicate: "http://xmlns.com/foaf/0.1/knows",
            object: "http://example.org/bob"
        )

        try await store.insert(triple)

        let results = try await store.query(
            subject: "http://example.org/alice",
            predicate: nil,
            object: nil
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first, triple)
    }
}
```

---

## 📝 実装チェックリスト

### フェーズ 1: 基礎（1週目）
- [ ] RDFTriple データモデル
- [ ] RDFError 定義
- [ ] SubspaceManager 完全実装
- [ ] SubspaceManager テスト

### フェーズ 2: Dictionary（1週目）
- [ ] DictionaryStore 基本実装
- [ ] Atomic operations によるID発行
- [ ] DictionaryStore テスト
- [ ] 並行アクセステスト

### フェーズ 3: Index（2週目）
- [ ] IndexManager 基本実装
- [ ] 6インデックス書き込み/削除
- [ ] IndexManager テスト

### フェーズ 4: Query（2週目）
- [ ] QueryPlanner 基本実装
- [ ] インデックス選択ロジック
- [ ] QueryPlanner テスト

### フェーズ 5: Public API（3週目）
- [ ] RDFStore 基本実装
- [ ] insert/delete/query
- [ ] 統合テスト
- [ ] パフォーマンステスト

### フェーズ 6: 最適化（4週目以降）
- [ ] Dictionary キャッシング
- [ ] バッチ操作
- [ ] 統計情報収集
- [ ] メトリクス/ロギング強化

---

## 🚀 次のステップ

1. **環境セットアップ**
   ```bash
   # FoundationDB インストール
   brew install foundationdb

   # Swift Package Manager
   swift build
   ```

2. **最小実装から開始**
   - フェーズ1から順番に実装
   - 各フェーズでテストを書く
   - CI/CD セットアップ

3. **ドキュメント整備**
   - API ドキュメント
   - 使用例
   - パフォーマンスガイド

4. **コミュニティフィードバック**
   - GitHub での公開
   - Issue/PR 受付
   - ベンチマーク公開
