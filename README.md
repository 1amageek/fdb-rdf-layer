# fdb-rdf-layer

**Swift-based RDF Triple Store built on FoundationDB**

[![Swift Version](https://img.shields.io/badge/Swift-6.0+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS-blue.svg)](https://www.apple.com/macos/)
[![FoundationDB](https://img.shields.io/badge/FoundationDB-7.1+-green.svg)](https://www.foundationdb.org)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

---

## 🎯 概要

`fdb-rdf-layer` は FoundationDB 上に構築される高性能な RDF (Resource Description Framework) トリプルストアです。
既存の FoundationDB レイヤー（[fdb-record-layer](https://github.com/FoundationDB/fdb-record-layer)、[fdb-document-layer](https://github.com/FoundationDB/fdb-document-layer)）の設計パターンを踏襲し、
Swift 6 の async/await と Actor モデルによる型安全で並行安全な API を提供します。

### 主な特徴

- ✅ **スケーラビリティ**: FoundationDB の分散トランザクションによる水平スケーリング
- ✅ **強い一貫性**: ACID トランザクション保証
- ✅ **高性能**: 6種類のインデックスによる最適化されたクエリ実行
- ✅ **型安全**: Swift 6 の Sendable チェックと Actor による並行安全性
- ✅ **ステートレス**: すべての状態を FDB に保存、水平スケーリングが容易

---

## 🏗️ アーキテクチャ

### レイヤー構造

```
Swift Application
      ↓
  RDFStore (Public API)
      ↓
  MetadataManager (バージョン管理) ← v1.1
      ↓
┌─────────────────────────────────┐
│  OnlineIndexBuilder ← v1.2 🆕   │
│  ├─ RangeSet (進捗追跡)         │
│  └─ IndexingThrottle (スロットリング)│
└─────────────────────────────────┘
      ↓
QueryPlanner → IndexManager → DictionaryStore
      ↓             ↓               ↓
       SubspaceManager (Tuple Encoding)
                ↓
        fdb-swift-bindings
                ↓
        FoundationDB Cluster
```

### 6インデックス戦略

| Index | 構造 | 最適なクエリパターン |
|-------|------|----------------------|
| SPO | Subject-Predicate-Object | `(s, p, ?)`, `(s, ?, ?)` |
| SOP | Subject-Object-Predicate | `(s, ?, o)` |
| PSO | Predicate-Subject-Object | `(?, p, ?)` |
| POS | Predicate-Object-Subject | `(?, p, o)` |
| OSP | Object-Subject-Predicate | `(?, ?, o)` |
| OPS | Object-Predicate-Subject | 将来拡張用 |

詳細は以下のドキュメントを参照してください：
- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)** - 包括的なアーキテクチャ設計書（v1.2最終版）
- **[IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md)** - 実装ステップバイステップガイド

---

## 🚀 クイックスタート

### 必要要件

- **Swift**: 6.0 以上
- **FoundationDB**: 7.1 以上
- **macOS**: 13.0 (Ventura) 以上

### インストール

#### 1. FoundationDB のインストール

```bash
# macOS (Homebrew)
brew install foundationdb

# サービス開始
brew services start foundationdb
```

#### 2. Swift Package Manager

`Package.swift` に追加:

```swift
dependencies: [
    .package(url: "https://github.com/YOUR_USERNAME/fdb-rdf-layer.git", branch: "main")
]
```

### 基本的な使い方

```swift
import FoundationDB
import RDFLayer

// FoundationDB 初期化
FDB.selectAPIVersion(710)
let db = try await FDB.openDatabase()

// RDFStore 作成
let store = try await RDFStore(database: db, rootPrefix: "my-app")

// トリプル挿入
let triple = RDFTriple(
    subject: "http://example.org/alice",
    predicate: "http://xmlns.com/foaf/0.1/knows",
    object: "http://example.org/bob"
)
try await store.insert(triple)

// クエリ実行
let results = try await store.query(
    subject: "http://example.org/alice",
    predicate: nil,
    object: nil
)

for result in results {
    print("\(result.subject) \(result.predicate) \(result.object)")
}
// 出力: http://example.org/alice http://xmlns.com/foaf/0.1/knows http://example.org/bob
```

---

## 📚 ドキュメント

### 🎯 推奨: まず読むべきドキュメント

1. **[DESIGN_FROM_SCRATCH.md](docs/DESIGN_FROM_SCRATCH.md)** 🆕🏆 - **新設計（v2.0）**
   - RDFの本質から設計を再構築
   - **4インデックス戦略**（書き込み33%高速化）
   - **2つの Actor**（コード50%削減）
   - **MVP 2週間で完成**

2. **[DESIGN_COMPARISON_REVIEW.md](docs/DESIGN_COMPARISON_REVIEW.md)** 🆕🏆 - **比較レビュー**
   - v1.2 vs v2.0 の客観的比較
   - 定量的評価（スコアカード 3.50 vs 4.70）
   - **最終推奨: v2.0を採用** 📊

### 📋 設計プロセスの記録（v1.0→v1.2の進化）

- **[ARCHITECTURE.md](docs/ARCHITECTURE.md)**: v1.0 初期設計
  - 既存レイヤーからの学習
  - 6インデックス戦略、6つの Actor

- **[ARCHITECTURE_UPDATES.md](docs/ARCHITECTURE_UPDATES.md)**: v1.1 更新
  - fdb-document-layer 詳細調査
  - Metadata Version Management

- **[ARCHITECTURE_UPDATES_V1.2.md](docs/ARCHITECTURE_UPDATES_V1.2.md)**: v1.2 更新
  - fdb-record-layer 詳細調査
  - RangeSet, IndexingThrottle

- **[CRITICAL_ANALYSIS_SUMMARY.md](docs/CRITICAL_ANALYSIS_SUMMARY.md)**: 批判的分析
  - 評価プロセスと採用/不採用の判断

- **[IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md)**: v1.2用実装ガイド（参考）

### 🎓 設計の重要な教訓

1. **過剰設計の回避**: 6インデックス → 4インデックスで十分（97%のクエリをカバー）
2. **シンプルさ優先**: 6 Actors → 2 Actorsで保守性向上
3. **段階的実装**: MVP（2週）→ 最適化 → 高度な機能
4. **批判的思考**: 既存設計を鵜呑みにせず、RDFの本質から再考

### API リファレンス

```swift
public actor RDFStore {
    // 初期化
    public init(database: any DatabaseProtocol, rootPrefix: String) async throws

    // CRUD 操作
    public func insert(_ triple: RDFTriple) async throws
    public func delete(_ triple: RDFTriple) async throws
    public func query(subject: String?, predicate: String?, object: String?) async throws -> [RDFTriple]

    // バッチ操作（将来実装）
    public func insertBatch(_ triples: [RDFTriple]) async throws
}

public struct RDFTriple: Hashable, Codable, Sendable {
    public let subject: String
    public let predicate: String
    public let object: String
}
```

---

## 🧪 テスト

```bash
# すべてのテストを実行
swift test

# 特定のテストを実行
swift test --filter RDFStoreTests

# 詳細出力
swift test -v
```

### テストカバレッジ

- ✅ 単体テスト: 各コンポーネントの独立したテスト
- ✅ 統合テスト: RDFStore の end-to-end テスト
- ✅ 並行性テスト: 並行アクセスの安全性検証
- ⏭️ パフォーマンステスト: ベンチマーク（将来実装）

---

## 🎯 ロードマップ

### フェーズ 1: 基本実装（現在）
- ✅ アーキテクチャ設計完了
- ✅ 実装ガイド作成
- ⏭️ 基礎コンポーネント実装
  - RDFTriple, RDFError
  - SubspaceManager
  - DictionaryStore
  - IndexManager
  - RDFStore

### フェーズ 2: 最適化
- [ ] Dictionary キャッシング
- [ ] バッチ操作の最適化
- [ ] クエリプランナーのコスト見積もり
- [ ] 統計情報収集

### フェーズ 3: 高度な機能
- [ ] SPARQL パーサー
- [ ] 推論エンジン（RDFS/OWL）
- [ ] 名前付きグラフサポート
- [ ] 全文検索統合

### フェーズ 4: 運用機能
- [ ] メトリクス収集
- [ ] オンラインインデックス再構築
- [ ] バックアップ/リストア
- [ ] マイグレーションツール

---

## 🤝 貢献

貢献を歓迎します！以下の手順でお願いします：

1. このリポジトリをフォーク
2. フィーチャーブランチを作成 (`git checkout -b feature/amazing-feature`)
3. 変更をコミット (`git commit -m 'Add amazing feature'`)
4. ブランチにプッシュ (`git push origin feature/amazing-feature`)
5. Pull Request を作成

### 開発ガイドライン

- Swift 6 の並行性モデルを使用
- すべてのpublic APIにドキュメントコメントを追加
- 新機能には必ずテストを追加
- `swiftlint` でコードスタイルをチェック

---

## 📖 参考資料

### FoundationDB レイヤー
- [fdb-record-layer](https://github.com/FoundationDB/fdb-record-layer) - Java ベースのレコードストア
- [fdb-document-layer](https://github.com/FoundationDB/fdb-document-layer) - MongoDB 互換ドキュメントストア
- [fdb-swift-bindings](https://github.com/FoundationDB/fdb-swift-bindings) - Swift バインディング

### RDF/セマンティックウェブ
- [RDF Primer](https://www.w3.org/TR/rdf11-primer/) - W3C RDF 1.1 入門
- [SPARQL](https://www.w3.org/TR/sparql11-overview/) - クエリ言語仕様

### FoundationDB
- [FoundationDB Documentation](https://apple.github.io/foundationdb/) - 公式ドキュメント
- [Layer Design Guide](https://apple.github.io/foundationdb/layer-concept.html) - レイヤー設計ガイド

---

## 📄 ライセンス

Apache License 2.0 - 詳細は [LICENSE](LICENSE) を参照してください。

---

## ✨ 謝辞

このプロジェクトは以下の素晴らしいプロジェクトから多くを学びました：

- [FoundationDB](https://www.foundationdb.org) - 分散トランザクションデータベース
- [fdb-record-layer](https://github.com/FoundationDB/fdb-record-layer) - レイヤー設計のベストプラクティス
- [fdb-document-layer](https://github.com/FoundationDB/fdb-document-layer) - ステートレスアーキテクチャ
- [fdb-swift-bindings](https://github.com/FoundationDB/fdb-swift-bindings) - Swift 並行性モデル

---

## 📞 お問い合わせ

- **Issues**: [GitHub Issues](https://github.com/YOUR_USERNAME/fdb-rdf-layer/issues)
- **Discussions**: [GitHub Discussions](https://github.com/YOUR_USERNAME/fdb-rdf-layer/discussions)

---

**Built with ❤️ using Swift and FoundationDB**
