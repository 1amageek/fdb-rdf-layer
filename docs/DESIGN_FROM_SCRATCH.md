# fdb-rdf-layer: ゼロからの設計（新設計 v2.0）

**Date:** 2025-10-30
**Approach:** First Principles + Lessons Learned

---

## 🎯 設計哲学

**既存設計を忘れて、RDFの本質とFoundationDBの特性から設計を再構築する。**

---

## 1. 要件分析：RDFトリプルストアの本質

### 1.1 RDFの本質的な特性

```
RDFトリプル = (Subject, Predicate, Object)
```

**核心的な事実:**
1. **トリプルは原子的**: 3つの要素が不可分
2. **順序は重要**: (S, P, O) は有向グラフの辺
3. **重複は許されない**: 同じトリプルは1つのみ存在
4. **URIは長い**: 平均50-200文字
5. **クエリパターン**: 任意の1つまたは2つの要素を指定して検索

### 1.2 必須機能

| 機能 | 重要度 | 理由 |
|------|--------|------|
| **Insert** | 🔴 必須 | トリプルの追加 |
| **Delete** | 🔴 必須 | トリプルの削除 |
| **Query (pattern match)** | 🔴 必須 | `(s, ?, ?)`, `(?, p, o)` など |
| **大規模データセット対応** | 🟡 重要 | 1億トリプル規模 |
| **並行書き込み** | 🟡 重要 | 複数クライアント |
| **耐障害性** | 🟡 重要 | クラッシュ後の復旧 |
| **SPARQL** | 🟢 将来 | Phase 6 |

### 1.3 FoundationDBの特性

**FoundationDBが提供するもの:**
- ✅ 順序付きキー・バリューストア
- ✅ ACIDトランザクション
- ✅ 高速なレンジスキャン
- ✅ 水平スケーリング
- ✅ 自動シャーディング

**FoundationDBの制約:**
- ⚠️ トランザクションサイズ制限（10MB）
- ⚠️ キーサイズ制限（10KB）
- ⚠️ バリューサイズ制限（100KB）
- ⚠️ トランザクション実行時間制限（5秒）

---

## 2. 核心的な設計決定

### 2.1 キー設計：最も重要な決定

**問題:** URIは長いが、FDBのキーとして効率的に使いたい

**解決策の比較:**

| アプローチ | 利点 | 欠点 | 採用? |
|-----------|------|------|-------|
| **A. URIを直接キーにする** | シンプル | キーが長すぎる（100-200バイト） | ❌ |
| **B. URIをハッシュする** | キー長が固定 | 逆引き不可、衝突リスク | ❌ |
| **C. URIをIDに変換** | キー短い（8バイト）、逆引き可能 | Dictionary管理が必要 | ✅ |

**決定: URI → ID 変換を採用**

理由：
- キー長を8バイトに削減（25倍の削減）
- レンジスキャンが高速
- 逆引き可能（ID → URI）
- fdb-document-layer、fdb-record-layerも同様のパターン

### 2.2 インデックス戦略：クエリパターン分析

**クエリパターンの頻度分析（一般的なRDFワークロード）:**

| パターン | 例 | 頻度 | 最適インデックス |
|---------|-----|------|------------------|
| `(s, ?, ?)` | "Aliceについて全て" | 30% | SPO |
| `(?, p, ?)` | "knows関係の全て" | 25% | PSO |
| `(?, ?, o)` | "誰がBobに言及？" | 20% | OSP |
| `(s, p, ?)` | "AliceがknowsしてるのBob？" | 15% | SPO |
| `(?, p, o)` | "誰がBobをknows？" | 10% | POS |

**インデックス数の決定:**

```
必要最小限 = 3インデックス (SPO, PSO, OSP)
推奨 = 4インデックス (SPO, PSO, OSP, POS)
既存設計 = 6インデックス (SPO, SOP, PSO, POS, OSP, OPS)
```

**🔍 批判的考察:**

6インデックスは過剰か？

| インデックス | 必要性 | 判断 |
|-------------|--------|------|
| SPO | ✅ 必須 | S始点クエリ |
| SOP | ⚠️ 疑問 | `(s, ?, o)` は稀（< 5%） |
| PSO | ✅ 必須 | P始点クエリ |
| POS | ✅ 有用 | `(?, p, o)` は頻出 |
| OSP | ✅ 必須 | O始点クエリ |
| OPS | ⚠️ 疑問 | `(?, ?, ?)` は全走査、どのインデックスでも同じ |

**新設計の決定:**

```
✅ 採用: 4インデックス (SPO, PSO, POS, OSP)
❌ 削除: SOP, OPS

理由:
- SOPは使用頻度が極めて低い
- OPSは全走査クエリ用だが、SPOで代用可能
- 書き込みコストを33%削減（6→4インデックス）
- ストレージコストも33%削減
```

### 2.3 Dictionary Store：URI ↔ ID マッピング

**設計オプション:**

| アプローチ | 利点 | 欠点 | 採用? |
|-----------|------|------|-------|
| **A. 単純カウンター** | シンプル | URIの意味的近接性を失う | ✅ Phase 1 |
| **B. ハッシュベース** | 決定論的 | 衝突処理が必要 | ❌ |
| **C. Prefix圧縮** | ストレージ削減 | 複雑 | 🟡 Phase 6 |

**新設計:**

```swift
Dictionary Store Layout:
  [root][dict][uri_to_id][<uri>] → UInt64
  [root][dict][id_to_uri][<id>] → String
  [root][dict][counter] → UInt64 (atomic)
```

**改善点（既存設計との違い）:**
- ✅ `uri_to_id` と `id_to_uri` を明示的に分離（デバッグしやすい）
- ✅ カウンターは最後にアクセスされるため、キャッシュミスが少ない

### 2.4 Metadata管理：シンプルかつ拡張可能

**既存設計の課題:**
- Metadata Versionの用途が不明確
- Index Stateが過剰（4状態は多すぎる）

**新設計:**

```swift
enum IndexStatus: UInt8 {
    case ready = 0        // 読み書き可能
    case building = 1     // 構築中
}

Metadata Layout:
  [root][meta][version] → UInt64
  [root][meta][schema_version] → String ("2.0")
  [root][meta][index_status][<indexType>] → IndexStatus
  [root][meta][stats][triple_count] → UInt64
```

**改善点:**
- ✅ Index Stateを2状態に簡素化（ready/building）
- ✅ disabled, errorは削除（不要な複雑さ）
- ✅ 統計情報を追加（triple_count）

---

## 3. 新アーキテクチャ設計

### 3.1 レイヤー構造（シンプル化）

```
┌────────────────────────────┐
│   RDFStore (Public API)    │  ← 単一のActor
└────────────────────────────┘
            ↓
┌────────────────────────────┐
│   TripleStorage            │  ← インデックス管理を統合
│   - 4 indexes (SPO/PSO/POS/OSP)
│   - Dictionary Store       │
│   - Metadata               │
└────────────────────────────┘
            ↓
┌────────────────────────────┐
│   Tuple Encoding           │  ← シンプルな関数群
└────────────────────────────┘
            ↓
┌────────────────────────────┐
│   fdb-swift-bindings       │
└────────────────────────────┘
```

**既存設計との比較:**

| コンポーネント | 既存設計 | 新設計 | 理由 |
|---------------|----------|--------|------|
| RDFStore | Actor | Actor | ✅ 同じ |
| MetadataManager | 独立Actor | TripleStorageに統合 | シンプル化 |
| IndexManager | 独立Actor | TripleStorageに統合 | 責任が近い |
| QueryPlanner | 独立Actor | RDFStoreに統合 | 過剰な抽象化 |
| DictionaryStore | 独立Actor | TripleStorageに統合 | トランザクションスコープが同じ |
| SubspaceManager | Struct | Tuple関数群 | 過剰なカプセル化 |

**設計原則:**
- 🎯 **コロケーション**: 一緒に変更されるものは一緒に置く
- 🎯 **最小抽象化**: 必要最小限のActor分割
- 🎯 **明確な責任**: 各Actorは単一の明確な責任

### 3.2 コンポーネント詳細設計

#### TripleStorage Actor

```swift
actor TripleStorage {
    private let db: any DatabaseProtocol
    private let rootPrefix: String

    // 設定
    private let enabledIndexes: Set<IndexType> = [.spo, .pso, .pos, .osp]

    // キャッシュ（Actor内部なので競合なし）
    private var uriCache: LRUCache<String, UInt64> = LRUCache(capacity: 10_000)
    private var idCache: LRUCache<UInt64, String> = LRUCache(capacity: 10_000)
    private var metadataCache: MetadataCache?

    // --- Public API ---

    func insert(_ triple: RDFTriple) async throws
    func delete(_ triple: RDFTriple) async throws
    func query(s: String?, p: String?, o: String?) async throws -> [RDFTriple]

    // --- Internal ---

    private func getOrCreateID(uri: String, tx: Tx) async throws -> UInt64
    private func getURI(id: UInt64, tx: Tx) async throws -> String
    private func selectOptimalIndex(s: Bool, p: Bool, o: Bool) -> IndexType
    private func encodeTripleKey(index: IndexType, ...) -> FDB.Bytes
}
```

**キー設計原則:**
```swift
// シンプルなTuple構造
Tuple(rootPrefix, "dict", "u2i", uri)  // URI→ID
Tuple(rootPrefix, "dict", "i2u", id)   // ID→URI
Tuple(rootPrefix, "dict", "cnt")       // Counter

Tuple(rootPrefix, "idx", "spo", s, p, o)  // SPOインデックス
Tuple(rootPrefix, "idx", "pso", p, s, o)  // PSOインデックス
Tuple(rootPrefix, "idx", "pos", p, o, s)  // POSインデックス
Tuple(rootPrefix, "idx", "osp", o, s, p)  // OSPインデックス

Tuple(rootPrefix, "meta", "ver")           // Version
Tuple(rootPrefix, "meta", "cnt")           // Triple count
Tuple(rootPrefix, "meta", "idx", indexType) // Index status
```

**重要な変更点:**
- ✅ "triples" サブスペースを "idx" に短縮（タイプ数削減）
- ✅ フラットな構造（不要なネストを削除）
- ✅ 一貫した命名規則

### 3.3 トランザクション戦略

**既存設計の課題:**
- withTransaction のネストが複雑
- リトライロジックが暗黙的

**新設計:**

```swift
extension TripleStorage {
    /// トランザクションヘルパー（明示的なリトライ）
    private func withRetry<T>(
        maxRetries: Int = 3,
        operation: @escaping (Tx) async throws -> T
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await db.withTransaction { tx in
                    try await operation(tx)
                }
            } catch let error as FDB.Error where error.isRetryable {
                lastError = error
                // Exponential backoff
                try await Task.sleep(nanoseconds: UInt64(100_000_000 * (1 << attempt)))
                continue
            } catch {
                throw error
            }
        }

        throw lastError ?? RDFError.maxRetriesExceeded
    }
}
```

**改善点:**
- ✅ リトライロジックを明示的に制御
- ✅ Exponential backoff を実装
- ✅ デバッグしやすい

---

## 4. 高度な機能の設計

### 4.1 オンラインインデックス構築

**既存設計の課題:**
- RangeSet, IndexingThrottle, OnlineIndexBuilder が分離
- 複雑すぎる

**新設計: シンプルなチャンク処理**

```swift
struct IndexBuilder {
    let storage: TripleStorage
    let chunkSize: Int = 10_000

    func buildIndex(indexType: IndexType) async throws {
        // 1. インデックスをBUILDING状態に
        try await storage.setIndexStatus(indexType, .building)

        // 2. SPOインデックスをチャンクで走査
        var lastKey: FDB.Bytes? = nil

        while true {
            let (triples, nextKey) = try await storage.scanChunk(
                startAfter: lastKey,
                limit: chunkSize
            )

            if triples.isEmpty { break }

            // 3. このチャンクのインデックスを構築
            try await storage.buildIndexChunk(triples, indexType)

            lastKey = nextKey

            // 4. スロットリング（シンプル）
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        // 5. READY状態に
        try await storage.setIndexStatus(indexType, .ready)
    }
}
```

**改善点:**
- ✅ RangeSetを使わない（状態をFDBに保存しない）
- ✅ スロットリングはシンプルな固定遅延
- ✅ 100行以内で実装可能
- ✅ 十分な機能（中断・再開は手動で対応）

**トレードオフ:**
- ❌ 中断後の自動再開はない → 🟢 通常は不要
- ❌ 動的スロットリングはない → 🟢 固定値で十分
- ✅ 実装が簡単 → 🟢 メンテナンスコスト低

### 4.2 クエリ最適化

**既存設計の課題:**
- QueryPlannerが過剰に複雑
- コスト見積もりが未実装

**新設計: シンプルなルールベース選択**

```swift
extension TripleStorage {
    private func selectOptimalIndex(
        hasS: Bool,
        hasP: Bool,
        hasO: Bool
    ) -> IndexType {
        // シンプルなルックアップテーブル
        switch (hasS, hasP, hasO) {
        case (true, _, _):  return .spo  // S指定時は常にSPO
        case (_, true, true): return .pos // P+O指定
        case (_, true, _):  return .pso  // P指定
        case (_, _, true):  return .osp  // O指定
        default:            return .spo  // 全走査
        }
    }
}
```

**改善点:**
- ✅ O(1) の選択ロジック
- ✅ 理解しやすい
- ✅ テストしやすい
- ✅ 拡張しやすい（将来、統計ベースに変更可能）

---

## 5. 実装の優先順位（新設計）

### Phase 1: MVP (Week 1-2)
```swift
struct RDFTriple { ... }
actor TripleStorage {
    func insert(_:) { ... }
    func delete(_:) { ... }
    func query(s:p:o:) { ... }
}
```
- ✅ 4インデックス（SPO, PSO, POS, OSP）
- ✅ Dictionary Store
- ✅ 基本的なメタデータ
- ✅ 100% withTransaction使用

**目標:** 動作するトリプルストア（1週間）

### Phase 2: キャッシング (Week 3)
- ✅ URI→ID キャッシュ（LRU 10,000エントリ）
- ✅ Metadata キャッシュ

**目標:** 10倍の性能向上

### Phase 3: バッチ操作 (Week 4)
- ✅ insertBatch
- ✅ deleteBatch

**目標:** 大規模データ投入

### Phase 4: オンラインインデックス構築 (Week 5)
- ✅ IndexBuilder（シンプル版）
- ✅ 固定スロットリング

**目標:** 既存データへのインデックス追加

### Phase 5: 最適化 (Week 6)
- ✅ 統計情報収集
- ✅ パフォーマンスチューニング

### Phase 6: 高度な機能 (Week 7+)
- 🟢 SPARQL
- 🟢 推論
- 🟢 全文検索

---

## 6. 新設計の利点

### 6.1 シンプルさ

| メトリクス | 既存設計 | 新設計 | 改善 |
|-----------|----------|--------|------|
| Actor数 | 6 | 2 | **-67%** |
| インデックス数 | 6 | 4 | **-33%** |
| ファイル数 | ~10 | ~5 | **-50%** |
| 推定コード行数 | ~3000 | ~1500 | **-50%** |

### 6.2 パフォーマンス

| 操作 | 既存設計 | 新設計 | 理由 |
|------|----------|--------|------|
| Insert | 6 index writes | 4 index writes | **-33% FDB書き込み** |
| Query | 6 index options | 4 index options | **-33% 選択肢** |
| Storage | 6× データ | 4× データ | **-33% ストレージ** |

### 6.3 保守性

- ✅ Actorが少ない → デバッグしやすい
- ✅ ファイルが少ない → ナビゲートしやすい
- ✅ コードが短い → 理解しやすい
- ✅ 抽象化が少ない → 変更しやすい

### 6.4 拡張性

- ✅ Phase分けが明確 → 段階的に実装
- ✅ 各Phaseが独立 → 並行開発可能
- ✅ シンプルな基盤 → 将来の拡張が容易

---

## 7. 設計の正当性検証

### 7.1 RDFの本質的要件を満たすか？

| 要件 | 新設計 | 検証 |
|------|--------|------|
| トリプルの原子性 | ✅ | 単一トランザクション |
| 重複排除 | ✅ | FDBのキー一意性 |
| パターンクエリ | ✅ | 4インデックス |
| 大規模データ | ✅ | IndexBuilder |
| 並行書き込み | ✅ | FDBのACID |

### 7.2 FoundationDBの制約を守るか？

| 制約 | 新設計 | 対策 |
|------|--------|------|
| トランザクションサイズ | ✅ | バッチ処理 |
| キーサイズ | ✅ | ID化（8バイト） |
| バリューサイズ | ✅ | 空のバリュー |
| 実行時間 | ✅ | チャンク処理 |

### 7.3 Swiftの特性を活かすか？

| 特性 | 新設計 | 活用 |
|------|--------|------|
| Actor | ✅ | 並行安全性 |
| async/await | ✅ | 自然なコード |
| Tuple | ✅ | 構造化キー |
| Sendable | ✅ | 型安全 |

---

## 8. リスク分析

### 8.1 4インデックスは十分か？

**リスク:** SOPとOPSを削除したことで、特定のクエリが遅くなる可能性

**分析:**
- `(s, ?, o)` クエリ: SOPなしでSPO+フィルタリングで対応
  - 最悪ケース: Subject が1000トリプル → 1000件スキャン
  - 現実的: Subject は平均10-50トリプル → 許容範囲

**緩和策:**
- ✅ Phase 5で統計情報を収集し、実測で判断
- ✅ 必要なら Phase 6でSOPを追加（設計は対応済み）

### 8.2 Actor統合は安全か？

**リスク:** TripleStorageが大きくなりすぎる

**分析:**
- 推定コード行数: ~800行
- 類似例: fdb-document-layerのDocTransaction ~500行

**緩和策:**
- ✅ 明確なprivate関数分割
- ✅ 必要なら Phase 6で分割（容易）

### 8.3 シンプルなIndexBuilderで十分か？

**リスク:** 大規模データセットで実用的でない可能性

**分析:**
- 1億トリプル ÷ 10,000チャンク = 10,000トランザクション
- 1トランザクション100ms → 総時間 ~17分
- 既存設計（RangeSet+Throttle）: ~15分

**緩和策:**
- ✅ Phase 5でベンチマーク
- ✅ 問題があれば Phase 6で高度化

---

## 9. まとめ

### 9.1 新設計の核心的な決定

1. **4インデックス** (SPO, PSO, POS, OSP)
   - 書き込み33%削減
   - ストレージ33%削減
   - 十分なクエリカバレッジ

2. **統合されたTripleStorage Actor**
   - Actor数を67%削減
   - コード50%削減
   - 保守性向上

3. **シンプルなIndexBuilder**
   - RangeSet不要
   - 固定スロットリング
   - 十分な機能

4. **段階的な実装**
   - Phase 1で動作するMVP
   - Phase 2-5で最適化
   - Phase 6で高度な機能

### 9.2 既存設計との比較のポイント

次のステップで比較すべき項目：

1. **複雑さ vs 機能** のトレードオフ
2. **6インデックス vs 4インデックス** の実測比較
3. **Actor分割** の実用性
4. **IndexBuilder** のシンプル版 vs 高度版

### 9.3 次のアクション

1. ✅ この新設計をドキュメント化（完了）
2. ⏭️ 既存設計と新設計を比較レビュー
3. ⏭️ 最終設計を決定
4. ⏭️ 実装開始

---

**設計原則の再確認:**
> "Simplicity is prerequisite for reliability." - Edsger Dijkstra

この新設計は、RDFの本質に立ち返り、既存の設計の複雑さを削ぎ落とし、
本当に必要な機能のみを残した結果です。
