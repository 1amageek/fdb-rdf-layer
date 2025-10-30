# fdb-swift-bindings Usage Guide

このドキュメントは `fdb-swift-bindings` ライブラリの使い方を詳細に説明します。RDF Layer の実装において重要な役割を果たします。

---

## 目次

1. [初期化とセットアップ](#初期化とセットアップ)
2. [コアプロトコルと型](#コアプロトコルと型)
3. [トランザクションパターン](#トランザクションパターン)
4. [CRUD操作](#crud操作)
5. [レンジクエリとストリーミング](#レンジクエリとストリーミング)
6. [Tupleエンコーディング](#tupleエンコーディング)
7. [アトミック操作](#アトミック操作)
8. [エラーハンドリング](#エラーハンドリング)
9. [ベストプラクティス](#ベストプラクティス)

---

## 初期化とセットアップ

### FDBクライアントの初期化

FoundationDB を使用する前に、クライアントを初期化し、データベース接続を開く必要があります。

```swift
import FoundationDB

// FoundationDB クライアントの初期化（非同期）
try await FDBClient.initialize()

// データベース接続を開く（同期）
let database = try FDBClient.openDatabase()
```

**重要なポイント:**
- `FDBClient.initialize()` は非同期メソッドで、`await` で呼び出す必要があります
- デフォルトの API バージョンは 710 です
- `openDatabase()` はオプションで `clusterFilePath` を指定できます
- 初期化は通常、アプリケーション起動時に一度だけ行います

### クラスターファイルの指定（オプション）

```swift
let database = try FDBClient.openDatabase(clusterFilePath: "/etc/foundationdb/fdb.cluster")
```

---

## コアプロトコルと型

### FDB 名前空間

`FDB` enum は基本的な型の名前空間として機能します:

```swift
// 基本型
FDB.Version      // Int64 - バージョン番号
FDB.Bytes        // [UInt8] - 生のバイトデータ
```

### DatabaseProtocol

データベース接続のインターフェースを定義します。`FDBDatabase` クラスがこのプロトコルに準拠しています。

**主要メソッド:**
- `createTransaction()`: 新しいトランザクションを作成
- `withTransaction(_:)`: 自動リトライロジック付きトランザクション実行

### TransactionProtocol

トランザクション内で実行できるすべての操作を定義します。`FDBTransaction` クラスが実装しています。

**主要メソッド:**
- `getValue(for:snapshot:)`: キーの値を取得
- `setValue(_:for:)`: キーに値を設定
- `clear(key:)`: キーを削除
- `clearRange(beginKey:endKey:)`: キー範囲を削除
- `getRangeNative()`: 全結果を一括取得
- `getRange()`: ストリーミングで範囲取得
- `atomicOp()`: アトミック操作
- `commit()`: トランザクションをコミット
- `cancel()`: トランザクションをキャンセル
- `onError(_:)`: エラーハンドリング

---

## トランザクションパターン

### パターン1: withTransaction（推奨）

自動リトライロジック付きで最も推奨されるパターンです:

```swift
try await database.withTransaction { transaction in
    // 値の設定
    transaction.setValue("world", for: "hello")

    // 値の取得
    if let value = try await transaction.getValue(for: "hello") {
        print(String(decoding: value, as: UTF8.self))
    }

    // 戻り値（オプション）
    return "operation_completed"
}
```

**特徴:**
- リトライ可能なエラーを自動的に処理（最大100回まで）
- トランザクションの作成、コミット、キャンセルを自動管理
- 例外が発生した場合、トランザクションは自動的にキャンセルされる

### パターン2: 手動トランザクション管理

より細かい制御が必要な場合:

```swift
let transaction = try database.createTransaction()

// 操作を実行
transaction.setValue("test_value", for: "test_key")

// コミット
let success = try await transaction.commit()
if success {
    print("Transaction committed successfully")
}
```

**注意:**
- エラーハンドリングとリトライロジックは手動で実装する必要があります
- `transaction.onError(_:)` を使用してリトライ判定を行います

---

## CRUD操作

### Create / Update (setValue)

キーに値を設定します。存在しない場合は作成、存在する場合は更新します:

```swift
// String を直接使用（内部で FDB.Bytes に変換）
transaction.setValue("world", for: "hello")

// FDB.Bytes を使用
let key: FDB.Bytes = [UInt8]("myKey".utf8)
let value: FDB.Bytes = [UInt8]("myValue".utf8)
transaction.setValue(value, for: key)
```

**特徴:**
- 同期メソッド（ローカルバッファに保存）
- 実際の書き込みはコミット時に発生

### Read (getValue)

キーの値を取得します:

```swift
// 非同期で値を取得
if let value = try await transaction.getValue(for: "hello") {
    let stringValue = String(decoding: value, as: UTF8.self)
    print(stringValue)
} else {
    print("Key not found")
}

// スナップショットリード（競合を発生させない）
let value = try await transaction.getValue(for: "hello", snapshot: true)
```

**特徴:**
- 非同期メソッド（`await` が必要）
- キーが存在しない場合は `nil` を返す
- `snapshot: true` で競合を回避できる

### Delete (clear)

単一のキーまたは範囲を削除します:

```swift
// 単一キーの削除
transaction.clear(key: "hello")

// キー範囲の削除
let beginKey: FDB.Bytes = [UInt8]("user:000".utf8)
let endKey: FDB.Bytes = [UInt8]("user:999".utf8)
transaction.clearRange(beginKey: beginKey, endKey: endKey)
```

**特徴:**
- 同期メソッド（ローカルバッファに保存）
- 範囲削除は `[beginKey, endKey)` の半開区間

---

## レンジクエリとストリーミング

### KeySelector の使用

`FDB.KeySelector` は参照キーからの相対位置を指定します:

```swift
// 最初の ">=" キー
let begin = FDB.KeySelector.firstGreaterOrEqual([UInt8]("user:".utf8))

// 最初の ">" キー
let end = FDB.KeySelector.firstGreaterThan([UInt8]("user;".utf8))

// 最後の "<=" キー
let last = FDB.KeySelector.lastLessOrEqual([UInt8]("user:999".utf8))

// 最後の "<" キー
let lastBefore = FDB.KeySelector.lastLessThan([UInt8]("user:000".utf8))
```

### getRangeNative: 小規模データセット用

全結果を一括で取得します（1000件未満の結果に最適）:

```swift
let beginKey: FDB.Bytes = [UInt8]("user:000".utf8)
let endKey: FDB.Bytes = [UInt8]("user:999".utf8)

let result = try await transaction.getRangeNative(
    beginKey: beginKey,
    endKey: endKey,
    limit: 0,      // 0 = 制限なし
    snapshot: false
)

// 結果の処理
for (key, value) in result.records {
    let keyStr = String(decoding: key, as: UTF8.self)
    let valueStr = String(decoding: value, as: UTF8.self)
    print("\(keyStr): \(valueStr)")
}

// より多くの結果があるかチェック
if result.more {
    print("More results available")
}
```

### getRange: 大規模データセット用（推奨）

`AsyncSequence` を使用したストリーミング処理:

```swift
let sequence = transaction.getRange(
    beginSelector: .firstGreaterOrEqual([UInt8]("user:".utf8)),
    endSelector: .firstGreaterOrEqual([UInt8]("user;".utf8))
)

// for-await-in でストリーミング処理
for try await (key, value) in sequence {
    let userId = String(decoding: key, as: UTF8.self)
    let userData = String(decoding: value, as: UTF8.self)
    // 各キー・バリューペアを処理
}
```

**特徴:**
- バックグラウンドプリフェッチによる最適化
- メモリ効率が高い（バッチ単位で処理）
- 大規模データセットに最適

### レンジクエリのパフォーマンス最適化

```swift
// バッチサイズを指定
let sequence = transaction.getRange(
    beginSelector: .firstGreaterOrEqual(beginKey),
    endSelector: .firstGreaterThan(endKey),
    limit: 10000,        // 最大取得件数
    batchLimit: 1000,    // バッチあたりの件数
    snapshot: true,      // スナップショットリード
    reverse: false       // 逆順（false = 昇順）
)
```

---

## Tupleエンコーディング

`FDB.Tuple` は構造化されたキーをバイト配列にエンコードし、辞書順を保持します。

### サポートされる型

| 型 | TypeCode | 説明 |
|----|----------|------|
| `String` | `0x02` | UTF-8 文字列 |
| `FDB.Bytes` | `0x01` | 生バイト配列 |
| `Int`, `Int32`, `Int64` | 可変 | 可変長整数 |
| `UInt64` | 可変 | 符号なし整数 |
| `Bool` | `0x26/0x27` | true/false |
| `Float` | `0x20` | 32ビット浮動小数点 |
| `Double` | `0x21` | 64ビット浮動小数点 |
| `UUID` | `0x30` | 128ビット UUID |
| `Tuple` | `0x05` | ネストされた Tuple |
| `TupleNil` | `0x00` | null 値 |

### 基本的なエンコード

```swift
// Tuple の作成とエンコード
let tuple = Tuple("user", 12345, true)
let keyBytes: FDB.Bytes = tuple.encode()

// データベースで使用
transaction.setValue("userData", for: keyBytes)
```

### デコード

```swift
let keyBytes: FDB.Bytes = // ... データベースから取得
let elements = try Tuple.decode(from: keyBytes)

// 型キャスト
let username = elements[0] as? String
let userId = elements[1] as? Int64
let isActive = elements[2] as? Bool
```

### ネストされた Tuple

```swift
// ネストされた構造
let metadata = Tuple("role", "admin")
let userKey = Tuple("user", 12345, metadata)
let encoded = userKey.encode()

// デコード
let decoded = try Tuple.decode(from: encoded)
let nestedTuple = decoded[2] as? Tuple
```

### RDF Layer での実装例

```swift
// RDF トリプル用のキー構造
struct RDFKey {
    // SPO インデックス: (subject_id, predicate_id, object_id)
    static func encodeSPO(subject: Int64, predicate: Int64, object: Int64) -> FDB.Bytes {
        return Tuple(subject, predicate, object).encode()
    }

    // Dictionary エントリ: (uri)
    static func encodeDictionary(uri: String) -> FDB.Bytes {
        return Tuple(uri).encode()
    }

    // Metadata キー: (version_counter)
    static func encodeMetadata(key: String) -> FDB.Bytes {
        return Tuple("metadata", key).encode()
    }
}
```

### 辞書順の保証

Tuple エンコーディングは辞書順を保持するため、範囲クエリが正しく動作します:

```swift
// "user:000" から "user:999" までの全ユーザーを取得
let beginKey = Tuple("user", 0).encode()
let endKey = Tuple("user", 1000).encode()

for try await (key, value) in transaction.getRange(
    beginSelector: .firstGreaterOrEqual(beginKey),
    endSelector: .firstGreaterThan(endKey)
) {
    // 処理
}
```

---

## アトミック操作

アトミック操作はロックフリーで並行修正を可能にします。

### 利用可能な操作

```swift
public enum FDB.MutationType {
    // 算術演算
    case add              // リトルエンディアン加算

    // ビット演算
    case bitAnd           // ビット AND
    case bitOr            // ビット OR
    case bitXor           // ビット XOR

    // 比較演算
    case max              // 最大値（リトルエンディアン）
    case min              // 最小値（リトルエンディアン）
    case byteMax          // 最大値（辞書順）
    case byteMin          // 最小値（辞書順）

    // 文字列操作
    case appendIfFits     // 追記（サイズ制限内）

    // バージョンスタンプ
    case setVersionstampedKey    // キーにバージョンスタンプ
    case setVersionstampedValue  // 値にバージョンスタンプ

    // 条件操作
    case compareAndClear  // 値が一致すれば削除
}
```

### Add: カウンター実装

```swift
// カウンターの初期化
let counterKey: FDB.Bytes = [UInt8]("counter".utf8)
transaction.setValue(withUnsafeBytes(of: Int64(0).littleEndian) { Array($0) },
                     for: counterKey)

// カウンターのインクリメント（+1）
let increment: FDB.Bytes = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
transaction.atomicOp(key: counterKey, param: increment, mutationType: .add)

// カウンターのインクリメント（+5）
let addValue: FDB.Bytes = withUnsafeBytes(of: Int64(5).littleEndian) { Array($0) }
transaction.atomicOp(key: counterKey, param: addValue, mutationType: .add)
```

### Max: 最大値の追跡

```swift
let key: FDB.Bytes = [UInt8]("max_value".utf8)
let maxValue: FDB.Bytes = withUnsafeBytes(of: Int64(100).littleEndian) { Array($0) }

// 既存値と 100 を比較し、大きい方を保存
transaction.atomicOp(key: key, param: maxValue, mutationType: .max)
```

### Min: 最小値の追跡

```swift
let key: FDB.Bytes = [UInt8]("min_value".utf8)
let minValue: FDB.Bytes = withUnsafeBytes(of: Int64(5).littleEndian) { Array($0) }

// 既存値と 5 を比較し、小さい方を保存
transaction.atomicOp(key: key, param: minValue, mutationType: .min)
```

### Metadata Version Counter の実装例

```swift
actor MetadataManager {
    private let db: any DatabaseProtocol
    private let versionKey: FDB.Bytes

    // バージョンカウンターのアトミックインクリメント
    func incrementVersion() async throws {
        try await db.withTransaction { transaction in
            let increment = withUnsafeBytes(of: UInt64(1).littleEndian) { Array($0) }
            transaction.atomicOp(
                key: versionKey,
                param: increment,
                mutationType: .add
            )
        }
    }

    // 現在のバージョンを取得
    func getCurrentVersion() async throws -> UInt64 {
        return try await db.withTransaction { transaction in
            guard let bytes = try await transaction.getValue(for: versionKey) else {
                return 0
            }
            return bytes.withUnsafeBytes { $0.load(as: UInt64.self).littleEndian }
        }
    }
}
```

### 重要な注意点

1. **エンディアン**: すべての整数ベースのアトミック操作はリトルエンディアンを使用
2. **読み取り競合なし**: アトミック操作は読み取り競合範囲を作成しません
3. **冪等性なし**: アトミック操作は冪等ではありません。リトライ時に再適用されます
4. **Read-Your-Writes**: 同じトランザクション内でアトミック操作後に読み取り可能
5. **値サイズ制限**: `appendIfFits` は最大値サイズ（通常100KB）を超えると失敗

---

## エラーハンドリング

### FDBError

すべての FoundationDB エラーは `FDBError` 型で表されます:

```swift
do {
    try await database.withTransaction { transaction in
        // 操作
    }
} catch let error as FDBError {
    if error.isRetryable {
        print("Retryable error: \(error)")
        // withTransaction が自動的にリトライ
    } else {
        print("Non-retryable error: \(error)")
        // アプリケーションレベルで処理が必要
    }
} catch {
    print("Other error: \(error)")
}
```

### 手動リトライロジック

```swift
func manualRetry() async throws {
    var retries = 0
    let maxRetries = 100

    while retries < maxRetries {
        let transaction = try database.createTransaction()

        do {
            // 操作を実行
            transaction.setValue("value", for: "key")
            try await transaction.commit()
            return // 成功

        } catch let error as FDBError {
            retries += 1

            // onError でリトライ可能かチェック
            try await transaction.onError(error)
            // onError が成功したらリトライ可能
            continue

        } catch {
            // 非 FDB エラーは即座に throw
            throw error
        }
    }

    throw FDBError(message: "Max retries exceeded")
}
```

### 一般的なエラー

| エラー | 説明 | 対処法 |
|--------|------|--------|
| `transaction_too_old` | トランザクションが5秒を超えた | リトライ可能 - withTransaction が自動処理 |
| `not_committed` | 競合によりコミット失敗 | リトライ可能 - withTransaction が自動処理 |
| `transaction_too_large` | トランザクションサイズが10MBを超えた | バッチサイズを削減 |
| `key_too_large` | キーが10KBを超えた | キー構造を見直す |
| `value_too_large` | 値が100KBを超えた | 値を分割または圧縮 |

---

## ベストプラクティス

### 1. withTransaction を優先

```swift
// ✅ 推奨: 自動リトライとエラーハンドリング
try await database.withTransaction { transaction in
    // 操作
}

// ❌ 非推奨: 手動管理は複雑でエラーが起きやすい
let transaction = try database.createTransaction()
// ... 手動コミットとエラーハンドリング
```

### 2. トランザクションは短く保つ

```swift
// ✅ 推奨: トランザクションは5秒以内
try await database.withTransaction { transaction in
    let value = try await transaction.getValue(for: key)
    transaction.setValue(newValue, for: key)
}

// ❌ 非推奨: 長時間の処理はトランザクション外で
let data = try await database.withTransaction { transaction in
    return try await transaction.getValue(for: key)
}
// 重い処理をここで実行
let processedData = heavyProcessing(data)
try await database.withTransaction { transaction in
    transaction.setValue(processedData, for: key)
}
```

### 3. 大規模データセットはストリーミング

```swift
// ✅ 推奨: AsyncSequence でメモリ効率よく
for try await (key, value) in transaction.getRange(...) {
    // バッチ単位で処理
}

// ❌ 非推奨: 大量データを一度に取得
let result = try await transaction.getRangeNative(...) // メモリ不足の可能性
```

### 4. Tuple を使用した構造化キー

```swift
// ✅ 推奨: Tuple で型安全かつ辞書順保証
let key = Tuple("user", userId, "profile").encode()

// ❌ 非推奨: 手動文字列結合は脆弱
let key = "user:\(userId):profile".utf8
```

### 5. スナップショットリードの活用

```swift
// 読み取り専用クエリは snapshot: true を使用
let value = try await transaction.getValue(for: key, snapshot: true)

// 範囲クエリも同様
let sequence = transaction.getRange(
    beginSelector: begin,
    endSelector: end,
    snapshot: true  // 競合を回避
)
```

### 6. アトミック操作でロックフリー

```swift
// ✅ 推奨: アトミック操作で並行安全
transaction.atomicOp(key: counterKey, param: increment, mutationType: .add)

// ❌ 非推奨: Read-Modify-Write は競合が発生しやすい
let current = try await transaction.getValue(for: counterKey)
let newValue = current + 1
transaction.setValue(newValue, for: counterKey)
```

### 7. エラーハンドリングを常に実装

```swift
// ✅ 推奨: エラーを適切にキャッチ
do {
    try await database.withTransaction { transaction in
        // 操作
    }
} catch let error as FDBError {
    // FDB エラーの処理
} catch {
    // その他のエラー
}
```

### 8. バッチ処理での制限を意識

```swift
// トランザクションサイズ制限: 10MB
// キーサイズ制限: 10KB
// 値サイズ制限: 100KB
// トランザクション時間制限: 5秒

// ✅ 推奨: バッチを適切なサイズに分割
let batchSize = 1000
for batch in triples.chunked(into: batchSize) {
    try await database.withTransaction { transaction in
        for triple in batch {
            // 処理
        }
    }
}
```

### 9. Actor を活用した並行安全性

```swift
// ✅ 推奨: Actor で状態を保護
actor RDFStore {
    private let database: any DatabaseProtocol

    func insert(_ triple: RDFTriple) async throws {
        try await database.withTransaction { transaction in
            // トランザクション内の操作
        }
    }
}
```

### 10. テストでの FDB のモック

```swift
// DatabaseProtocol と TransactionProtocol はプロトコルなので、
// テスト用のモック実装が可能

protocol DatabaseProtocol {
    func withTransaction<T>(_ body: (any TransactionProtocol) async throws -> T) async throws -> T
}

// テスト用モック
class MockDatabase: DatabaseProtocol {
    var mockData: [FDB.Bytes: FDB.Bytes] = [:]

    func withTransaction<T>(_ body: (any TransactionProtocol) async throws -> T) async throws -> T {
        let transaction = MockTransaction(data: mockData)
        return try await body(transaction)
    }
}
```

---

## RDF Layer での実装例

### SubspaceManager の実装

```swift
actor SubspaceManager {
    private let rootPrefix: FDB.Bytes

    init(rootPrefix: String) {
        self.rootPrefix = Tuple(rootPrefix).encode()
    }

    // サブスペースキーの生成
    func createKey(subspace: String, components: TupleElement...) -> FDB.Bytes {
        var tuple = Tuple(subspace)
        for component in components {
            tuple = tuple.appending(component)
        }
        return rootPrefix + tuple.encode()
    }

    // 例: SPO インデックスキー
    func spoKey(subject: Int64, predicate: Int64, object: Int64) -> FDB.Bytes {
        return createKey(subspace: "spo", components: subject, predicate, object)
    }
}
```

### DictionaryStore の実装

```swift
actor DictionaryStore {
    private let database: any DatabaseProtocol
    private let subspaceManager: SubspaceManager

    // URI → ID 変換（存在しなければ作成）
    func getOrCreateID(for uri: String) async throws -> Int64 {
        return try await database.withTransaction { transaction in
            let uriKey = subspaceManager.createKey(subspace: "uri2id", components: uri)

            // 既存IDをチェック
            if let idBytes = try await transaction.getValue(for: uriKey) {
                return idBytes.withUnsafeBytes { $0.load(as: Int64.self).littleEndian }
            }

            // 新しいIDを生成（アトミックカウンター）
            let counterKey = subspaceManager.createKey(subspace: "id_counter")
            let increment = withUnsafeBytes(of: Int64(1).littleEndian) { Array($0) }
            transaction.atomicOp(key: counterKey, param: increment, mutationType: .add)

            let newIDBytes = try await transaction.getValue(for: counterKey)!
            let newID = newIDBytes.withUnsafeBytes { $0.load(as: Int64.self).littleEndian }

            // マッピングを保存
            transaction.setValue(newIDBytes, for: uriKey)

            let idKey = subspaceManager.createKey(subspace: "id2uri", components: newID)
            transaction.setValue([UInt8](uri.utf8), for: idKey)

            return newID
        }
    }
}
```

### IndexManager での範囲クエリ

```swift
actor IndexManager {
    private let database: any DatabaseProtocol
    private let subspaceManager: SubspaceManager

    // SPO インデックスを使ったクエリ
    func queryBySPO(
        subject: Int64?,
        predicate: Int64?,
        object: Int64?
    ) async throws -> [RDFTriple] {
        return try await database.withTransaction { transaction in
            var results: [RDFTriple] = []

            let (beginKey, endKey) = buildRangeKeys(s: subject, p: predicate, o: object)

            let sequence = transaction.getRange(
                beginSelector: .firstGreaterOrEqual(beginKey),
                endSelector: .firstGreaterThan(endKey),
                snapshot: true
            )

            for try await (key, _) in sequence {
                // Tuple デコードで ID を取得
                let keyWithoutPrefix = key.dropFirst(rootPrefix.count)
                let elements = try Tuple.decode(from: Array(keyWithoutPrefix))

                let s = elements[0] as! Int64
                let p = elements[1] as! Int64
                let o = elements[2] as! Int64

                // ID → URI 変換
                let triple = try await convertToTriple(s: s, p: p, o: o)
                results.append(triple)
            }

            return results
        }
    }
}
```

---

## まとめ

`fdb-swift-bindings` の重要なポイント:

1. **初期化**: `FDBClient.initialize()` → `openDatabase()`
2. **トランザクション**: `withTransaction` を優先使用
3. **CRUD**: `getValue` (async), `setValue` (sync), `clear` (sync)
4. **範囲クエリ**: 小規模データは `getRangeNative`, 大規模は `getRange` + `AsyncSequence`
5. **Tuple**: 構造化キーのエンコード・デコードに必須
6. **アトミック操作**: カウンター、最大値/最小値の追跡に使用
7. **エラー**: `FDBError` の `isRetryable` でリトライ判定
8. **制限**: トランザクション 10MB, キー 10KB, 値 100KB, 時間 5秒

このライブラリの理解が RDF Layer の実装の基礎となります。
