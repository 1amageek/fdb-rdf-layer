# fdb-rdf-layer アーキテクチャ設計書

**Version:** 1.2 (Final)
**Date:** 2025-10-30
**Target:** Swift 6.0+, FoundationDB 7.1+, fdb-swift-bindings

---

## 目次

1. [概要](#1-概要)
2. [設計の進化と批判的考察](#2-設計の進化と批判的考察)
3. [システムアーキテクチャ](#3-システムアーキテクチャ)
4. [キーエンコーディング戦略](#4-キーエンコーディング戦略)
5. [サブスペース管理](#5-サブスペース管理)
6. [トランザクション管理](#6-トランザクション管理)
7. [Metadata Management](#7-metadata-management)
8. [インデックス戦略](#8-インデックス戦略)
9. [オンラインインデックス構築](#9-オンラインインデックス構築)
10. [クエリプランニング](#10-クエリプランニング)
11. [コンポーネント詳細設計](#11-コンポーネント詳細設計)
12. [パフォーマンス最適化](#12-パフォーマンス最適化)
13. [運用とモニタリング](#13-運用とモニタリング)

---

## 1. 概要

### 1.1 プロジェクトの目的

`fdb-rdf-layer` は FoundationDB 上に構築される高性能な RDF (Resource Description Framework) トリプルストアです。既存の FoundationDB レイヤー（fdb-record-layer、fdb-document-layer）の設計パターンを批判的に評価し、RDFの特性に最適化された設計を採用しています。

### 1.2 設計目標

- **スケーラビリティ**: 1億トリプル規模に対応
- **一貫性**: ACID トランザクション保証
- **パフォーマンス**: 最適化されたインデックス選択とストリーミング
- **保守性**: 階層化されたアーキテクチャ
- **型安全性**: Swift 6 の Actor モデルを活用
- **耐障害性**: オンラインインデックス構築の中断・再開サポート

### 1.3 主要な技術選択

| 技術 | 採用理由 |
|------|----------|
| **Swift 6** | Actor モデルによる並行安全性、async/await |
| **FoundationDB 7.1+** | 分散トランザクション、水平スケーリング |
| **Tuple Encoding** | 構造化されたキー、辞書順保証 |
| **6インデックス戦略** | あらゆるクエリパターンに対応 |

---

## 2. 設計の進化と批判的考察

### 2.1 設計プロセスの概要

本プロジェクトは、既存の FoundationDB レイヤーを詳細に調査し、RDFの特性と照らし合わせて批判的に評価するプロセスを経て設計されました。

#### 調査した既存レイヤー

1. **fdb-swift-bindings**: 基本API、Tuple encoding、withTransaction
2. **fdb-document-layer**: Metadata管理、Plugin Architecture、Index実装
3. **fdb-record-layer**: Online Indexing、RangeSet、Throttling

#### 評価基準

各機能を以下の4つの基準で評価（各5点、合計20点満点）：

1. **RDFの特性との適合性**: トリプルストアに合っているか？
2. **複雑さとのトレードオフ**: 利益が複雑さを正当化するか？
3. **既存設計との整合性**: Swift 6の特性を活かしているか？
4. **実装の優先度**: 今すぐ必要か？

**採用基準**: 総合点 15点以上

### 2.2 設計の進化

#### v1.0: 初期設計（fdb-swift-bindings ベース）

**採用した機能:**
- ✅ Tuple Encoding（20/20点）
- ✅ withTransaction パターン（19/20点）
- ✅ AsyncKVSequence ストリーミング（18/20点）
- ✅ Atomic Operations（17/20点）

**設計の特徴:**
- 6インデックス戦略
- Dictionary Store（URI↔ID）
- Actor ベースのコンポーネント

#### v1.1: Metadata Management 追加（fdb-document-layer からの学習）

**採用した機能:**
- ✅ **Metadata Version Management**（19/20点）
  - 複数インスタンスでのキャッシュ整合性に必須
  - Atomic ADD でシンプルに実装可能

**不採用の機能:**
- ❌ Plugin Architecture（8/20点）
  - RDFは固定6インデックス、拡張性不要
  - Decorator PatternをSwift + Actorで実装すると複雑
- ❌ DocumentDeferred Pattern（8/20点）
  - withTransaction で原子性は保証済み
- ❌ Three-Level Context Hierarchy（7/20点）
  - RDFの構造には過剰

#### v1.2: Online Indexing 追加（fdb-record-layer からの学習）

**採用した機能:**
- ✅ **RangeSet による進捗追跡**（16/20点）
  - 大規模データセット対応に必須
  - 中断・再開が可能（耐障害性）
  - 並行構築をサポート

- ✅ **IndexingThrottle による適応的スロットリング**（17/20点）
  - transaction_too_large エラー回避
  - 動的な最適化
  - システム保護

**不採用の機能:**
- ❌ KeySpace + DirectoryLayer（9/20点）
  - RDFはフラット構造
  - Phase 6（マルチテナント）で再検討
- ❌ FDBRecordContext 抽象化（8/20点）
  - withTransaction で十分
  - 過剰な抽象化
- ❌ IndexingByIndex 戦略（7/20点）
  - RDFには不適（6インデックスすべて同じソースから構築）

### 2.3 批判的考察の重要な教訓

#### 教訓1: 鵜呑みにしない

既存の実装が「ベストプラクティス」でも、自分のユースケースに最適とは限らない。

**具体例:** fdb-record-layerの `FDBRecordContext` は強力だが、RDFには `withTransaction` の方がシンプルで十分。

#### 教訓2: 文脈を考慮する

機能の価値は文脈依存。RDFレイヤーの特性を常に意識。

**具体例:**
- RDFは固定6インデックス → Plugin Architecture不要
- RDFはフラット構造 → KeySpace/DirectoryLayer不要

#### 教訓3: トレードオフの定量化

「良い機能」ではなく「利益 > コスト」で評価。

**評価項目:**
- 実装の複雑さ（LOC、テストケース数）
- パフォーマンス向上（ベンチマーク）
- 機能の価値（ユーザー価値）

---

## 3. システムアーキテクチャ

### 3.1 レイヤー構造（v1.2 最終版）

```
Swift Application
      ↓
  RDFStore (Public API)
      ↓
  MetadataManager
  (バージョン管理・キャッシュ)
      ↓
┌──────────────────────────────────┐
│  OnlineIndexBuilder              │
│  ├─ RangeSet (進捗追跡)          │
│  └─ IndexingThrottle (スロットリング)│
└──────────────────────────────────┘
      ↓
QueryPlanner → IndexManager → DictionaryStore
      ↓             ↓               ↓
       SubspaceManager (Tuple Encoding)
                ↓
        fdb-swift-bindings
                ↓
        FoundationDB Cluster
```

### 3.2 コンポーネント責務

| コンポーネント | 責務 | Actor | Phase |
|----------------|------|-------|-------|
| **RDFStore** | 公開API、CRUD操作 | ✅ | Phase 1 |
| **MetadataManager** | バージョン管理、キャッシュ | ✅ | Phase 1 |
| **OnlineIndexBuilder** | オンラインインデックス構築 | ✅ | Phase 4 |
| **QueryPlanner** | インデックス選択、最適化 | ✅ | Phase 3 |
| **IndexManager** | 6インデックス管理 | ✅ | Phase 2 |
| **DictionaryStore** | URI↔ID マッピング | ✅ | Phase 2 |
| **SubspaceManager** | Tuple エンコーディング | ❌ Struct | Phase 1 |
| **RDFTriple** | データモデル | ❌ Struct | Phase 1 |

---

## 4. キーエンコーディング戦略

### 4.1 Tuple Encoding の採用

**採用理由:**
- ✅ fdb-swift-bindings のネイティブサポート
- ✅ 辞書順ソートの保証
- ✅ 型安全なエンコード/デコード
- ✅ ネスト対応

### 4.2 トリプルインデックスキー構造

```swift
// 擬似コード
func encodeTripleKey(
    subspace: String,       // "rdf"
    indexType: UInt8,       // 0-5
    id1: UInt64,
    id2: UInt64,
    id3: UInt64
) -> FDB.Bytes {
    return Tuple(
        subspace,
        SubspaceType.triples.rawValue,  // 2
        indexType,
        Int64(id1), Int64(id2), Int64(id3)
    ).encode()
}
```

**実際のキー例:**
```
Tuple("rdf", 2, 0, 12345, 67890, 11111).encode()
  └─┘  └┘ └┘ └───┘ └───┘ └───┘
   │    │  │   │     │     └─ object_id
   │    │  │   │     └─ predicate_id
   │    │  │   └─ subject_id
   │    │  └─ SPO index (0)
   │    └─ TRIPLES subspace (2)
   └─ Root subspace name
```

### 4.3 Dictionary キー構造

#### URI → ID マッピング
```swift
let key = Tuple(rootPrefix, 1, "uri_to_id", uri).encode()
// Value: UInt64 (ID)
```

#### ID → URI 逆引き
```swift
let key = Tuple(rootPrefix, 1, "id_to_uri", Int64(id)).encode()
// Value: String (URI)
```

#### Counter キー（Atomic increment）
```swift
let key = Tuple(rootPrefix, 1, "counter").encode()
// Value: UInt64 (次に発行するID)
```

---

## 5. サブスペース管理

### 5.1 サブスペース構造（v1.2 最終版）

```
[root_prefix: "rdf"]
  ├─ [METADATA: 0]
  │   ├─ ["version"] → UInt64 (メタデータバージョンカウンター)
  │   ├─ ["schema_version"] → String (例: "1.2")
  │   └─ ["index_states", indexType] → UInt8 (インデックス状態)
  │
  ├─ [DICTIONARY: 1]
  │   ├─ ["uri_to_id", uri] → UInt64
  │   ├─ ["id_to_uri", id] → String
  │   └─ ["counter"] → UInt64
  │
  ├─ [TRIPLES: 2]
  │   ├─ [SPO: 0, id1, id2, id3] → empty
  │   ├─ [SOP: 1, id1, id2, id3] → empty
  │   ├─ [PSO: 2, id1, id2, id3] → empty
  │   ├─ [POS: 3, id1, id2, id3] → empty
  │   ├─ [OSP: 4, id1, id2, id3] → empty
  │   └─ [OPS: 5, id1, id2, id3] → empty
  │
  └─ [INDEX_BUILD: 3]
      └─ [indexType, rangeBegin] → rangeEnd (RangeSet)
```

### 5.2 SubspaceManager 実装

```swift
public struct SubspaceManager: Sendable {
    public let rootPrefix: String

    public enum Subspace: UInt8, Sendable {
        case metadata = 0
        case dictionary = 1
        case triples = 2
        case indexBuild = 3
    }

    public enum IndexType: UInt8, CaseIterable, Sendable {
        case spo = 0, sop = 1, pso = 2
        case pos = 3, osp = 4, ops = 5

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

    public func encodeTripleKey(
        indexType: IndexType,
        id1: UInt64, id2: UInt64, id3: UInt64
    ) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.triples.rawValue,
            indexType.rawValue,
            Int64(id1), Int64(id2), Int64(id3)
        ).encode()
    }

    public func metadataVersionKey() -> FDB.Bytes {
        return Tuple(rootPrefix, Subspace.metadata.rawValue, "version").encode()
    }

    public func indexStateKey(indexType: IndexType) -> FDB.Bytes {
        return Tuple(
            rootPrefix,
            Subspace.metadata.rawValue,
            "index_states",
            indexType.rawValue
        ).encode()
    }
}
```

---

## 6. トランザクション管理

### 6.1 withTransaction パターンの活用

**採用理由:**
- ✅ fdb-swift-bindings のネイティブサポート
- ✅ 自動リトライロジック
- ✅ シンプルで明確なAPI
- ✅ Swift の async/await との親和性

```swift
public actor RDFStore {
    private let db: any DatabaseProtocol

    public func insert(_ triple: RDFTriple) async throws {
        try await db.withTransaction { transaction in
            // 1. URI → ID 変換
            let sID = try await dictionary.getOrCreateID(uri: triple.subject, transaction: transaction)
            let pID = try await dictionary.getOrCreateID(uri: triple.predicate, transaction: transaction)
            let oID = try await dictionary.getOrCreateID(uri: triple.object, transaction: transaction)

            // 2. 6インデックスに書き込み
            try await indexManager.insertTriple(
                subject: sID, predicate: pID, object: oID,
                transaction: transaction
            )
            // 自動コミット、エラー時は自動リトライ
        }
    }
}
```

### 6.2 エラーハンドリング

```swift
public enum RDFError: Error, Sendable {
    case invalidURI(String)
    case tripleNotFound(RDFTriple)
    case indexNotAvailable(SubspaceManager.IndexType)
    case encodingError(String)
    case transactionFailed(FDBError)
}

// FDBError の isRetryable は withTransaction が自動処理
```

---

## 7. Metadata Management

### 7.1 概要と採用理由

**出典:** fdb-document-layer
**評価:** 19/20点
**採用理由:**
- ✅ 複数RDFStoreインスタンスでのキャッシュ整合性に必須
- ✅ Atomic ADD でシンプルに実装
- ✅ オンラインインデックス構築の前提条件

### 7.2 MetadataManager 設計

```swift
public actor MetadataManager {
    private let subspaceManager: SubspaceManager
    private var cachedVersion: UInt64?
    private var cachedIndexStates: [SubspaceManager.IndexType: IndexState]?

    public enum IndexState: UInt8, Codable, Sendable {
        case building = 0
        case readable = 1
        case disabled = 2
        case error = 3
    }

    /// メタデータバージョンを取得
    public func getMetadataVersion(
        transaction: any TransactionProtocol
    ) async throws -> UInt64 {
        let versionKey = subspaceManager.metadataVersionKey()

        guard let data = try await transaction.getValue(versionKey, snapshot: true) else {
            return 1  // 初期バージョン
        }

        return data.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }

    /// メタデータバージョンをインクリメント（Atomic操作）
    public func bumpMetadataVersion(
        transaction: any TransactionProtocol
    ) async throws {
        let versionKey = subspaceManager.metadataVersionKey()
        let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Data($0) }

        transaction.atomicOp(key: versionKey, param: increment, mutationType: .add)

        // キャッシュ無効化
        cachedVersion = nil
        cachedIndexStates = nil
    }

    /// キャッシュ付きインデックス状態取得
    public func getIndexStates(
        transaction: any TransactionProtocol
    ) async throws -> [SubspaceManager.IndexType: IndexState] {
        let currentVersion = try await getMetadataVersion(transaction: transaction)

        // キャッシュヒット&バージョン一致
        if let cached = cachedVersion, cached == currentVersion,
           let states = cachedIndexStates {
            return states
        }

        // FDBから読み込み
        let states = try await loadIndexStatesFromFDB(transaction: transaction)

        // キャッシュ更新
        cachedVersion = currentVersion
        cachedIndexStates = states

        return states
    }
}
```

### 7.3 バージョンインクリメントのタイミング

1. **インデックス状態の変更時**
2. **スキーマ初期化時**（初回起動）
3. **オンラインインデックス構築の開始/完了時**

---

## 8. インデックス戦略

### 8.1 6インデックス戦略

| Index | Key構造 | 最適なクエリパターン | 例 |
|-------|---------|----------------------|----|
| **SPO** | `(s, p, o)` | `(s, p, ?)`, `(s, ?, ?)` | "AliceがknowsしているのBob？" |
| **SOP** | `(s, o, p)` | `(s, ?, o)` | "AliceとBobの関係は？" |
| **PSO** | `(p, s, o)` | `(?, p, ?)` | "knowsしている人は誰？" |
| **POS** | `(p, o, s)` | `(?, p, o)` | "Bobをknowsしているのは？" |
| **OSP** | `(o, s, p)` | `(?, ?, o)` | "Bobについて何が言われてる？" |
| **OPS** | `(o, p, s)` | 補助的 | - |

### 8.2 IndexManager 設計

```swift
public actor IndexManager {
    private let subspaceManager: SubspaceManager
    private let metadataManager: MetadataManager

    public func insertTriple(
        subject: UInt64, predicate: UInt64, object: UInt64,
        transaction: any TransactionProtocol
    ) async throws {
        let indexStates = try await metadataManager.getIndexStates(transaction: transaction)

        for indexType in SubspaceManager.IndexType.allCases {
            let state = indexStates[indexType] ?? .readable
            guard state != .disabled && state != .error else { continue }

            let (id1, id2, id3) = reorderIDs(
                indexType: indexType,
                s: subject, p: predicate, o: object
            )

            let key = subspaceManager.encodeTripleKey(
                indexType: indexType,
                id1: id1, id2: id2, id3: id3
            )

            transaction.setValue(Data(), for: key)
        }
    }

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

---

## 9. オンラインインデックス構築

### 9.1 概要と採用理由

**出典:** fdb-record-layer
**Phase:** 4
**採用理由:**
- ✅ 大規模データセット（1億トリプル）対応
- ✅ 中断・再開が可能（耐障害性）
- ✅ 複数インスタンスでの並行構築
- ✅ プログレス追跡

### 9.2 RangeSet による進捗追跡

**評価:** 16/20点

```swift
public actor RangeSet {
    private let subspaceManager: SubspaceManager
    private let subspace: FDB.Bytes

    public init(subspaceManager: SubspaceManager, name: String) {
        self.subspaceManager = subspaceManager
        self.subspace = Tuple(
            subspaceManager.rootPrefix,
            SubspaceManager.Subspace.indexBuild.rawValue,
            name
        ).encode()
    }

    /// 範囲を追加（処理済みとしてマーク）
    public func insertRange(
        begin: Data, end: Data,
        transaction: any TransactionProtocol
    ) async throws {
        // 重複範囲をマージして保存
        let key = subspace + begin
        transaction.setValue(end, for: key)
    }

    /// 最初の未処理範囲を取得
    public func firstMissingRange(
        absoluteBegin: Data, absoluteEnd: Data,
        transaction: any TransactionProtocol
    ) async throws -> (begin: Data, end: Data)? {
        var currentPos = absoluteBegin

        let sequence = transaction.getRange(
            beginSelector: .firstGreaterOrEqual(subspace + absoluteBegin),
            endSelector: .firstGreaterOrEqual(subspace + absoluteEnd)
        )

        for try await (key, value) in sequence {
            let rangeBegin = Data(key.dropFirst(subspace.count))
            let rangeEnd = value

            if currentPos < rangeBegin {
                return (currentPos, rangeBegin)  // ギャップ発見
            }

            currentPos = max(currentPos, rangeEnd)
        }

        if currentPos < absoluteEnd {
            return (currentPos, absoluteEnd)
        }

        return nil
    }

    /// RangeSetをクリア（構築完了後）
    public func clear(transaction: any TransactionProtocol) {
        transaction.clearRange(begin: subspace, end: subspace + [0xFF])
    }
}
```

### 9.3 IndexingThrottle による適応的スロットリング

**評価:** 17/20点
**採用理由:**
- ✅ 6インデックス同時更新で transaction_too_large が起きやすい
- ✅ 動的調整で最適なバッチサイズを自動決定
- ✅ システム保護

```swift
public actor IndexingThrottle {
    private var recordsLimit: Int
    private let config: ThrottleConfig

    private var consecutiveSuccessCount: Int = 0
    private var consecutiveFailureCount: Int = 0

    public struct ThrottleConfig {
        let initialLimit: Int = 1000
        let maxLimit: Int = 10000
        let minLimit: Int = 10
        let increaseLimitAfter: Int = 5
        let recordsPerSecond: Int? = nil
    }

    public func recordSuccess(recordsScanned: Int) async throws {
        consecutiveSuccessCount += 1
        consecutiveFailureCount = 0

        if consecutiveSuccessCount >= config.increaseLimitAfter {
            recordsLimit = increaseLimit(recordsLimit)
            consecutiveSuccessCount = 0
        }
    }

    public func recordFailure(recordsScanned: Int, error: Error) async {
        consecutiveSuccessCount = 0
        consecutiveFailureCount += 1

        if shouldDecreaseLimit(error: error) {
            recordsLimit = decreaseLimit(currentLimit: recordsLimit, failedAt: recordsScanned)
        }
    }

    private func increaseLimit(_ oldLimit: Int) -> Int {
        let newLimit: Int
        if oldLimit < 5 { newLimit = oldLimit + 5 }
        else if oldLimit < 100 { newLimit = oldLimit * 2 }
        else { newLimit = oldLimit * 4 / 3 }
        return min(newLimit, config.maxLimit)
    }

    private func decreaseLimit(currentLimit: Int, failedAt: Int) -> Int {
        let reductionFactor = consecutiveFailureCount > 1 ? 0.5 : 0.8
        return max(Int(Double(failedAt) * reductionFactor), config.minLimit)
    }

    private func shouldDecreaseLimit(error: Error) -> Bool {
        if let fdbError = error as? FDB.Error {
            return fdbError.code == 2101  // transaction_too_large
        }
        return false
    }
}
```

### 9.4 OnlineIndexBuilder

```swift
public actor OnlineIndexBuilder {
    private let store: RDFStore
    private let indexType: SubspaceManager.IndexType
    private let rangeSet: RangeSet
    private let throttle: IndexingThrottle

    public func buildIndex() async throws {
        logger.info("Starting online index build", metadata: ["indexType": "\(indexType)"])

        while true {
            // 1. 次の未処理範囲を取得
            let missingRange = try await store.db.withTransaction { transaction in
                try await rangeSet.firstMissingRange(
                    absoluteBegin: Data(),
                    absoluteEnd: Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
                    transaction: transaction
                )
            }

            guard let range = missingRange else {
                logger.info("Index build complete")
                break
            }

            // 2. 範囲を処理
            let recordsProcessed = try await buildRange(begin: range.begin, end: range.end)

            // 3. スロットリング
            try await throttle.recordSuccess(recordsScanned: recordsProcessed)

            // 4. 進捗を記録
            try await store.db.withTransaction { transaction in
                try await rangeSet.insertRange(begin: range.begin, end: range.end, transaction: transaction)
            }
        }

        // 5. 完了処理
        try await store.db.withTransaction { transaction in
            rangeSet.clear(transaction: transaction)
        }
    }
}
```

---

## 10. クエリプランニング

### 10.1 QueryPlanner 設計

```swift
public actor QueryPlanner {
    private let subspaceManager: SubspaceManager
    private let dictionary: DictionaryStore

    public struct QueryPlan: Sendable {
        public let indexType: SubspaceManager.IndexType
        public let beginSelector: FDB.KeySelector
        public let endSelector: FDB.KeySelector
        public let needsFiltering: Bool
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

        return QueryPlan(
            indexType: indexType,
            beginSelector: .firstGreaterOrEqual(begin),
            endSelector: .firstGreaterOrEqual(end),
            needsFiltering: false
        )
    }
}
```

---

## 11. コンポーネント詳細設計

### 11.1 RDFTriple

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

### 11.2 DictionaryStore

```swift
public actor DictionaryStore {
    private let subspaceManager: SubspaceManager

    public func getOrCreateID(
        uri: String,
        transaction: any TransactionProtocol
    ) async throws -> UInt64 {
        let uriKey = subspaceManager.dictionaryURIKey(uri: uri)

        if let existingData = try await transaction.getValue(uriKey, snapshot: false) {
            return decodeID(existingData)
        }

        let newID = try await allocateNewID(transaction: transaction)

        transaction.setValue(encodeID(newID), for: uriKey)

        let idKey = subspaceManager.dictionaryIDKey(id: newID)
        transaction.setValue(Data(uri.utf8), for: idKey)

        return newID
    }

    private func allocateNewID(transaction: any TransactionProtocol) async throws -> UInt64 {
        let counterKey = subspaceManager.dictionaryCounterKey()
        let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Data($0) }

        transaction.atomicOp(key: counterKey, param: increment, mutationType: .add)

        guard let data = try await transaction.getValue(counterKey, snapshot: false) else {
            let initialValue = encodeID(1)
            transaction.setValue(initialValue, for: counterKey)
            return 1
        }

        return decodeID(data)
    }

    private func encodeID(_ id: UInt64) -> Data {
        return withUnsafeBytes(of: id.littleEndian) { Data($0) }
    }

    private func decodeID(_ data: Data) -> UInt64 {
        return data.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
    }
}
```

### 11.3 RDFStore（Public API）

```swift
import FoundationDB
import Logging

public actor RDFStore {
    private let db: any DatabaseProtocol
    private let subspaceManager: SubspaceManager
    private let indexManager: IndexManager
    private let dictionary: DictionaryStore
    private let metadataManager: MetadataManager
    private let logger: Logger

    public init(database: any DatabaseProtocol, rootPrefix: String = "rdf") async throws {
        self.db = database
        self.subspaceManager = SubspaceManager(rootPrefix: rootPrefix)
        self.dictionary = DictionaryStore(subspaceManager: subspaceManager)
        self.metadataManager = MetadataManager(subspaceManager: subspaceManager)
        self.indexManager = IndexManager(
            subspaceManager: subspaceManager,
            metadataManager: metadataManager
        )

        var logger = Logger(label: "com.fdb-rdf-layer.RDFStore")
        logger.logLevel = .info
        self.logger = logger

        try await initializeSchema()
    }

    // CRUD Operations
    public func insert(_ triple: RDFTriple) async throws {
        try await db.withTransaction { transaction in
            let sID = try await self.dictionary.getOrCreateID(uri: triple.subject, transaction: transaction)
            let pID = try await self.dictionary.getOrCreateID(uri: triple.predicate, transaction: transaction)
            let oID = try await self.dictionary.getOrCreateID(uri: triple.object, transaction: transaction)

            try await self.indexManager.insertTriple(
                subject: sID, predicate: pID, object: oID,
                transaction: transaction
            )
        }
    }

    public func delete(_ triple: RDFTriple) async throws {
        try await db.withTransaction { transaction in
            guard let sID = try await self.dictionary.getID(uri: triple.subject, transaction: transaction) else { return }
            guard let pID = try await self.dictionary.getID(uri: triple.predicate, transaction: transaction) else { return }
            guard let oID = try await self.dictionary.getID(uri: triple.object, transaction: transaction) else { return }

            try await self.indexManager.deleteTriple(
                subject: sID, predicate: pID, object: oID,
                transaction: transaction
            )
        }
    }

    public func query(
        subject: String? = nil,
        predicate: String? = nil,
        object: String? = nil
    ) async throws -> [RDFTriple] {
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

                if self.matches(triple, subject: subject, predicate: predicate, object: object) {
                    results.append(triple)
                }
            }

            return results
        }
    }
}
```

---

## 12. パフォーマンス最適化

### 12.1 Dictionary キャッシング

```swift
extension DictionaryStore {
    private var cache: [String: UInt64] = [:]
    private let cacheLimit = 10_000

    func getOrCreateID(uri: String, transaction: any TransactionProtocol) async throws -> UInt64 {
        if let cachedID = cache[uri] {
            return cachedID
        }

        let id = try await lookupOrCreateID(uri: uri, transaction: transaction)

        if cache.count >= cacheLimit {
            cache.removeValue(forKey: cache.keys.first!)
        }
        cache[uri] = id

        return id
    }
}
```

### 12.2 バッチ操作

```swift
extension RDFStore {
    public func insertBatch(_ triples: [RDFTriple]) async throws {
        try await db.withTransaction { transaction in
            let allURIs = Set(triples.flatMap { [$0.subject, $0.predicate, $0.object] })
            let uriToID = try await dictionary.batchGetOrCreateIDs(uris: Array(allURIs), transaction: transaction)

            for triple in triples {
                let s = uriToID[triple.subject]!
                let p = uriToID[triple.predicate]!
                let o = uriToID[triple.object]!

                try await indexManager.insertTriple(subject: s, predicate: p, object: o, transaction: transaction)
            }
        }
    }
}
```

---

## 13. 運用とモニタリング

### 13.1 ロギング

```swift
import Logging

// すべてのコンポーネントでLogger使用
actor RDFStore {
    private let logger: Logger

    init(...) {
        var logger = Logger(label: "com.fdb-rdf-layer.RDFStore")
        logger.logLevel = .info
        self.logger = logger
    }

    func insert(_ triple: RDFTriple) async throws {
        logger.info("Inserting triple", metadata: [
            "subject": "\(triple.subject)",
            "predicate": "\(triple.predicate)",
            "object": "\(triple.object)"
        ])
        // ...
    }
}
```

### 13.2 メトリクス

```swift
extension RDFStore {
    public struct Metrics {
        var insertCount: UInt64 = 0
        var queryCount: UInt64 = 0
        var deleteCount: UInt64 = 0
        var errorCount: UInt64 = 0
    }

    private var metrics = Metrics()

    public func getMetrics() -> Metrics {
        return metrics
    }
}
```

---

## 付録A: 実装ロードマップ

### Phase 1: 基礎（Week 1-2）
- [ ] SubspaceManager
- [ ] MetadataManager
- [ ] RDFTriple, RDFError

### Phase 2: コア機能（Week 3-4）
- [ ] DictionaryStore
- [ ] IndexManager
- [ ] RDFStore

### Phase 3: クエリ（Week 5-6）
- [ ] QueryPlanner
- [ ] 統合テスト

### Phase 4: オンラインインデックス構築（Week 7-8）
- [ ] RangeSet
- [ ] IndexingThrottle
- [ ] OnlineIndexBuilder

### Phase 5: 最適化（Week 9-10）
- [ ] Dictionary キャッシング
- [ ] バッチ操作
- [ ] 統計情報収集

### Phase 6: 高度な機能（Week 11+）
- [ ] KeySpace/DirectoryLayer（マルチテナント）
- [ ] Plugin Architecture（全文検索）
- [ ] SPARQL パーサー

---

## 付録B: 成功指標

### 技術的指標
- 1億トリプルの挿入: < 2時間
- クエリレイテンシ: < 100ms (99パーセンタイル)
- インデックス構築速度: > 10,000 トリプル/秒

### 運用指標
- 中断・再開成功率: 100%
- transaction_too_large エラー: 0%（スロットリング後）

### コード品質指標
- テストカバレッジ: > 80%
- ドキュメント整備率: 100%（全public API）

---

**Built with ❤️ using Swift and FoundationDB**
