# zigprop Phase 0 design (v2)

Vendored from the author's research notes on 2026-11-19 so the repository is self-contained. This is the specification that src/, formal/ and docs/verification.md refer to.

# zigprop Phase 0 設計（v2）

作成: 2026-11-19 / 改訂: 2026-11-19（v2、Codex Sol レビューの Must-fix 12件を反映）
状態: 設計確定（D1〜D3 決定済み）。次は Phase 0 実装。
前提: 名前 zigprop、MIT、最新安定のみ（0.17.0+）、integrated shrinking、v0.1 型範囲と stateful / 保存形式の決定は `pbt-zig-de-facto-plan-2026-11-19.md` §4。

## 改訂履歴

- v1 (2026-11-19): 初版
- v2 (2026-11-19): Codex（gpt-6.1-sol）レビュー（`zigprop-phase0-design-review-codex-sol-2026-11-19.md`、判定 conditional-go）の Must-fix 12件を反映。対応表:

| # | 指摘 | 反映先 |
|---|---|---|
| MF1 | `bound == 0` 番兵が不変条件・剰余と矛盾 | §2（有効性と正規化を再定義）、§8 |
| MF2 | shortlex の比較対象が未定義 | §2・§6（再記録後の実消費列に統一） |
| MF3 | 枯渇ゼロ補完は完走を保証しない | §2・§4.2（生成器契約と draw 上限）、§6 |
| MF4 | 局所最小保証と予算打ち切りが両立しない | §6（パス定義・受理規則・`shrink_outcome`）、§8 |
| MF5 | discard / エラーの状態遷移が未規定 | §5（EvalOutcome）、§6 |
| MF6 | config とカスタム生成器の接続口がない | §3（GenContext）、§5（`checkCustom`） |
| MF7 | 整数生成がアルゴリズムとして未完成 | §4.1（全面仕様化、対象は 1〜64 bit） |
| MF8 | 対応型の境界条件が未決定 | §4（enum / sentinel / comptime field / 総要素数予算） |
| MF9 | allocator と Report の所有権が欠落 | §3（sticky error）、§5（2 allocator 制と `deinit`） |
| MF10 | property 制約と arena の記述が矛盾 | §5（利用規約と完全な test 例） |
| MF11 | regression の API と保存契約がない | §7（スキーマ・gen_version・再生規則） |
| MF12 | 検証ターゲットが到達不能・基準が定性的 | §9（mutant 固定・事前登録・成功条件の分離） |

Should-fix 9件は v2 では未反映（バックログとしてレビュー文書に保持）。ただし MF と重なる部分（§8 のメタテスト限定化など）は Must-fix 側で取り込んだ。

## 0. Phase 0 の目的と範囲

- 目的: コア設計（choice 表現・生成・shrinking）が正しいかを、事前登録した測定可能な基準（§9）で検証する。公開しない
- Phase 0 の成功 = 「コア設計の検証完了」であって、デファクト化の判定ではない。実プロジェクトへの適用は公開移行の別ゲート（計画メモ §5 の Phase 1/2）であり、Phase 0 の成功に含めない（MF12）
- 作るもの: プロトタイプ実装一式、メタテスト、mutant を使った検証ターゲット2件、手書き乱数ループとの比較記録
- 作らないもの: combinator 網羅、float / union / 再帰型、stateful、regressions の自動追記、`--fuzz` 連携（ただし表現は将来の連携を塞がないこと）

## 1. コアモデル

```text
seed ──► PRNG ──► choice 列を生成しながら値を組み立て ──► property 実行
                      │                                      │
                      │                                  失敗したら
                      ▼                                      ▼
              choice 列を記録 ◄────────────── choice 列を変形して再実行（shrinking）
```

生成器は「乱数源から直接値を引く」のではなく、**choice 列を消費して値を組み立てる関数**として定義する。shrinking は値ではなく choice 列を変形し、生成を再実行して失敗が再現するかで判定する（Hypothesis の Conjecture と同型の発想。値は制約を満たすものだけが再生成される）。

## 2. Choice 表現

- 1 choice = `{ bound: u64, value: u64 }`
- **有効性（MF1）**: `bound == 0 or value < bound`。`bound == 0` は番兵で「全 u64 域」を表し、その場合 value は任意の u64 が有効（2^64 が u64 に収まらないための措置）
- 生成プリミティブは基底1つ + 意味上の wrapper:
  - 基底: `range(bound) -> u64` — `bound > 0` なら `[0, bound)` の一様分布、`bound == 0` なら全 u64 域の一様分布
  - wrapper: `boolean()`（= `range(2)`）、`index(n)`（= `range(n)`、ただし `n == 0` は空集合なので `error.InvalidBound`。全域抽選として扱わない）、`length(max)`（包含上限。内部では `range(max + 1)`。max は Config の上限検証を通った値のみ）
- 全ての型の生成はこのプリミティブへの分解で書く。文字列・バイト列も Phase 0 では「長さ + 要素（u8）列」として扱い、専用の bytes プリミティブは置かない
- **記録するのは生の PRNG ワードではなく、正規化済みの意味的 choice（結果値）**。これにより shrink 候補は常に有効範囲内にあり、seed 再現とは独立に choice 列単体で再生できる
- **再生時の正規化（MF1）**: 要求 bound が 0 なら記録値をそのまま返す。そうでなければ `value % bound` を返す（shrink で列がずれて bound が変わっても常に有効。ただしこれは replay 専用の変換で、生成分布を保存しない。値の意味は bound によって変わる）
- **枯渇（MF3）**: 列を使い切ったら以降は 0 を返し「枯渇」フラグを立てる。組み込み生成器は型構造から draw 回数の上限が決まるため、枯渇しても最小値寄りの値で完走する。ただしこれは組み込み生成器だけの性質で、カスタム生成器には §4.2 の契約と上限で対処する
- 各試行では「実際に消費された choice 列」を新たに記録し直す。末尾の未消費分は自動的に落ちる
- **順序と比較（MF2）**: choice 列の順序は **value 列に対する shortlex**（まず長さ、次に辞書順）とする。bound は順序に含めない（診断用メタデータ）。shrinking の受理判定は §6 のとおり「再記録後の実消費列」に対して行う

### Smith との関係（将来の fuzz 連携）

Zig 0.17 の `std.testing.Smith` は整数 draw を 8 バイト LE ワードとして読み、範囲外なら範囲の最小値を返す仕様で、スカラー draw の組み合わせでは到達できない値が出ることが実地で報告されている。zigprop の Source は Smith を直接使わず独自に定義し、将来の連携では `smith.slice` でバイト列を取り込んで u64 列に変換する経路にする（Phase 0 では実装しない）。

## 3. Source と GenContext

```zig
pub const Choice = struct { bound: u64, value: u64 };

pub const Source = struct {
    mode: union(enum) {
        random: std.Random.DefaultPrng,
        replay: []const Choice,
    },
    pos: usize = 0,
    exhausted: bool = false,
    limit_exceeded: bool = false,       // draw 上限超過（MF3）
    sticky_error: ?anyerror = null,     // 記録の確保失敗など（MF9）
    recorded: std.ArrayList(Choice),    // その試行で消費された列
    draws: usize = 0,
    max_draws: usize,
    pub fn range(self: *Source, bound: u64) u64;
    pub fn boolean(self: *Source) bool;
};

/// 生成器へ渡る文脈（MF6）。自動生成・カスタム生成で共通。
pub const GenContext = struct {
    src: *Source,
    allocator: Allocator,   // 試行 arena（§5）
    limits: Limits,
};

pub const Limits = struct {
    max_len: usize = 32,              // slice 長の上限（length の包含上限）
    max_total_elements: usize = 4096, // 1ケースの総要素数（MF8）
    max_draws: usize = 100_000,       // 1ケースの draw 回数（MF3）
};
```

- random モード: `range` は偏りなし抽選（std.Random の範囲抽選と同じ棄却方式。bound==0 では生の u64 を引く）で結果値を決め、記録する
- replay モード: §2 の再生規則に従い、消費のたびに正規化後の値を記録し直す
- **記録の失敗（MF9）**: `range` の戻り値は u64 のままにし、記録用 ArrayList の確保失敗は `sticky_error` に残して 0 を返す。生成器と runner は試行の境界ごとに `sticky_error` を確認し、立っていれば infrastructure error として伝播する。記録を黙って欠落させることはしない
- **draw 上限（MF3）**: `draws` が `max_draws` を超えたら `limit_exceeded` を立て、以降の draw は 0 を返す。runner はその試行を discard として扱う
- Config の検証: `max_len` は `length` の内部加算（+1）が overflow しないこと、`max_total_elements` / `max_draws` が 0 でないことを `check` 開始時に検証し、不正なら `error.InvalidConfig` を返す
- PRNG は `std.Random.DefaultPrng` を使う。自前 PRNG は持たない

## 4. 型からの自動生成（comptime）

`generate(comptime T: type, ctx: *GenContext) !T`

| 型 | 分解 |
|---|---|
| bool | `boolean()` |
| 整数（1〜64 bit、符号あり/なし） | §4.1 |
| 整数（0 bit） | 唯一の値 0 を draw なしで生成 |
| 整数（65 bit 以上） | Phase 0 では対象外（v0.2 で複数 choice へ分解）。コンパイルエラーで案内 |
| enum | §4 の enum 規則 |
| optional | `boolean()` が真なら payload を生成 |
| 配列 `[N]T` | 要素を N 回（長さ draw なし）。N==0 は draw なし |
| slice `[]T` / `[]const u8` | `length(max_len)` + 要素列。確保は試行 arena |
| struct（タプル含む） | フィールドを宣言順に生成。comptime field は §4 の規則 |
| それ以外 | コンパイルエラー（型名を含め、カスタム生成関数の案内を出す） |

境界条件（MF8）:

- **enum**: draw は宣言順の index で、値は reflection 上のその field の実 tag 値に変換する（明示値付き enum でも壊れない）。non-exhaustive enum（`_` を持つ）は名前付き field のみを生成すると宣言する。空 enum は生成不能としてコンパイルエラー
- **sentinel 付き slice**（`[:0]u8` 等）: Phase 0 では対象外。コンパイルエラーで `[]T` の利用を案内する
- **comptime struct field**: 実行時生成の対象から外し、その field の既定値（comptime 値）を使う
- **空 struct**: draw なしで生成する
- **総要素数予算（MF8）**: slice / 配列の要素生成は `Limits.max_total_elements` で数え、超えたら `error.InvalidGeneration`（discard）。nested slice の乗算的膨張はこれで抑える。型構造自体は再帰型を対象外としているため深さは有限

### 4.1 整数の分布（D1 決定: サイズ偏向ミックス、MF7 で全面仕様化）

対象は bit 幅 W が 1〜64 の整数。生成は「ランク空間」で定義する:

- unsigned: ランク = 値そのもの（ランク域 R = 2^W、W=64 では番兵 bound==0）
- signed: zigzag 対応でランクを決める。ランク r に対して、r が偶数なら値 = r/2、奇数なら値 = -(r/2)-1（0→0, 1→-1, 2→1, 3→-2, …）。小さいランクが小さい絶対値に対応し、shrink の 0 方向が値の 0 に対応する

手順は2 draw:

1. クラス draw `range(4)`:
   - class 0（小域）: ランク = `range(min(R, 256))`
   - class 1（境界）: 境界集合 B(W) から index で選択。B(W) は値集合 {0, 1, -1, max, min, max-1, min+1} をその型で表現可能なものだけ残し、ランクへ変換して重複を除き、ランク昇順に整列したもの（unsigned では -1 / min-1 相当を除外、i1 のような狭い型では自然に縮む）
   - class 2（中域）: ランク = `range(min(R, 65536))`
   - class 3（全域）: ランク = `range(R)`（W=64 では番兵）
2. 値 draw はクラスごとに上記のとおり

不変: 全 draw が 0 の列からは class 0 / ランク 0、つまり値 0 が生成される（符号あり/なし共通）。
狭い型（W=1 等）では各クラスの域が重なってよい。クラス draw は常時消費し、消費列の形は型ごとに一定に保つ。

### 4.2 カスタム生成

`fn (ctx: *GenContext) !T` を満たす関数を差し込める（入口は §5 の `checkCustom`）。これが Phase 0 における filter / map の代替（手続き的に書く）。

契約（MF3）:

- 有限ステップで終了すること。強制手段として Source の `max_draws` と Limits の総要素数があり、超過した試行は discard になる
- 制約を満たせない場合は `error.InvalidGeneration` を返し、そのケースは discard として数える
- それ以外の error（OOM 等）は infrastructure error として runner が伝播する（§5）

## 5. Property と Runner

```zig
pub const Config = struct {
    seed: u64 = 0,
    max_cases: usize = 100,        // 有効ケース数
    max_discards: usize = 1000,
    shrink_budget: usize = 2000,   // shrink の述語評価回数の上限（§6）
    limits: Limits = .{},
    regressions: []const Regression = &.{},  // §7
    regression_id: ?[]const u8 = null,       // §7
};

pub fn check(allocator: Allocator, comptime T: type,
             property: *const fn (T) bool, config: Config) !Report;

pub fn checkCustom(allocator: Allocator, comptime T: type,
             generator: *const fn (ctx: *GenContext) !T,
             property: *const fn (T) bool, config: Config) !Report;
```

- property のシグネチャは Phase 0 では `fn (T) bool` のみ（D2）。入口名は `check`、カスタム生成版は `checkCustom`（D3、`forAll` は将来用に温存）

### 評価結果の分類（MF5）

各試行の結果は4分類し、状態遷移を固定する:

| 結果 | 条件 | runner の扱い |
|---|---|---|
| pass | 生成成功 かつ property が真 | 有効ケースとして数える |
| fail | 生成成功 かつ property が偽 | 反例候補。shrink の受理対象はこれだけ |
| discard | `error.InvalidGeneration`、または draw / 要素数上限の超過 | 現在の反例を置き換えない。ランダム探索では discard 予算を消費 |
| infrastructure error | OOM、`sticky_error`、それ以外の error | discard に混ぜず即座に伝播し、check は error を返す |

### メモリと所有権（MF9）

- allocator は2つに分ける。**試行 arena**（ケース毎・shrink 試行毎に作って破棄。生成値の一時置き場）と、**結果 allocator**（`check` に渡された allocator。採用した choice 列、Report の内容、反例の表示用スナップショットの保存用）
- 失敗が確認された時点で、その試行の実消費 choice 列と値の表示文字列を結果 allocator へコピーしてから arena を破棄する。Report が arena 内のデータを参照することはない
- `Report` は所有する allocator を保持し、`deinit()` で全て解放する

### ケースの独立性と seed

- ケースは試行（attempt）単位で単調増加する attempt index を持つ。attempt i の乱数流は、seed 導出関数 `deriveSeed(seed, i)` で初期化した PRNG から作る。導出は zigprop の仕様として固定する（splitmix64 の最終段ミックスを seed と i の wrapping 加算に適用する。具体的な演算は実装時に定数まで固定し、メタテストで固定値検証する）。std に同名の二引数関数がある前提にはしない
- discard が起きても attempt index は進む（同じケースの繰り返しにならない）

### property の利用規約（MF10）

- property は純粋な `fn (T) bool`。allocator は渡らない
- SUT が作業領域を必要とする場合、その確保は呼び出し側の責任とする（テスト内なら `std.testing.allocator` や呼び出し側の arena を、property の外で用意して使う）。「SUT の作業領域もケース arena が面倒を見る」という仕組みは Phase 0 には存在しない
- SUT が error を返す場合、その分類（反例か、想定内エラーか）は property の中で行い、bool に落とす。OOM と反例の区別も呼び出し側の責任

完全な使用例（test ブロック）:

```zig
test "varint round-trip" {
    const prop = struct {
        fn run(x: u32) bool {
            var buf: [5]u8 = undefined;
            const encoded = varint.encode(x, &buf);
            return varint.decode(encoded) == x;
        }
    };
    var report = try zigprop.check(std.testing.allocator, u32, prop.run, .{});
    defer report.deinit();
    try std.testing.expect(report == .passed);
}
```

### 結果型と test 統合

- `Report` は union: `passed { cases, discards, stale_regressions }` / `failed { seed, attempt_index, choices, shrunk_choices, original_value: []u8, shrunk_value: []u8, shrink_evaluations, shrink_outcome }` / `gave_up { cases, discards }`（いずれも結果 allocator 所有、`deinit` で解放）
- `checkOrError` は薄いラッパで、`failed` なら報告を印字して `error.PropertyFailed`、`gave_up` なら `error.GaveUp` を返す。検証できなかったケースが test の緑に化けることはない

## 6. Shrinking アルゴリズム

述語 P(C) = 「choice 列 C を再生した試行の結果が fail（§5 の分類）であること」。pass / discard / infrastructure error はいずれも P を満たさない（infrastructure error は shrink を中断して伝播する）。

**受理規則（MF2）**: 候補 C' を評価し、P(C') が真なら、C' の試行で**再記録された実消費列** R' を取る。R' が現在の最良列 R より shortlex（value 列の長さ→辞書順）で厳密に小さい場合だけ、R := R' として受理する。保存される状態そのものが毎回厳密に減少するので、循環は起きない。

**パス定義（MF4）**: 以下の1巡を「変更なし」になるまで繰り返す。各述語評価は `shrink_budget` を消費し、尽きたらその時点で打ち切る。

1. **P1 chunk 削除**: chunk サイズを「len 以下の最大の 2 の冪の半分」から始め、半分ずつ 1 まで下げる。各サイズでは開始位置を 0 から順に試す
2. **P2 0 化**: 各要素（既に 0 のものは除く）を 0 に置換して試す
3. **P3 減少**: 各要素について、差分を「現在値以下の最大の 2 の冪」から 1 まで下げながら引く試行を繰り返す

**保証の範囲（MF4）**: 全パスが変更なしで1巡完了した場合に限り、その結果を「P1〜P3 の候補近傍（連続 chunk の削除、単一要素の 0 化、単一要素からの 2 の冪差分の減算）に対する局所最小」と呼ぶ。任意の小さい値への置換に対する最小性は主張しない。予算打ち切りの場合は局所最小を主張しない。
Report の `shrink_outcome` は `fixed_point` か `budget_exhausted` のどちらかを必ず持つ。

**終了性**: 受理のたびに保存列が shortlex で厳密減少し、列長と値には下限（長さ 0、全て 0）があるため、受理回数は有限。評価回数自体も予算で上限がある。ただし各 property 評価そのものの終了は呼び出し側の責任であり、runner は制御できない（この範囲に終了保証を限定する）。

**実装注記（2026-11-19、Sol のマイルストーン3レビューを受けて追記）**:

- P1 の chunk サイズは、len が 1 のとき 1 とする（「最大の 2 の冪の半分」は 0 になるため、単一要素の削除を試す側に倒す）。
- shrink の候補が候補列を使い切る場合（再生枯渇）、その試行は 0 埋めで評価し、再記録された実消費列（埋め分を含む）を受理判定の対象とする。runner の regressions 再生で枯渇した場合は §7 のとおり discard（stale）として扱い、両者は区別する。
- 予算の単位は「試行全体の評価（生成＋property）1回」であり、property 呼び出し回数そのものではない。生成段階で discard になった試行も 1 回として数える。

## 7. 失敗の報告と regressions

- 失敗時は次を印字する: seed、attempt index、元の値、shrink 後の値、shrink 評価回数と outcome、choice 列
- 値の表示文字列は失敗確認時に結果 allocator でスナップショットする（表示のために property を再実行しない）

### regressions の保存契約（MF11）

保存するのは **正規化済みの実消費 value 列**（bound は保存しない。再実行時に生成器が再導出する）。

ファイル `tests/regressions.zon` のスキーマ（version 1）:

```zig
.{
    .version = 1,
    .entries = .{
        .{ .id = "varint round-trip", .gen_version = 1, .choices = .{ 3, 0, 268435456 } },
    },
}
```

- `id`: テストの識別子。`Config.regression_id` と一致するエントリだけが対象
- `gen_version`: 生成器の互換性識別子。ライブラリが定数 `generator_version` を持ち、生成の意味が変わる変更では必ず上げる。エントリの `gen_version` が現在の値と異なるエントリは、警告を印字して読み飛ばす（stale）
- 読み込みは Phase 0 では `@import("regressions.zon")` による comptime 取り込みとし、runtime の ZON パースには依存しない。呼び出し側が `Config.regressions` にエントリ列を渡す
- 再生規則: ランダムケースの前に regressions を流す。結果が fail なら即座に全体を `failed` として shrink に入る。pass ならランダムケース数には算入しない（追加のケースとして数だけ記録）。discard になったエントリは stale として数え、警告する。infrastructure error は伝播する
- Phase 0 ではファイルへの自動追記はせず、印字された断片を手で貼る運用

## 8. ライブラリ自身のメタテスト

- 決定性: 同じ seed の2回実行でケース列・結果が完全一致。`deriveSeed` の固定値検証を含む
- 範囲妥当性: bound = 1, 2, 3 と番兵（bound == 0）を含む全プリミティブで、有効性 `bound == 0 or value < bound` が常に成り立つ（MF1）
- 再生忠実度: 記録した列を replay すると同じ値が再生成される
- shrink 保存性（専用 encoding に限定、MF4）: 単一の `range(2^32)` draw で u32 を作るカスタム生成器を使い、性質 `x < 10` の反証で shrink 結果がちょうど 10 になる。組み込み整数生成に対する主張は「失敗が保存され、結果が元の値以下で、性質を満たさないこと」までに留める
- shrink 終了性: 予算内で必ず止まり、`shrink_outcome` が正しく付く
- discard 上限: 常に InvalidGeneration を返す生成器で `gave_up` になる
- 所有権: Report の内容が試行 arena 破棄後も有効で、`deinit` 後にリーク検出（`std.testing.allocator`）に引っかからない（MF9）

## 9. 検証ターゲット（mutant 方式、事前登録）

測定の再現性のため、mutant と期待値を事前に固定する（MF12）。結果は seed 0〜9 の10 seed で集計する。

- **T1 varint**: LEB128 符号化/復号の round-trip。mutant は復号器が 4 バイト（28 bit）で打ち切り、継続バイトを無視する版。期待する最小反例はちょうど **2^28 = 268435456**。成功条件: 10 seed 中 8 seed 以上で、`max_cases = 200` 以内に失敗を発見し、shrink 後の反例が 268435456 に一致すること
- **T2 RLE**: run-length 符号化/復号の round-trip。入力は独立 u8 列ではなく、(値, run 長) の列を作るカスタム生成器で生成し、run 長は 200〜300 を含む分布にする。mutant は run 長を u8 に切り捨てる版。期待する最小反例は **単一 run・長さ 256**。成功条件は T1 と同じ集計方法で、shrink 後の入力が単一 run かつ長さ 256 であること
- 比較対象: 同じ seed 予算の手書き乱数ループ。測定項目 = 失敗までのケース数、反例の大きさ、shrink 評価回数。発見性能の比較と shrink の効果（有無）は分けて記録する
- 正しい実装（mutant でない版）では同じ条件で失敗が見つからないことも対照として確認する

## 10. ファイル構成（プロトタイプ）

```text
src/root.zig      — 公開 API の再輸出
src/source.zig    — Choice / Source / GenContext / Limits
src/gen.zig       — comptime 型生成
src/shrink.zig    — shrink パス
src/runner.zig    — check / checkCustom / Report / 報告印字
tests/meta.zig    — §8
tests/mutants.zig — §9
tests/regressions.zon — §7（空のスキーマで開始）
examples/         — round-trip の使用例 1〜2 件
```

## 11. スケジュール目安（2週間）

- 0日目: §9 の検証基準の事前登録（この文書がその記録）
- 1〜3日目: Source + プリミティブ + メタテスト（範囲・決定性）
- 4〜6日目: gen（v0.1 型範囲）+ runner
- 7〜9日目: shrink パス + shrink メタテスト
- 10〜12日目: mutant 検証と比較記録
- 13〜14日目: 判定（§9 の成功条件を満たしたか）と計画メモへの反映

## 12. 決定済み（2026-11-19、ユーザーが推奨どおりで確定）

- D1: 整数分布 — **サイズ偏向ミックス**（§4.1 で全面仕様化）
- D2: property シグネチャ — Phase 0 は **`fn (T) bool` のみ**
- D3: 入口名 — **`check`**（カスタム生成版は `checkCustom`、`forAll` は温存）

v2 で Phase 0 の設計上の未決は解消。次は実装。
