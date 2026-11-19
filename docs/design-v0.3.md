# zigprop v0.3 設計（ドラフト v1、2026-11-19）

状態: **ドラフト v1（独立レビュー待ち）**。ユーザー確認前であり、ここに書く決定はすべて提案である。
拡張元: Phase 0 設計 `zigprop/docs/design-v2.md`（v2.1 改訂込み）と v0.2 設計 `zigprop/docs/design-v0.2.md`（v2）。両文書の節番号を「v2 §n」「v0.2 §n」で参照する。
基準バージョン: **v0.2.1**（リリース済み、`generator_version = 1`）。
入力: v0.2.0 レビュー `research_notes/zigprop-v0.2-full-review-claude-opus-2026-11-19.md`（以下「レビュー」）の §3 I2・I4〜I8、§5、§7。

改訂履歴:
- v1 (2026-11-19): 初版。

### この文書の検証状況（最初に読むこと）

- **私はこのセッションで `zig` も `git` も実行できなかった。** `zig version` を含むすべての zig 呼び出しと `git status` が「This command requires approval」で拒否され、非対話セッションでは承認できない（レビュー著者と同じ状況）。したがって:
  - 現状の挙動に関する記述は、**v0.2.1 のソースを読んで確認したもの**（`file:line` 付き）と、**コードからの算術・推論**のどちらかである。「実行で確認」は一つもない。
  - ベースライン（`zig build test --summary all` と `zig build validation`）は記録できなかった。テスト数は静的に数えた: `^test ` 宣言が 89 個（src/source.zig 7、src/root.zig 1（無名）、tests/meta.zig 9、meta2 18、meta3 14、meta4 3、meta5 12、meta6 7、meta7 8、meta8 7、examples 3）。README の「89 tests」（README.md:52）と一致するが、パスするかは未確認。**M0 の最初の作業はこのベースラインの記録である**（§9）。
  - 新しい comptime / reflection 機能に依存する設計は、Zig 0.17.1 で動くかを確認できていない。各所で「未確認」と明記し、M0 の実験項目にした。
- 作業ツリーの状態は `git status` を実行できないため確認できていない。私はリポジトリ内のファイルを一切書いていない（書いたのはこの文書だけ）。

---

## 0. 範囲と互換性

### 0.1 v0.3 の目的

v0.3 は**型の範囲を広げるリリースではない**。v0.2.0 レビューで残った指摘（I2, I4〜I8）を片付け、**公開 API と regression の契約を確定させる**リリースである。「デファクト標準」を目指すなら、利用者が少ない今のうちに API を壊して決めておく方が、後で壊すより安い。stateful testing は対象になり得る最初の版だが、取り込まない（§6）。

### 0.2 IN / OUT 一覧

| 項目 | 判定 | 要旨 | 節 |
|---|---|---|---|
| 1. I2 切断の範囲 | **IN** | 切断地点の型 R に到達できるチャネルだけを止め、それ以外は通常生成する。切断地点の union は許容バリアントの中から tag を draw する | §1 |
| 2. I4 分布 | **IN** | 整数の class 2 を対数一様に置き換える（組の形は不変）。float に中程度の大きさの class 4 を追加する。正規形は class 3 のまま | §2 |
| 3. I5 shrinker | **IN** | span 注釈の記録。P5 要素削除（長さ draw とセット）、P6 部分木昇格、P1 のサイズ 3/5/6/7 を「高価なパス」として追加 | §3 |
| 4. I6 regression の頑健性 | **IN** | 構造ハッシュと関連 Limits で fingerprint を作る。未消費の suffix を stale とする。stale は Report で報告し、OrError ラッパーでは任意で error にする | §4 |
| 5. I7/I8 API とワークフロー | **IN**（実行時パースと自動追記は OUT） | `checkWith` と `*Case`、失敗の種類、名前付きの Report 型、GenContext をメソッドだけにする、`internal` 名前空間、表示は再生成で作る、貼り付けられる ZON エントリ、型付きの `RegressionFile` | §5 |
| 6. stateful testing | **OUT**（v0.4 で再評価） | 前提（対話的な draw、コマンド列の削除の実測）がまだ揃っていない。v0.3 では先送りを妨げない形を選ぶ | §6 |
| 7. 互換性ポリシー | **IN** | `generator_version` は replay の意味だけを追う。I2 のマイルストーンで一度だけ 2 に上げる。v1 エントリは stale | §7 |

### 0.3 互換性の要約（詳細は §7）

- **replay 互換**（保存された正規化済み choice 列 → 値）: `generator_version` が守る対象。v0.3 でこれを変えるのは **I2 だけ**（再帰型の切断地点）。I4 は**ライブラリが記録した正規化済みのエントリ**について replay の意味を変えない（§2.5 で論証）。`generator_version` は I2 のマイルストーン（M7）で 1 → 2 にする。
- **seed 互換**（seed → 生成列）: バージョン間では約束しない（v0.3 で明文化する）。I4 は全ての整数型と float 型の seed → 値の対応を変え、I2 は再帰型について変える。
- **shrink 結果の互換**: 約束しない。I5 は同じ失敗から得られる最小形を変える。契約として固定するのは §3.6 の列挙だけ。
- v1 のエントリは gen_version 不一致として **stale（再生しない）**。移行ツールは作らず、v1 生成器の切り替えスイッチも置かない（§7.3）。

### 0.4 変えないもの（基盤）と、基盤に触れる決定

変えないもの: choice 表現 `{bound, value}` と有効性（v2 §2）、replay の正規化 `value % bound`（source.zig:176）、記録するのは意味的な値であること、キー列の shortlex による受理規則（v2 §6、shrink.zig:108-122, 208-217）、整数・float の組のキー注釈の形（非 skip の位置 + skip の位置。gen.zig:357-372, 523-549）、P4 の規則（shrink.zig:225-239, 326-339）、`deriveSeed`（source.zig:54-59）、予算をフラグで制御すること（shrink.zig:153-157）、評価結果の4分類（v2 §5）。

基盤に触れる決定（レビュアーはここを特に見てほしい）:
- **(F-a)** shrink の述語 P(C) を「失敗する」から「**同じ種類で**失敗する」に変える（D27）。bool の property だけを使う場合は今と同じになる。
- **(F-b)** Source が span 注釈（どの範囲がどの要素・出現か）をメタデータとして記録する。順序にも受理にも入れない（D18）。
- **(F-c)** random モードでだけ使う非一様なサンプリング（対数一様、中程度の大きさ）を内部 primitive として加える。記録される choice は今と同じく `{bound, value}` で、replay の意味は `range(bound)` と同じ（D14, D15）。v2 §3 の「range は一様」という記述は、この内部クラスについてだけ改める。

---

## 1. I2 — 切断の範囲

### 1.1 現状（v0.2.1 で確認）

- 切断は「再帰の出現」、つまり Set に既に入っているコンテナ型に再び入ったときにだけ起きる。起き方は2通り: 実行時は `ctx.depth >= max_depth` のとき（gen.zig:128-131）、comptime では `n >= max_depth_cap` のとき（gen.zig:103-110）。
- 切断形 `generateCut`（gen.zig:234-291）の挙動:
  - optional は常に null（:240）、slice は常に長さ 0 で draw なし（:250-260）。**要素型が再帰に関わるかどうかは見ていない。**
  - union は「切断形を持つ最初のバリアント」を **tag draw なしで**選ぶ（:273-286）。
  - スカラー、enum、bool は通常どおり draw する（:236-239）。
- その結果、次のことが起きる（レビュー I2 の主張を確認した）:
  - `Tree{ name: []const u8, extra: ?u32, kids }` の切断ノードは必ず `name = ""`、`extra = null` になる。
  - T4 の `Value` も meta8 の `Json` も、切断地点では必ず `.int` になる（`.str` は宣言順で `.int` の後なので選ばれない）。meta8.zig:82-90 の `expectAllNestedCut` はこの挙動を固定している。
  - **レビューに無かった細部**: union の切断では tag draw を行わない。このため非再帰のバリアント（`.str`）ですら切断地点に現れない。I2 は slice と optional だけでなく、union の tag の問題でもある。
- `cutExists`（gen.zig:209-232）と `generateCut` の union 分岐（:277-285）は、同じ条件 `cutExists(Payload)` を別々の場所に書いている。I1 はこの二重化から生じた不一致だった。

### 1.2 提案

切断地点の型を R とする（R は再入された型そのもの）。R の切断形を生成するとき、各構成要素 C について次のように扱う。

- `reaches(C, R)` が偽: C を **post-limit 状態** `(Set = ∅, n = max_depth_cap)` で**通常生成**する。
- `reaches(C, R)` が真: 構成的な切断（§1.3）を続ける。

union では、**許容バリアント**の中から tag を draw する。許容バリアントとは、ペイロードが R に到達しないもの（通常生成する）か、到達するが切断形を持つもの（切断モードで生成する）である。

### 1.3 精密な仕様

**到達関係** `reaches(A, B)`（comptime）: 型グラフの辺を次のように定め、A から B へ 1 本以上の辺で辿れるとき真とする。辺は、struct の comptime でない各フィールド型、union の各ペイロード型、optional の child、`N > 0` の配列の child、slice の child である。void、スカラー、enum、`[0]X` からは辺が出ない。訪問済みリストを持つ comptime の深さ優先探索で計算する。型の数が有限なので停止する。

**補題（Set を R だけに置き換えてよいこと）**: 切断地点の comptime 状態を Set（その経路で入ったコンテナ型の集合）とすると、R ∈ Set であり、どの X ∈ Set も R に到達する。X は経路上で R の今回の出現より前に入っており、X → … → R という経路が実在するからである。したがって任意の C について「C が Set のどれかに到達する」⇔「C が R に到達する」。→ v0.2.1 の正準集合の状態を持ったまま計算しても、`reaches(C, R)` だけで計算しても判定は同じであり、後者は経路に依存しない（C1 型の爆発を持ち込まない）。

**post-limit 状態の正当性**:
- (i) R に到達しない C の部分木には、Set のどの型も現れない（補題による）。だから Set の代わりに ∅ を渡しても `setHas` の結果はどの型についても変わらない。
- (ii) 不変条件 `ctx.depth ≥ n` が成り立つ。n が増えるのは depth が増えるときだけで（gen.zig:111 と :132 は同じ再入で対になる）、カスタム生成器から `generate` を呼ぶと n = 0 から始まる（:48）。このため、どの切断地点でも `ctx.depth ≥ max_depth` が成り立つ。
- (iii) よって、R に到達しない部分木の中での再入は、実行時に作っても必ず `depth ≥ max_depth` で切断される。n = cap を渡せばそれを comptime に前倒しするだけで、挙動は変わらない。post-limit の部分木では深さの消費と復元（gen.zig:128-136）は一度も起きない。

**`cutRel(C, R)` の規則**（`reaches(C, R)` が真の C に適用する）:

| C の種類 | 切断形 |
|---|---|
| slice `[]E` | 長さ 0、draw なし |
| optional `?E` | null、draw なし |
| 配列 `[N]E`（N > 0） | 要素ごとに `cutRel(E, R)` を N 回（各要素を要素予算で数える。今と同じ） |
| struct | comptime フィールドは既定値。他の各フィールド F は、`reaches(F, R)` なら `cutRel(F, R)`、そうでなければ post-limit で通常生成 |
| union | `admissible(U, R)`（宣言順）を m 個とする。m = 0 なら `error.InvalidGeneration`。m = 1 ならそのバリアントを選び draw なし。m ≥ 2 なら `index(m)` を draw する。選んだバリアントのペイロードは、R に到達しないなら post-limit で通常生成し、到達するなら `cutRel` で生成する。void ペイロードは draw なし |
| R 自身（入口） | 上の struct / union の規則を適用する |

- `admissible(U, R)` = { ペイロード P : `!reaches(P, R)` または `cutExistsRel(P, R)` }。
- `cutExistsRel(C, R)` の定義:
  - `!reaches(C, R)` → 真。
  - slice、optional → 真。
  - 配列 → `N == 0` または `cutExistsRel(E, R)`。
  - struct → comptime でない全フィールドについて `cutExistsRel` が真。
  - union → `admissible(U, R)` が空でない。
- `cutExistsRel` が再帰するのは、R に到達する struct フィールド、配列要素、union ペイロードだけである（slice と optional は即座に真）。これらの辺だけからなる循環は Zig が無限サイズとして拒否するので、`cutExistsRel` は停止する（v0.2 §3.3 の論証と同じ）。

**I1 の教訓への対応（一致を構成で保証する）**: `admissible(U, R)` を、バリアント index の comptime 配列を返す**一つの関数**として実装する。`cutExistsRel` の union 分岐は「その配列が空でない」、`cutRel` の union 分岐は「その配列から選ぶ」とし、条件式を二箇所に書かない。さらに表駆動の一致テストを置く（§1.7）。

**生成の停止（実行時）**: post-limit で通常生成される C は R に到達しない。だから C の部分木の中で次に起きる切断の根 Y は、`Reach(Y) ⊆ Reach(C) ⊊ Reach(R)` を満たす（R ∈ Reach(R) だが R ∉ Reach(C)）。到達集合は真に縮み、型は有限なので、切断の入れ子の深さは型の数以下である。二つの切断の間では、post-limit 状態のどの再入も即座に切断されるので、経路上のコンテナの初回進入は相異なる型だけになり、経路長は型の数で抑えられる。要素の総数は今までどおり `max_len` と `max_total_elements` で抑えられる。→ 生成は有界である。（これは論証であって、機械的には検査していない。）

**comptime 展開の停止**: 新しく増えるインスタンス化のキーは、`cutRel(C, R)`（型の対の数で有界）と post-limit の `generateRec(E, Set', cap)`（Set' は ∅ から初回進入だけで増え、n は cap に固定）である。どちらも有限である。post-limit の Set' の個数は、通常モードで n を固定した場合の個数を超えない。→ 停止は論証済みだが、**コンパイル時間は実測が必要**（M0-a）。

### 1.4 採らなかった案

- **(A) slice と optional だけを関連チャネルに限り、union の切断は「最初のバリアント・draw なし」のまま残す。** レビューが挙げた「切断地点に `str` の葉が出ない」が直らないので採らない。
- **(B) 切断で何も止めず、深さだけで止める**（再入するたびに切断形を作り直す）。切断形は深さを消費しないので、実行時に無限に再帰しうる（R → チャネル → R の切断 → …）。採らない。
- **(C) 到達判定に Set 全体を使う。** 補題により判定は同じで、インスタンス化が増えるだけなので採らない。
- **(D) union の切断で `index(全バリアント数)` を draw し、許容されないバリアントが出たら discard する。** discard 率が上がり、shrink 中に tag を下げる操作が discard に当たりやすくなる。採らない。

### 1.5 コスト

- 再帰型の replay の意味が変わる（切断地点の union で tag を draw する。R に到達しないチャネルを通常生成する）。→ `generator_version` を 2 にする（§7）。非再帰型の生成は一切変わらない（切断が起きないため）。
- 切断地点に生成されるデータが増え、ケースあたりの draw 数と要素数が増える。`max_total_elements` による discard が増える可能性がある。T4 で discard 数を測る（ゲートにはしない）。
- 既存の固定テストのうち次が変わる:
  - meta8.zig:108-134（Json の切断 replay の固定と `expectAllNestedCut`）
  - meta8.zig:172-182（List の void 切断が「draw なし」であること。m = 2 になり tag を draw する）
  - meta8.zig:184-197（Node の `Color` は R に到達しないので通常生成になり、`.red` 固定が崩れる）
  - meta8.zig:199-217（`ZU` は R に到達しないので通常生成になる）
- 変わらないもの: meta7.zig:67-80（`Tree{value, kids}` の切断形は value の draw と空の kids で、今と同じ）、:82-101、:103-116。
- 定義のうえでは「max_depth = 0 は子を全て剥がす」ではなくなる。README と verification の記述を変える。

### 1.6 Zig 0.17.1 で依存する機能

- 訪問済みリストを持つ comptime の再帰探索。`[N]type` の comptime 配列は gen.zig:74 で既に使っている。
- `@setEvalBranchQuota`。
- comptime の index 配列を `inline for` で回してバリアントを選ぶこと。union の選択は既存コードと同じく「`inline for` と index の比較」で書く（gen.zig:574-581 の方式）。

**探索関数が 0.17.1 で書けることは未確認**であり、M0-a で確認する。

### 1.7 検証

| 主張 | 証拠 | 種別 | 失敗とみなす結果 |
|---|---|---|---|
| `cutExistsRel` と `cutRel` が一致する | 新テスト `tests/meta9.zig` "cut: cutExists agrees with generateCut on every listed type"。meta7/meta8 の全型と新しい型について、全て 0 の replay で `cutRel` が InvalidGeneration を返すこと ⇔ `!cutExistsRel` | テストで固定 | 一つでも不一致 |
| 切断地点で非再帰チャネルが生成される | meta9 "cut: non-recursive fields are generated at the cut"。`Tree2{ name: []const u8, extra: ?u32, kids: []const Tree2 }` を max_depth = 0 で replay し、消費列、値、keys、skips を固定 | テストで固定 | 切断した子の `name` に長さ draw がない |
| 切断地点の union が tag を draw する | meta9 "cut: Json at the limit draws among admissible variants"。`.str` の切断を replay で固定。seed 0〜9 で `.str` と `.list = &.{}` が現れることも確認 | テストで固定 | `.int` しか出ない |
| 切断地点の部分木に固有の再帰があっても有界 | meta9 "cut: an independent recursive type below the cut stays bounded"。`Tree3{ meta: ?Other, kids }`、`Other{ next: []const Other }`。Other の入れ子は 1 段で切断される | テストで固定 | 2 段以上の入れ子、または停止しない |
| 多経路の型が今も速くコンパイルされる | meta8 の全型（Json, E, Bin）がコンパイルできること。コンパイル時間を M0-a と M7 で測る | コンパイルで固定、時間は測定のみ | コンパイルが終わらない（ゲート）。時間は報告のみ |
| 生成が停止する | §1.3 の論証 | **論証のみ（機械的検査なし）** | — |
| 非再帰型の replay が変わらない | §7.4 の golden replay の固定（非再帰の全形状） | テストで固定 | 一つでも差分 |

---

## 2. I4 — 分布

### 2.1 現状と算術（gen.zig:348-374 で確認）

整数（幅 W、ランク域 R = 2^W）の生成:
- class draw は `range(4)`（:358）。
- class 0: `range(min(R, 256))`（:360）。
- class 1: 境界集合の index（:361-365）。
- class 2: `range(min(R, 65536))`（:366）。
- class 3: `range(R)`。W = 64 では番兵の 0（:367）。

W = 64 の場合（u64、i64）:
- class 0 と 2 はランク < 2^16 に限られ、class 1（境界）は {0, 1, max-1, max} かそれに対応するランクで、どれも中域にない。
- P(ランク ∈ [2^16, 2^48)) = 1/4 · (2^48 − 2^16)/2^64 ≈ 2^-18 ≈ 3.8·10^-6 / ケース。レビューの「¼·2^-16」と一致する。
- P(ランク ∈ [2^21, 2^28)) ≈ 1/4 · 2^-36 = 2^-38。レビューと一致する。

W = 32: P(ランク ∈ [2^16, 2^24)) ≈ 1/4 · 2^-8 ≈ 0.098% / ケース。レビューと一致する。

**訂正**:
- (1) レビューの「T1 passes only because 2^28 sits in the top 1/16 of u32」は不正確である。T1 の失敗域 [2^28, 2^32) は class 3 の域の **15/16** を占める。u32 の境界集合は {0, 1, 2^32−2, 2^32−1} の4つで、そのうち2つが失敗する。したがって 1 ケースの発見確率は 1/4·15/16 + 1/4·1/2 ≈ 0.36 である。
- (2) この穴は **W > 16 の型にだけ**ある。W ≤ 16 では class 2 の bound が R に等しく、class 2 がすでに全域一様だからである（u8 と u16 では class 2 と class 3 が同じ分布）。

float（gen.zig:515-551）: class 0 は −16〜16 の整数、class 1 は境界、class 2 は k/8 のグリッド（|x| ≤ 128）、class 3 は全ビットパターン一様。0.1 や 1234.567 のように二進で割り切れない普通の値は class 3 からしか出ない。f64 の class 3 で指数が [−20, 20] に入る確率は約 41/2048 ≈ 2%（レビューの「約 1%」と同程度）。

### 2.2 提案（整数）

**class 2 を対数一様に置き換える。** class draw は `range(4)` のまま、組の形（class の位置 + 値の位置）も、キー注釈（値のランク、2番目の位置は skip）も変えない。

- 値 draw の**意味**: bound = R（W = 64 では 0）、値 = ランクそのもの。replay では class 3 と同じ `raw % R` になる。
- **random モードでのサンプリング**:
  1. 幅 w を {0, 1, …, W} から一様に引く。
  2. w = 0 ならランク 0、そうでなければランク = 2^(w−1) + 一様[0, 2^(w−1))。
  3. 記録するのは `{bound = R or 0, value = ランク}` の choice 1 個。
  この非一様な draw は Source の内部 primitive `rangeLogUniform(bits)` として実装する（D14、F-c）。生成器から PRNG に直接触る手段はなく、記録される choice の有効性（`value < bound`）は保たれる。
- 符号付き: ランク空間でのサンプリングなので、zigzag により絶対値が対数一様になり、符号はランクの偶奇でほぼ半々になる。
- W = 1: w ∈ {0, 1} → ランク {0, 1}。W = 64: w = 64 のときランク ∈ [2^63, 2^64)。どちらも u64 に収まる。
- クラスの比率は 1/4 ずつのまま。u64 の各オクターブの確率は 1/4 · 1/65 ≈ 0.38% / ケースになる。

**正規形と P4**:
- 正規形は class 3 のまま（P4 の書き換え先、shrink.zig:331-335）。class 2 の組は値の位置にすでにランクを持っているので、P4 が (2, r) → (3, r) と書き換えても値は同じでキー列も同じである。P4 は一方通行の横移動としてそのまま成り立つ。
- 通常受理で 3 → 2 の逆行は起きない。class の位置に P3 を適用して 3 を 2 に減らしても、値 draw の意味は `% R` で同じランクのままなのでキーは等しく、通常受理（厳密な減少）では拒否される。
- 測度（キー列の shortlex、非正規形の組の数）の議論（v2 §6）は変わらない。
- P4 は受理時に再評価して、キーが等しいことと class = 3 であることを確認する（shrink.zig:228-232）。だから健全性は論証ではなく、コードによる検査で保たれる。

### 2.3 提案（float）

**class 4「中程度の大きさ」を追加し、class draw を `range(5)` にする。** class 0〜3 の定義は変えない（グリッドは厳密な二進値によるバグを見つけるのに有用で、T3 の到達経路にも関わるので残す）。

- 値 draw の意味: bound = 2^bits（f64 では 0）、値 = ランク。replay では class 3 と同じ（NaN の写像も同じ。gen.zig:401-410）。
- random モードでのサンプリング:
  1. 符号を一様に引く。
  2. 偏りを除いた指数 e を一様に引く。範囲は f32/f64 では [−20, 20]、f16 では正規数の全範囲 [−14, 15]。
  3. 仮数を `2^mant_bits` から一様に引く。
  4. ランク = 2·((e + bias) << mant_bits | m) + sign。
  生成される値は必ず有限の正規数で、NaN や ∞ は出ない。
- 1 ケースあたりのクラス比率は 1/5 ずつ。

### 2.4 採らなかった案

- **(A) 幅の draw と値の draw に分けた3つ組（class, 幅, 値）。** 組を前提にしている箇所（`annotatePair` の2位置、`passReexpress` の「非 skip の直後に skip」、`tryRatchet` の長さ一致、shrink.zig:228）を全て一般化しなければならない。P4 の書き換えで生の列の長さが変わり、受理の検査も変える必要がある。shrinker に手を入れる量が大きく、replay の意味も変わるので採らない。
- **(B) 整数でも class 5 を追加し、class 2（65536）を残す。** 狭い型でも分布が変わる点は同じで、W ≤ 16 では class 2 が class 3 と重複したまま残る。得るものがないので採らない。
- **(C) float の class 2（グリッド）を中程度の大きさのクラスに置き換える。** 厳密な二進値（0.125 など）を引く確率が無くなる。採らない。
- **(D) 中程度の大きさの整数クラス（例: 2^16〜2^32 一様）。** 特定の幅を恣意的に選ぶことになり、対数一様の方が幅について偏りがない。採らない。

### 2.5 replay 互換の論証（I4 単独では `generator_version` を上げない根拠）

- ライブラリが記録する列は正規化済みである。記録されるのは `range` の戻り値で、source.zig:179 で `value < bound` を満たして記録される。checkOrError が印字するのも shrunk 後の正規化済みの値である（runner.zig:126-127）。
- 整数: v1 で class 2 の値として記録された v は `v < min(R, 65536) ≤ R` を満たす。v2 の replay `v % R = v` なので、v1 の `v % min(R, 65536) = v` と同じ値になる。class 0、1、3 は定義を変えないので同じ。
- float: v1 で記録された class 値 c は c < 4 なので、v2 の `c % 5 = c`。class 0〜3 の定義は同じ。
- したがって、**正規化済みの v1 の列は、v2 の I4 適用後も同じ値に replay される**。例外は、手で書いた正規化されていない値（たとえば class 2 の位置に 100000 を書いた u32 のエントリ）で、これは意味が変わる。私はこれを互換の対象外と宣言する（v2 §7 の保存契約は「正規化済みの実消費列」だからである）。
- この論証は M6 の終了基準「全ての replay の固定が無変更」で**機械的に検査する**（§7.4）。

### 2.6 コスト

- **seed 互換が壊れる。** 全ての整数型（W ≥ 1。W ≤ 16 でも class 2 のサンプリングが変わる）と全ての float 型で、seed → 値の対応が変わる。
- 固定 seed の挙動に依存している既存テストを再検証する必要がある（v0.3 で洗い出したもの）:
  - meta5.zig:21-35（seed 42 の golden）。class 2 の bound が 65536 から 2^32 に、値も変わる。**M6 で再記録する**。
  - meta5.zig:37-54（u8 の golden）。class 0 と class 3 の draw だけなので、分布の変化は class 2 が出たかどうかだけに表れる。再記録が要るかもしれない。
  - meta5.zig:231-247（「seed 0 の最初の3ケースは全て pass」を走査で確認したもの）。float の class 比率が変わるので再走査が必要。
  - meta2.zig:48（i8 を 300 回試行して境界値に到達する）。
  - meta2.zig:156, 183（seed 5 と 9 での失敗）、meta3.zig:18-27, 50-75（seed 1）、meta3.zig:77-94（seed 5）、meta3.zig:111（seed 0）、meta6.zig:132（seed 0）、examples.zig:62-73（seed 2）。
  ほとんどは「失敗が見つかる」ことだけを主張しているので、壊れる可能性は低いが、M6 で全て実行して確認する。
- class 2 の [256, 65536) への偏りが減る。u64 で 1/4 → 約 3.1%（幅 9〜16 の 8/65 × 1/4）。この範囲だけにあるバグの発見率は下がる。T1〜T4 の再実行でゲートが下がらないことを確認する。
- float の class 0〜2 の確率が 1/4 から 1/5 に下がる。T3 で発見率を確認する。

### 2.7 検証

| 主張 | 証拠 | 種別 | 失敗とみなす結果 |
|---|---|---|---|
| v0.2 は中域のバグを発見できない | T5 の v0.2.1 ベースライン（M0-e で実測。予測は 0/10、確率の上界は 200·2^-38 / seed） | 測定・事前予測 | v0.2.1 で 1 seed 以上発見した場合、§2.1 の算術が誤り |
| 対数一様クラスで中域バグを発見し、最小まで shrink できる | T5, T5s（§8） | ゲート | §8 の基準未達 |
| 新しいクラスの意味（replay） | 新 golden `tests/meta10.zig` "golden v2: integer class 2 replays as rank"。各幅（u1, u8, u16, u17, u32, u64, i1, i8, i16, i17, i32, i64）で (2, r) → 値、消費列、keys、skips を固定 | テストで固定 | 差分 |
| サンプリングが仕様どおり | meta10 "distribution: log-uniform width histogram"。u64 と i64 を 65 × 1000 回引き、幅ごとの度数が一様の 99.9% 区間に入る。f64 の class 4 では指数の範囲と NaN/∞ が出ないことを確認 | テストで固定（統計検定。seed 固定なので決定的） | 区間外、NaN/∞ の出現 |
| I4 は正規化済み列の replay を変えない | M6 の終了基準: M1 で置いた replay の固定が全て無変更 | テストで固定 | 一つでも差分 |
| float の中程度クラスが「普通の値」を出す | T5-F（§8）。指数 [−20, 20] かつ仮数の下位 20 bit ≠ 0 の比率を v0.2.1 と v0.3 で比べる | 測定のみ（ゲートなし） | — |
| P4 は class 2 と 4 からも一方通行で健全 | meta10 "P4: class-2 and class-4 pairs ratchet to class 3 with equal keys"（regression で各1件） | テストで固定 | キーの変化、受理されない |
| 測度による停止 | v2 §6 の論証。クラスが増えても変わらない（§2.2） | **論証のみ** | — |

---

## 3. I5 — shrinker の強さ

### 3.1 現状（shrink.zig で確認）

- 1巡は P1 chunk 削除 → P4 → P2 0化 → P3 減少（:341-348）。
- P1 の chunk サイズは `highestPow2(len)/2` から半分ずつ 1 まで下げる（:253）。2 の冪だけで、len の半分より大きいサイズは試さない。
- 要素とその長さ draw を同時に消すパスはない。部分木を昇格するパスもない。
- shrinker は列の構造（どの範囲が要素か）を知らない。Source が記録するのは choice、キー、skip だけである（source.zig:70-78）。→ 要素削除と昇格には構造情報が要る（D18）。
- meta7.zig:154-179 は非最小の結果 `{0, [{7, []}]}`（キー4個）を固定している。キー2個の `{7, []}` が存在する。
- レビューの「`[1,7,3]` は `[0,7]` で止まる」は、私も追ってみて同じ結論になった（推論。未実行）: 7 の前の要素を消すとき長さ draw を同時に下げられないので、ずらすと `[7, 0]` になり、キー `[2, 7, 0] > [2, 0, 7]` で拒否される。
- 予算を使い切った後も、各パスは位置ごとに候補の複製を作り続ける（:257-260, :280, :303）。tryAccept は :209 で即 false を返すので評価は増えないが、CPU を使う（レビューの軽微な指摘のまま）。

### 3.2 提案

1. **span 注釈（D18）**: 生成のあいだ Source が次を記録する。
   - 各 slice 要素の範囲 `[start, end)` と、その slice の長さ draw の位置 `length_pos`。
   - 各コンテナの出現（struct または union の生成1回）の範囲と、型の識別子 `type_id`（`@typeName(T)` の 64 bit ハッシュ）。
   span は**メタデータ**であり、キー列にも受理判定にも入れない。ハッシュの衝突（別の型が同じ id になる）は効率を落とすだけで、健全性には影響しない（理由は §3.4）。カスタム生成器が primitive を直接使う部分には span がなく、P5 と P6 はその部分では候補を作らない。
2. **P5 要素削除**: 長さ draw の値が v ≥ 1 である slice の各要素 span `[s, e)`（`length_pos = ℓ`）について、候補を作る。候補は、位置 ℓ の値を v − 1 にし、位置 [s, e) を取り除いた列である。要素は後ろから順に試し、受理されたら新しい best の span で同じ slice を最初から走査し直す。
3. **P6 部分木昇格**: 出現 span X と、X の中で最も近い同じ `type_id` の出現 Y（X と Y のあいだに同じ型の出現がないもの）の組ごとに、候補を作る。候補は `values[0..X.start] ++ values[Y.start..Y.end] ++ values[X.end..]`。X は先行順、Y は先行順で試す。1回の受理で1段だけ持ち上がり、巡回を重ねれば深いところからも持ち上がる。
4. **P1 の拡張（P1b、「高価なパス」）**: サイズ集合 {3, 5, 6, 7}（ただし len 以下のもの）の chunk 削除を、**その巡の他のパスが全て変更なしだったときにだけ**走らせる。既存の P1（2 の冪）はそのまま残す。結果として、不動点での近傍は「サイズ 1〜8 の全 chunk と、len/2 以下の 2 の冪」になる。
5. **巡の構成（v0.3）**:
   ```
   round = P6 → P5 → P1 → P4 → P2 → P3
   その巡で変更がなく、予算も残っていれば → P1b
   不動点 = P1b まで含めた1巡で変更なし
   ```
6. 予算切れの後は、各パスのループの先頭で `exhausted` を確認して抜ける（挙動は変えず、CPU の無駄だけを止める）。

### 3.3 精密な仕様（列とキー順序による定義）

best を、列 `V = v_0 … v_{L−1}`、キー K、skip S、span 集合 Σ の組とする。どのパスも候補の**値列** V' だけを作り、`tryAccept(V')`（shrink.zig:208-217）に渡す。`tryAccept` は V' を replay し（足りない分は 0 で埋める。v2 §6 の実装注記）、次の3つが全て成り立つときだけ best を置き換える。

- 失敗した。
- その失敗の種類が元の失敗と同じである（§5 の D27）。
- 再記録された列のキー列 K' が `K' <_shortlex K` を満たす。

置き換えるときは、再記録された (V'', K', S', Σ') で best を丸ごと置き換える。**P5、P6、P1b は P4 の横移動の受理（`tryRatchet`）を使わない。**

### 3.4 健全性と停止の論証

- **健全性**: P5、P6、P1b は全て `tryAccept` を通る。だから受理される候補は (a) 失敗し、(b) 同じ種類の失敗であり、(c) キー列が厳密に shortlex で小さい。span が間違っていても（ハッシュ衝突、カスタム生成器の span なし）、作られる候補が変わるだけで、受理条件は再評価で検査されるので崩れない。→ 「小さくない候補を受理する」ことは起きない。これは構成による主張である（受理の判定を行うコードは `tryAccept` 一つだけ）。実装では、新しいパスが `tryAccept` 以外で best を置き換えないことをコードレビューで確認する。
- **停止**:
  - 測度は v2 §6 と同じく（キー列の shortlex、非正規形の組の数）の辞書順。新しいパスの受理は全て通常受理なので、第1成分が厳密に減る。
  - キー列の要素は u64（有限のアルファベット）である。長さを先に比べる shortlex は、各長さで列が有限個しかないので整礎であり、受理の回数は有限である。
  - 一つのパスの中では、受理と受理のあいだに試す候補は有限個（P5 は要素数、P6 は出現の対の数、P1b は 4·L 以下）であり、受理するたびに走査をやり直しても全体は有限である。
  - さらに評価回数は予算で上から抑えられる。
  - Lean では shortlex の整礎性を証明していない（verification.md の既知の欠落）。だから**この停止は論証であり、証明ではない**。
- **ループしないこと**: 横移動は P4 だけであり、P4 は組ごとに一方通行（v2 §6）。新しいパスは横移動を持たないので、新しい循環は生じない。

### 3.5 予算への影響と、予算切れの報告

- 1巡あたりの候補数（L は列長、n は出現の数、k は slice 要素の数）:
  - P6 ≤ n − 1（最も近い同じ型の子だけに限るので線形）
  - P5 ≤ k
  - P1b ≤ 4L（P1b は不動点の直前にだけ走る）
- 例: T4 の評価回数は v0.2 で 102〜305 回だった。L = 100 なら最後の巡で P1b が最大 400 回増える。
- 既定の `shrink_budget = 2000` は**変えない**。T1〜T7 で評価回数を測って報告し、予算切れになった seed の数も報告する（ゲートには、それぞれの target の最小性の基準を通して間接的に効く）。
- 予算切れの報告は今の方式を守る。`Inner.exhausted` フラグで制御し、エラー名は使わない（shrink.zig:153-157）。巡の終わりにフラグを優先して `budget_exhausted` を返す（:393）。新しいパスも `evalCandidate` を通るので、自動的にこのフラグに従う。
- meta3.zig:209-248 の予算境界の固定（カスタム生成器、長さ 1 の列）は、P5/P6 の候補なし（span なし）、P1b の候補なし（len < 3）、P1 は同じ、という理由で**評価回数まで変わらない**はずである（論証。M3 の終了基準で検査）。

### 3.6 契約として固定する最小形と、測定だけするもの

| 事例 | v0.3 の期待値 | 種別 |
|---|---|---|
| meta7.zig:154 の木（regression `{0,6,1,0,14,1,0,18,0}`、property `noSeven`） | 値 `Tree{ .value = 7, .kids = &.{} }`、**キー列 `[14, 0]`**（v0.2 の固定 `{0, [{7, []}]}` は撤回する） | テストで固定（M3 で meta7 を書き換え） |
| slice の「7 を含む」（regression で `[1, 7, 3]`、`[]const u8`） | 値 `[7]`、キー列 `[1, 7]` | テストで固定（新テスト meta9 "shrink: element deletion removes a leading element with its length"） |
| T4 `list[int 0, int 0, int 0]` | 構造が一致すること（ゲート） | validation のゲート |
| T6 / T7（§8） | `Tree{7, []}` / `[7]` | validation のゲート |
| 既存の meta3、meta4、meta6 の値の期待 | 変更なし | テストで固定 |
| 生の choice 列（P4 の後かどうかなど）、評価回数 | — | **測定のみ** |

キー列を固定し、生の choice 列は固定しない理由: P4 の横移動の有無やパスの順序で生の列（例: (0, 14) か (3, 14) か）は変わるが、キー順序のうえでの最小は一意だからである。

### 3.7 採らなかった案

- **(A) span なしで、「各位置 i の値を 1 減らし、かつ後続の chunk を削除する」組み合わせを総当たりする。** O(L²) で予算に収まらない。採らない。
- **(B) P1 に 1〜8 の全サイズを毎巡入れる。** 長い列で1巡が約 1.7 倍になり、P5 が構造的な削除を担った後では効果が小さい。採らない（P1b として不動点の直前だけで走らせる）。
- **(C) 昇格で、全ての子孫（最も近いものに限らない）を一度に試す。** O(n²) になる。1段ずつでも巡を重ねれば到達できるので採らない。
- **(D) span をカスタム生成器にも公開 API として提供する。** API の面が増え、v0.4 の対話的な draw の設計とぶつかる。v0.3 では内部に留める（§6.3）。

### 3.8 コスト

- 生成の各 slice 要素と各コンテナ出現で span を ArrayList に追加するため、random 探索のコストも増える。`zig build bench` で Source と生成のマイクロベンチを測る（ゲートなし、BASELINE と比べて報告）。
- 予想より高い場合の代替案: span は replay モードでだけ記録し、shrink の最初の評価で span を得る。ただしこれは、meta3.zig:195 の「評価回数 = 生成器呼び出し回数」の固定と相談が必要になる。
- shrink の結果が変わる。v0.2 で印字された regression エントリは、同じ失敗でも v0.3 では別の列になる（互換の対象外）。
- meta7.zig:154-179 の期待値を変える（撤回の理由をテストのコメントに残す）。

### 3.9 検証

| 主張 | 証拠 | 種別 | 失敗とみなす結果 |
|---|---|---|---|
| span の記録は choice、キー、skip を変えない | M2 の終了基準: M1 の全ての replay と random の固定が無変更 | テストで固定 | 一つでも差分 |
| span の形 | meta9 "spans: slice elements and occurrences"。`Tree` と `[]const u8` で span の位置、`length_pos`、入れ子を固定 | テストで固定 | 差分 |
| P5、P6 は厳密な減少でしか受理しない | 構成（`tryAccept` 経由のみ）+ meta9 "shrink: new passes never accept a non-smaller candidate"。全ての受理の前後のキー列を記録する内部フックで検査し、T6/T7 の全 seed で単調減少を確認する | テストで固定（フックは internal） | 非減少の受理 |
| meta7 の木は `{7, []}` まで縮む | meta7（書き換え後）、§3.6 | テストで固定 | 他の形 |
| slice の要素削除 | meta9、§3.6 | テストで固定 | `[0, 7]` で止まる |
| 予算の境界と flag の意味は不変 | meta3.zig:209-248（無変更で pass） | テストで固定 | 評価回数の変化 |
| shrink の改善はパスごとに帰属できる | T6/T7 のアブレーション（P6 無効、P5 無効。内部のパスマスク） | 測定のみ | — |
| 停止 | §3.4 | **論証のみ** | — |

---

## 4. I6 — regression の頑健性

### 4.1 現状（確認済み）

- `Regression = { id, gen_version, choices }`（runner.zig:24-28）。Limits と型の情報は持たない。
- 長さは `length(max_len)` で `range(max_len + 1)` になり（gen.zig:166、source.zig:200-207）、replay では `raw % bound`（source.zig:176）。max_len を変えると、同じ列が別の長さを生む（I6 の主張を確認）。
- max_depth は切断の位置を決める（gen.zig:128-131）。切断では長さと tag を draw しない（:240, :250-260, :277-284）ので、変えると以降の列が全てずれる。
- 未消費の suffix: Source は無視する（meta.zig:102-114 が Source の層で固定）。runner の regression 段階も `src.pos` を見ていない（runner.zig:205-215）。→ pass すれば `regressions_passed` に数えられ、警告もない（確認済み）。
- stale の警告は `std.debug.print` で出す（runner.zig:195, 212）。

### 4.2 Limits の各フィールドが生成に関わるか（コードから導出）

| フィールド | 使用箇所 | 値の意味を変えるか | 判定 |
|---|---|---|---|
| `max_len` | gen.zig:166（slice の長さの bound） | **変える**（`% (max_len+1)`） | fingerprint に入れる。ただし T が slice に到達する型でなければ 0 に正規化する |
| `max_depth` | gen.zig:129（実行時の切断）、runner.zig:179（検証） | **変える**（切断の位置） | fingerprint に入れる。T が再帰型でなければ 0 に正規化する |
| `max_total_elements` | gen.zig:18-23（超過で discard） | 変えない（超えるかどうかだけ。超えれば discard → stale として検出済み） | 入れない |
| `max_draws` | source.zig:156-160（超過で discard） | 変えない（同上） | 入れない |

- カスタム生成器（`checkCustom` / `checkWith` に生成器を渡す場合）: 生成器が `ctx.limits` の何を読むか分からず、`ctx.generate` で組み込み生成を呼ぶこともある。だから `max_len` と `max_depth` を**常に**入れ、正規化しない。
- `T が slice に到達する`と`T が再帰型である`（ある コンテナ X が T から到達可能で、`reaches(X, X)` が真）は、§1.3 の `reaches` で comptime に判定する。

### 4.3 型の fingerprint: 構造ハッシュを採る

| 変更 | `@typeName` | 構造ハッシュ（提案） | 生成への影響 |
|---|---|---|---|
| 型の改名、別ファイルへの移動 | stale（誤検出） | 検出しない（正しい） | なし |
| フィールドの改名 | 検出しない | 検出しない（名前は含めない） | なし |
| フィールドの並べ替え | **見逃す** | 検出する | あり |
| 整数幅の変更（u32 → u64、usize の 32/64 bit） | **見逃す** | 検出する | あり |
| バリアントの追加、並べ替え | **見逃す** | 検出する | あり |
| enum の明示値の変更 | 見逃す | 検出する（値を含める） | あり（値の写像） |
| comptime フィールドの値 | 見逃す | 検出しない（draw しないので含めない） | 値は変わるが列の意味は不変 |
| カスタム生成器のコード変更 | 見逃す | **見逃す** | あり |
| 形が同じままの意味の変更（同じ型の2フィールドの役割を入れ替える） | 見逃す | **見逃す**（原理的に不可能） | — |

**構造ハッシュの定義**: 型の「生成の形」を正準に直列化した列に対する 64 bit の FNV-1a（comptime で計算）。直列化には次を含める。

- 種類のタグ。
- 整数: 符号と幅。float: 幅。
- enum: フィールド数と各値（宣言順）。
- optional: child。配列: 長さと child。slice: child。
- struct: comptime でないフィールドの型を宣言順に。
- union: tag の有無とペイロードを宣言順に（void を区別する）。

再帰型は、名前付きコンテナに初めて訪れた順に番号を振り、2回目以降は「後方参照 #k」として直列化する（訪問済みリスト。§1.3 と同じ探索の基盤を使う）。

- **Zig 0.17.1 で依存する機能**: comptime の文字列・バイト列の構築、`@typeInfo` の `field_types` / `field_values`、comptime ループの `@setEvalBranchQuota`。**再帰型で後方参照を伴う直列化が 0.17.1 のコンパイル時間内で書けることは未確認**で、M0-b で確認する。
- 落とし穴: ハッシュの安定性はこの定義そのものが仕様になる。定義を変えれば全てのエントリが stale になる。定義は golden（「この型の hash = 0x…」）で固定する（§4.8）。

### 4.4 ZON スキーマ

```zig
pub const Fingerprint = struct {
    /// 生成の形の構造ハッシュ（§4.3）。
    type_hash: u64,
    /// T が slice に到達しない場合（カスタム生成器は除く）は 0 に正規化。
    max_len: u64,
    /// T が再帰型でない場合（カスタム生成器は除く）は 0 に正規化。
    max_depth: u8,
    /// カスタム生成器で記録されたか（組み込み生成との取り違えを検出する）。
    custom_generator: bool,
};

pub const Regression = struct {
    id: []const u8,
    gen_version: u32,
    /// v0.3 で追加。v0.3 より前のエントリと手書きのエントリでは null。
    fingerprint: ?Fingerprint = null,
    choices: []const u64,
};

/// tests/regressions.zon の型（v2 §7 の version 1 スキーマに、任意フィールドを追加したもの）。
pub const RegressionFile = struct {
    version: u32,
    entries: []const Regression,
};
```

- ファイルの `version` は **1 のまま**にする。追加するのは既定値付きの任意フィールドだけで、v0.2 のファイルはそのまま読める。`gen_version`（生成の意味）と `version`（ファイルのスキーマ）は別物である。
- 依存する機能: `@import("regressions.zon")` を結果型 `RegressionFile` に coerce できること、そして**欠けた任意フィールドに既定値が入ること**。0.17.1 では未確認で、M0-c で確認する。

### 4.5 stale の条件と扱い

regression 段階の各エントリ（id が一致するもの）について、次の順に判定する。

| # | 条件 | 再生するか | 分類 |
|---|---|---|---|
| 1 | `gen_version` ≠ 現在の値 | しない | stale（`gen_version_mismatch`） |
| 2 | fingerprint が非 null で、現在の値と不一致 | しない | stale（`fingerprint_mismatch`。どのフィールドが違うかも記録） |
| 3 | 再生して fail | — | **失敗として報告する**（現在のコードの本物の反例は隠さない）。条件 4 か 5 にも当たる場合は、その stale の理由を `Report.Failed.origin` に付ける |
| 4 | 再生して discard（枯渇を含む） | した | stale（`discarded`。今と同じ） |
| 5 | 再生して pass、かつ `src.pos < choices.len`（未消費の suffix） | した | stale（`unconsumed_suffix`）。**passed には数えない** |
| 6 | 再生して pass、fingerprint は null | した | passed、ただし `unverified` に数える |
| 7 | 再生して pass、fingerprint 一致、suffix なし | した | passed |

- バージョンか fingerprint が不一致のエントリを「とりあえず再生」しない理由: そのエントリが生む値は不明であり、pass しても何も保証しない。fail した場合は本物の反例ではあるが、未知の値を探すのは random 段階の仕事である。挙動を単純で決定的に保つ方を選ぶ。
- 制御フローにエラー名を使わない: stale の判定は runner の中の enum `StaleReason` と値で行い、エラーは返さない。ユーザーの property や生成器が返すエラーとは経路が分かれているので取り違えない（§5.3）。

### 4.6 報告の方法と方針

- ライブラリの中核（`check*`）は**一切印字しない**。stale は `Report` の `regressions: RegressionSummary` に、エントリごとの理由付きで入れる（§5.2）。
- `*OrError` ラッパー（テストに組み込むための層）は stale を `std.debug.print` で印字する。ラッパーの役目は印字することであり、テストランナーが stderr を拾う。
- `Config.fail_on_stale: bool = false`。true のとき、`*OrError` は stale が 1 件以上あれば印字したうえで `error.StaleRegression` を返す（property の失敗のほうを優先する）。既定値は利用者の判断に関わる（未決事項 Q2）。

### 4.7 採らなかった案

- **(A) `@typeName` だけを使う。** §4.3 のとおり、生成に影響する変更の大半を見逃し、無害な改名で誤検出する。
- **(B) `@typeName` と構造ハッシュの両方を使う。** 改名で stale になるという害だけが増える。
- **(C) Limits の全フィールドを fingerprint に入れる。** `max_draws` を上げただけで全エントリが stale になる。discard 系のフィールドは、超過すれば既に stale として検出される。
- **(D) stale を常に error にする。** v0.3 は gen_version を上げるので、regression を持つ全ての利用者のテストがアップグレードした瞬間に落ちる。既定にするかは Q2 に回す。
- **(E) fingerprint のないエントリを stale とする。** 手書きのエントリを書きにくくなる。`unverified` として数え、目に見えるようにする方が良い。

### 4.8 検証

| 主張 | 証拠 | 種別 | 失敗とみなす結果 |
|---|---|---|---|
| 関連する Limits と型の変更を検出する | T8（§8）の行列 | ゲート | 検出漏れ、または誤検出 |
| 正しい replay を stale と誤判定しない | T8 の対照 | ゲート | 誤検出 |
| 構造ハッシュの定義の固定 | `tests/meta11.zig` "fingerprint: golden hashes"。代表的な型 10 個について hash 値を固定し、改名では不変、並べ替えと幅の変更では変わることを確認 | テストで固定 | 差分 |
| 未消費の suffix を stale にする | meta11 "stale: unconsumed suffix is not counted as passed" | テストで固定 | passed に数えられる |
| 失敗する stale エントリは失敗として報告される | meta11 "stale: a failing replay with a suffix is still reported as a failure" | テストで固定 | 握りつぶされる |
| 既存の v0.2 ファイルが読める | meta11 "zon: a version-1 file without fingerprints imports" と、`tests/regressions.zon` 自体の import テスト | テストで固定（M0-c で可否を確認） | コンパイルエラー |
| 中核は印字しない | src/ 以下に `std.debug.print` が OrError ラッパー以外に無いことを CI の grep で確認 | テスト（CI の grep） | 該当行あり |

---

## 5. I7 / I8 — API と regression のワークフロー

### 5.1 現状（確認済み）

- property は `*const fn (T) bool` のみ（runner.zig:89-106）。T4 は 256 KiB + 16 MiB のグローバルバッファで回避している（validation/main.zig:268-272）。
- `checkCustomOrError` はない。`checkOrError` は空白区切りの値を印字するだけで、`gen_version` も id も出さない（runner.zig:111-132、特に :126-127）。→ v2 §7 の「印字された断片を貼る」運用は成立していない（確認済み）。
- 公開面:
  - root.zig:12 で `Source` を、:13 で `deriveSeed` を、:19-20 で `shrink` / `ShrinkResult` を公開している。shrink の公開はレビューが挙げていなかった。
  - `Source` の `recorded`、`recorded_keys`、`recorded_skip`（source.zig:70-78）と `annotatePair`（:136-143）は pub。
  - `GenContext` のフィールド `src`、`elements_generated`、`depth` も外から書ける（source.zig:34-47）。
- `Report` の各ペイロードは無名の struct（runner.zig:46-74）。regression による失敗では `seed = config.seed`、`attempt_index = 0` を報告していて誤解を招く（runner.zig:214）。
- 表示は property の**後に**フォーマットしている（shrink.zig:76 の後に :83）。README の例（README.md:28-33）と examples.zig:55 は入力を `@constCast` でその場でソートする。→ この property が失敗すると、元の値の表示が変形後のものになる（確認済み）。
- shrink 中も、失敗した候補のたびに表示文字列を確保している（shrink.zig:83 は evaluateAttempt 経由。使われるのは最後の1つだけ）。

### 5.2 v0.3 の公開 API（Zig の宣言）

```zig
// ---- 生成 ----
pub const Limits = struct { max_len: usize = 32, max_total_elements: usize = 4096,
                            max_draws: usize = 100_000, max_depth: usize = 8 };   // 変更なし

/// カスタム生成器が受け取る文脈。フィールドは allocator と limits だけで、
/// 記録・深さ・要素予算の状態は internal に隠す。
pub const GenContext = struct {
    /// 試行の arena。
    allocator: std.mem.Allocator,
    /// 読み取り専用として扱う（書き換えても生成には反映されない複製）。
    limits: Limits,
    impl: *internal.GenState,

    pub fn range(self: *GenContext, bound: u64) u64;
    pub fn boolean(self: *GenContext) bool;
    pub fn index(self: *GenContext, n: u64) u64;
    pub fn length(self: *GenContext, max_inclusive: usize) usize;
    /// 組み込み生成。深さと要素予算を共有し、キー注釈と span を付ける。
    pub fn generate(self: *GenContext, comptime T: type) anyerror!T;
    /// slice / 配列の要素を自前で作るときに予算を数える。
    pub fn countElement(self: *GenContext) error{InvalidGeneration}!void;
};

pub fn Generator(comptime T: type) type {
    return *const fn (gen: *GenContext) anyerror!T;
}
pub fn GeneratorWith(comptime Ctx: type, comptime T: type) type {
    return *const fn (ctx: Ctx, gen: *GenContext) anyerror!T;
}

// ---- property ----
/// property に渡す試行ごとの情報。v0.4 で拡張できるよう、ポインタで渡す。
pub const Case = struct {
    /// 試行の arena（生成値と同じ寿命）。SUT の作業領域に使う。
    allocator: std.mem.Allocator,
};

pub fn PropertyWith(comptime Ctx: type, comptime T: type) type {
    return *const fn (ctx: Ctx, case: *Case, value: T) anyerror!bool;
}

/// 失敗の種類。shrink はこの種類を保つ（D27）。
pub const Failure = union(enum) {
    returned_false,
    returned_error: anyerror,
};

// ---- 入口 ----
pub fn check(gpa: Allocator, comptime T: type,
             property: *const fn (T) bool, config: Config) anyerror!Report;          // シグネチャ不変
pub fn checkCustom(gpa: Allocator, comptime T: type, generator: Generator(T),
             property: *const fn (T) bool, config: Config) anyerror!Report;          // シグネチャ不変
pub fn checkWith(gpa: Allocator, comptime T: type, comptime Ctx: type, ctx: Ctx,
             generator: ?GeneratorWith(Ctx, T),
             property: PropertyWith(Ctx, T), config: Config) anyerror!Report;        // 新規・汎用形

pub fn checkOrError(gpa: Allocator, comptime T: type,
             property: *const fn (T) bool, config: Config) anyerror!void;            // 不変
pub fn checkCustomOrError(gpa: Allocator, comptime T: type, generator: Generator(T),
             property: *const fn (T) bool, config: Config) anyerror!void;            // 新規
pub fn checkWithOrError(gpa: Allocator, comptime T: type, comptime Ctx: type, ctx: Ctx,
             generator: ?GeneratorWith(Ctx, T),
             property: PropertyWith(Ctx, T), config: Config) anyerror!void;          // 新規

// ---- 設定と結果 ----
pub const Config = struct {
    seed: u64 = 0, max_cases: usize = 100, max_discards: usize = 1000,
    shrink_budget: usize = 2000, limits: Limits = .{},
    regressions: []const Regression = &.{}, regression_id: ?[]const u8 = null,
    /// §4.6。*OrError だけが参照する。
    fail_on_stale: bool = false,
};

pub const StaleReason = enum { gen_version_mismatch, fingerprint_mismatch, discarded, unconsumed_suffix };
pub const StaleEntry = struct { index: usize, reason: StaleReason };
pub const RegressionSummary = struct {
    passed: usize,
    /// fingerprint が null で pass したもの（passed にも含む）。
    unverified: usize,
    /// 結果 allocator が所有する。
    stale: []StaleEntry,
};

pub const Origin = union(enum) {
    random: struct { seed: u64, attempt_index: usize },
    regression: struct { index: usize, stale: ?StaleReason },
};

pub const Report = union(enum) {
    passed: Passed,
    failed: Failed,
    gave_up: GaveUp,

    pub const Passed = struct { allocator: Allocator, cases: usize, discards: usize,
                                regressions: RegressionSummary };
    pub const GaveUp = struct { allocator: Allocator, cases: usize, discards: usize,
                                regressions: RegressionSummary };
    pub const Failed = struct {
        allocator: Allocator,
        origin: Origin,
        failure: Failure,
        choices: []Choice,
        shrunk_choices: []Choice,
        fingerprint: Fingerprint,
        original_value: []u8,
        shrunk_value: []u8,
        shrink_evaluations: usize,
        shrink_outcome: ShrinkOutcome,
        regressions: RegressionSummary,

        /// tests/regressions.zon の `.entries` に貼れる1行
        /// （`.{ .id = …, .gen_version = …, .fingerprint = …, .choices = .{…} },`）。
        /// 呼び出し側が所有する。
        pub fn regressionEntry(self: *const Failed, allocator: Allocator, id: []const u8) ![]u8;
    };
    pub fn deinit(self: *Report) void;
};

pub const Choice = struct { bound: u64, value: u64 };   // Report が保持するデータ型として公開を続ける
pub const ShrinkOutcome = enum { fixed_point, budget_exhausted };
pub const Regression, Fingerprint, RegressionFile;      // §4.4
pub const generator_version: u32;                       // M7 で 2
pub const max_depth_cap: usize;
pub fn generate(comptime T: type, gen: *GenContext) anyerror!T;   // = gen.generate(T)。互換のため残す

/// 安定性を保証しない。zigprop 自身のテストと validation のための面。
pub const internal = struct {
    pub const Source = …; pub const GenState = …; pub const deriveSeed = …;
    pub const shrink = …; pub const ShrinkResult = …; pub const Span = …;
    pub const ShrinkPassMask = …;   // アブレーション用（§8 T6/T7）
    pub fn genContextForTest(…) …;  // テストで Source から GenContext を作る
};
```

- 簡易形（`check`、`checkCustom`、`*OrError`）は内部で `checkWith` に変換する。`Ctx = *const fn (T) bool` とし、property は「`ctx(value)` を返すアダプタ」（comptime に決まる関数）、生成器は「Ctx を無視するアダプタ」にする。中核の実行経路は一つになる。
- `*OrError` の失敗時の印字（形式は固定するが、テストで固定はしない）:
  ```
  zigprop: property failed (seed 3, attempt 17)            または (regression #0 "varint")
    failure: returned false                                 または returned error.Foo
    original: …
    shrunk:   … (fixed_point, 41 evaluations)
    regression entry (paste into regressions.zon .entries):
      .{ .id = "varint", .gen_version = 2, .fingerprint = .{ .type_hash = 0x…, .max_len = 0, .max_depth = 0, .custom_generator = false }, .choices = .{ 3, 268435456 } },
  ```
  id は `config.regression_id` を使い、null なら `"<set Config.regression_id>"` を出す。

### 5.3 エラー集合の扱い（エラー名の大域的な interning への対策）

- **property が返したエラーは、名前にかかわらず全て「失敗」である**（`Failure.returned_error`）。`check*` のエラー集合には流さない。名前で分類しない。たとえば property が返した `error.OutOfMemory` も `error.InvalidGeneration` も反例として扱う。名前で分類すると、ユーザーのエラーとライブラリの条件を区別できないからである。SUT の OOM を infrastructure として扱いたい利用者は、property の中で catch する。
- 生成器の `error.InvalidGeneration` → discard。これは既存の契約で、利用者が意図して返す名前である（v2 §4.2）。それ以外の生成器のエラー → `check*` のエラー集合へ伝播する（今と同じ）。この経路では、ライブラリのエラー（`InvalidConfig`、`OutOfMemory`）と生成器のエラーを名前で区別できない。これは既存の問題であり、「読んでいて見つけたもの」F3 に記録した（§10）。
- `*OrError` が返すエラーは `PropertyFailed`、`GaveUp`、`StaleRegression` だけで、どれもライブラリが判定した結果である。property のエラーは印字に含めるが、エラーとしては返さない。→ ユーザーが返したエラーとライブラリ内部の条件が同じ経路を通ることはない。
- shrink の予算制御はこれまでどおりフラグで行い（shrink.zig:153-157）、stale は enum で表す（§4.5）。

### 5.4 失敗の種類と shrink（D27、基盤への変更 F-a）

- P(C) を「C を再生した試行が fail し、**かつその `Failure` が元の失敗と等しい**（同じタグで、`returned_error` ならエラー値も等しい）」と定義し直す。P4 の横移動の受理（shrink.zig:227）にもこの P を使う。
- 理由: shrink の途中で別のバグ（別のエラー）に滑ると、報告される最小例が元の失敗と無関係になる。
- bool だけの property では種類は常に `returned_false` なので、今の挙動と同じである。
- 採らなかった案: (a) どの失敗でも受理する（滑りを許す）。(b) 失敗の種類ごとに別の反例を報告する（複数の反例を報告する機能になり、範囲が広がる）。

### 5.5 表示のスナップショット（I8）

- **方式**: 表示文字列は、失敗が確定した時点の choice 列から、**property を呼ばずに値を再生成して**作る（新しい一時 arena で replay → フォーマット → arena を破棄）。元の値は `fail.choices` から、shrunk 後の値は shrink の終わりの best から作る。shrink 中の候補ごとのフォーマット（shrink.zig:83）はやめる。
- v2 §7 の「表示のために property を再実行しない」は守られる（生成は再実行するが、property は呼ばない）。
- フォーマット: T が struct、union、enum で `format` 宣言を持てば `{f}`、それ以外は `{any}`。`@hasDecl` で comptime に分ける。**0.17.1 の `{f}` / `format` の規約は未確認**で、M0-d で確認する。確認できなければ `{any}` だけにする。
- コスト:
  - 失敗を報告するたびに生成を 2 回余分に行う（試行のたびのコストはない）。
  - カスタム生成器は「同じ draw からは同じ値を作る」決定的な関数でなければならない。これは replay と shrink の前提でもあるので新しい制約ではないが、`GeneratorWith` が Ctx を受け取るようになるので明文化する: **生成器は、property が書き換える Ctx の状態に依存してはならない。**
  - メモリの所有: 表示文字列は `gpa`（結果 allocator）が所有し、`Report.deinit` で解放する。arena の中を参照することはない。
- 採らなかった案:
  - (a) property の前に毎回フォーマットする（全ケースで確保が要り、遅い）。
  - (b) property に `*const T` を渡して変形を禁じる。slice の中身は `@constCast` で書き換えられるので防げない。
  - (c) 文書で禁止するだけにする（それでも README の例は直す）。
- README と examples.zig:55 の例は、入力を複製してからソートする形に直す（M4b）。

### 5.6 公開と内部の線引き

- **公開**: 上の宣言（§5.2）全て。
- **内部（`zigprop.internal`、安定性の保証なし）**: Source とその記録用の配列、`annotatePair`、span、`deriveSeed`、`shrink`、`ShrinkResult`、`GenState`、テスト用の構築関数、パスマスク。
- 効果:
  - カスタム生成器から `annotatePair` を呼べなくなる。これで、レビュー §4 の「`tryRatchet` は他の位置が変わっていないことを確かめていない → 敵対的な注釈で P4 が循環しうる」という理論上の穴が、公開面からは開かなくなる（`internal` を使う利用者は保証の対象外）。
  - `deriveSeed` を内部に移す: seed → 試行の対応は、利用者が直接呼ぶ必要のない実装の仕様である。固定値は source.zig:210-221 のテストで今までどおり固定する。

### 5.7 regressions.zon の実行時パース（D11 の再判定）と自動追記

- **実行時パース: OUT（引き続き）**。
  - 理由 (1): v0.3 で型付きの comptime import（`RegressionFile`）が成立すれば、v2 §7 の「貼って `@import`」の運用は完結する。
  - 理由 (2): 実行時に読むには、テストの実行時の cwd とファイルパスに依存した IO が要る。`zig build test` での cwd は保証されていない。
  - 理由 (3): ファイルを読むテストは、build のキャッシュ（入力が変わらなければテストを再実行しない）と相性が悪い。
  - 取り込む条件: 「失敗したら自動で記録する」という要求が実際の利用者から出ること、かつ build step（例: `zig build zigprop-record`）として設計できること。v0.4 以降の候補。
- **自動追記: OUT**。テストがソースツリーに書き込むことは、上のキャッシュの問題に加えて、CI での再現性を損なう。
- **IN**: 貼り付けられるエントリの印字（`regressionEntry` と `*OrError`）、`RegressionFile` 型、`tests/regressions.zon` を実際に import するテスト（レビュー §5.7 の「どのテストも import していない」を解消する）。

### 5.8 破壊的変更の一覧と移行

| # | 変更 | v0.2 の利用者のコード（前） | v0.3（後） |
|---|---|---|---|
| B1 | GenContext をメソッドだけにする | `ctx.src.range(256)`、`ctx.src.length(n)` | `ctx.range(256)`、`ctx.length(n)` |
| B2 | `zigprop.generate(T, ctx)` は残す | `zigprop.generate(T, ctx)` | 同じ（`ctx.generate(T)` も可） |
| B3 | `Source`、`deriveSeed`、`shrink`、`ShrinkResult` を `internal` へ移す | `zigprop.Source.initReplay(…)` | `zigprop.internal.Source.initReplay(…)`（安定性の保証なし） |
| B4 | Report のフィールド | `r.passed.regressions_passed`、`r.passed.stale_regressions`、`r.failed.seed`、`r.failed.attempt_index`、`r.failed.regression_index` | `r.passed.regressions.passed`、`r.passed.regressions.stale.len`、`r.failed.origin.random.seed` など、`r.failed.origin.regression.index` |
| B5 | 中核が stale を印字しなくなる | stderr に警告が出る | Report を見るか、`*OrError` を使う |
| B6 | `generator_version` が 2 になる | v1 のエントリが再生される | stale（§7）。同じテストを再実行し、印字されたエントリを貼り直す |
| B7 | 表示文字列の作り方 | property の後にフォーマット | 再生成（値の内容は、property が入力を変形しない限り同じ） |
| 互換 | `check`、`checkCustom`、`checkOrError` のシグネチャ、`Config` の既存フィールド、`Limits`、ZON のファイル形式 | — | 不変 |

- **非推奨の互換層は置かず、一度で切り替える（推奨）**。理由:
  - (1) B1 の `ctx.src` を互換のために残すと、隠したい状態をそのまま公開し続けることになり、互換層の目的と矛盾する。
  - (2) B4 は union のペイロードの形の変更で、古いフィールド名を両方持たせると Report の型が二重になる。
  - (3) 利用者が少ない今、移行は機械的な置換で済む。
  - 「v0.3 で API を確定させる」という目標に照らして、これ以上壊れる予定がないことを README に明記する。最終判断は利用者の範囲に関わるので Q1 に回す。
- 移行の例（カスタム生成器。validation/main.zig:139-149 の `genRuns`）:
  ```zig
  // v0.2
  fn genRuns(ctx: *zigprop.GenContext) anyerror![]const Run {
      const n = 1 + ctx.src.length(max_runs - 1);
      … ctx.src.range(256) …
  }
  // v0.3
  fn genRuns(ctx: *zigprop.GenContext) anyerror![]const Run {
      const n = 1 + ctx.length(max_runs - 1);
      … ctx.range(256) …
  }
  ```
- 移行の例（T4 のグローバルバッファ → `checkWith`。§8 T9）:
  ```zig
  fn prop(codec: *const Codec, case: *zigprop.Case, v: Value) !bool {
      const enc = try codec.encodeAlloc(case.allocator, v);
      const dec = try codec.decode(case.allocator, enc);   // エラーは失敗として報告される
      return valueEql(v, dec);
  }
  try zigprop.checkWithOrError(gpa, Value, *const Codec, &codec, null, prop, .{});
  ```

### 5.9 コスト

- 全てのメタテストと validation が `zigprop.internal` に移る（機械的だが diff は数百行）。これを M4a として独立させる。
- `checkWith` は `comptime Ctx` を引数に取るので、利用者のコードがジェネリックになる。エラーメッセージが分かりにくくなる恐れがある（Zig の関数ポインタ型の不一致）。README に完全な例を置く。
- Report の全ての variant に allocator を持たせる（stale の一覧を所有させるため）。`passed` と `gave_up` も `deinit` が必須になる（今も `deinit` は呼ぶ規約だが、呼ばなくても漏れなかった）。
- P(C) に失敗の種類を加えると、shrink で候補が拒否されやすくなり、最小形が今より大きくなる場合がある（同じ種類の範囲での最小になる）。

### 5.10 検証

| 主張 | 証拠 | 種別 | 失敗とみなす結果 |
|---|---|---|---|
| `checkWith` でグローバルなしに T4 相当が書け、結果は同一 | T9（§8）: seed ごとの shrunk choices が T4 と完全に一致 | ゲート | 1 seed でも不一致 |
| property のエラーは失敗であり、check のエラーには流れない | `tests/meta12.zig` "api: property errors are failures, never check errors"（`error.OutOfMemory` と `error.InvalidGeneration` を property から返す） | テストで固定 | check がエラーを返す、または discard になる |
| shrink は失敗の種類を保つ | meta12 "api: shrinking preserves the error kind"（値によって2種類のエラーを返す property） | テストで固定 | 別のエラーで終わる |
| 変形する property でも元の値の表示が正しい | meta12 "display: a mutating property does not corrupt the original"（その場でソートして失敗する property） | テストで固定 | 変形後の表示 |
| 貼れる ZON エントリ | meta12 "workflow: the printed entry round-trips"（`regressionEntry` の出力を、テストに埋め込んだ同じ文字列の ZON として import し、再生すると失敗する。印字形式の固定も兼ねる） | テストで固定 | import できない、再生しても失敗しない |
| `tests/regressions.zon` が `RegressionFile` として読める | meta11 | テストで固定 | コンパイルエラー |
| 公開面に internal が漏れていない | examples.zig は `zigprop.internal` を使わずにコンパイルできる（下流の import の smoke test。examples.zig:1-2 の役目を続ける） | コンパイルで固定 | internal への参照 |
| 中核の実行経路が一つ | 簡易形は `checkWith` のアダプタであること（コードレビュー） | **論証のみ** | — |

---

## 6. stateful testing — OUT（v0.4 で再評価）

### 6.1 判定と理由

**v0.3 では取り込まない。** 理由:

1. **前提となる仕組みがない。** 実用的な stateful testing（コマンドを生成しながら実行し、前提条件はモデルの状態に依存する）には、**property の実行中に draw すること**（Hypothesis の `data.draw` に当たるもの）が要る。v0.3 の生成は property の前に全て終わる。前提条件を「生成器の中でモデルを模擬して判定する」形にすると、モデルを二重に書かせることになる。
2. **shrink の材料がまだ測られていない。** コマンド列を縮めるには要素削除（P5）が効くことが前提だが、P5 は v0.3 で入るもので、T7 で初めて測る。
3. **範囲。** v0.3 はすでに6つの領域を持ち、API の確定（M4）と gen_version の引き上げ（M7）を含む。stateful を足すと、検証できる単位にマイルストーンを分けられなくなる。

### 6.2 v0.4 の目玉にする条件

- (a) v0.3 の `checkWith` と `*Case` が 1 リリースのあいだ変更なしで使われていること。
- (b) T7（slice の要素削除）が v0.3 でゲートを満たし、コマンド列に当たる `[]const union` の削除が実測で効くこと。
- (c) `case.generate(T)`（property の中での draw）の設計が決まっていること。中で引いた値の表示、キー注釈、span、replay の扱いを含む。
- (d) 実際の利用者のシナリオ（状態を持つ SUT）が1件あること。

### 6.3 v0.3 の決定が後の stateful を楽にするか、難しくするか

| v0.3 の決定 | 影響 |
|---|---|
| `Case` を**ポインタ**で渡す（D27） | **楽にする**: v0.4 で `case.generate(T)` や `case.note(…)` を足してもシグネチャが変わらない。値渡しにしていたら破壊的変更になっていた |
| property がエラーを返せ、失敗の種類を保つ | **楽にする**: 不変条件の違反をエラーで表せる |
| Ctx（SUT の手綱）を property に渡す | **楽にする**: 実際の SUT と参照モデルをグローバルなしで渡せる |
| span 注釈と P5/P6 | **楽にする**: コマンドの削除がそのまま使える |
| span を公開 API にしない（§3.7 D） | 中立: v0.4 で対話的な draw の span を内部で扱える余地が残る |
| 表示を再生成で作る（§5.5） | **難しくする可能性**: 対話的な draw の値は T の表示に含まれない。v0.4 では、property の中で引いた値を別に表示する仕組み（draw ログ）が要る |
| 生成器に Ctx を渡す（`GeneratorWith`） | 中立: stateful のモデルは生成器のローカルな状態になる。生成器は property が書き換える状態に依存してはならないという契約（§5.5）は、stateful でも守る必要がある |

（参考: v0.3 の API でも、`[]const Command` を生成し、`checkWith` の property の中でコマンドを SUT とモデルに適用して比べる、という書き方はできる。前提条件を満たさないコマンドは、discard せずに読み飛ばす。これは利用者が自分で書ける形であり、v0.3 の成果物にはしない。）

---

## 7. 互換性とバージョン

### 7.1 何が生成列を変えるか（項目ごと）

| 項目 | random の生成列（seed → 列） | 正規化済み列の replay の意味 | `generator_version` |
|---|---|---|---|
| I2 切断の範囲 | 変える（再帰型のみ） | **変える**（再帰型のみ） | **上げる理由になる** |
| I4 整数 class 2 | 変える（全整数型） | 変えない（§2.5） | 単独では上げない |
| I4 float class 4 | 変える（全 float 型） | 変えない（§2.5） | 単独では上げない |
| I5 span と新しいパス | 変えない（span はメタデータ） | 変えない | 上げない |
| I6 fingerprint、stale | 変えない | 変えない（判定が増えるだけ） | 上げない |
| I7/I8 API、表示 | 変えない | 変えない | 上げない |

### 7.2 一括か段階か

- **一度だけ（M7 で 1 → 2）上げる。** 上げる理由は I2 だけで、I2 は一つのマイルストーンに閉じている。I4 は replay の意味を変えないので段階的に上げる必要がない。
- **M7（I2）を見送った場合、v0.3 は `generator_version = 1` のまま出す。** v1 のエントリは引き続き有効で、seed 互換だけが壊れる。

### 7.3 v1 で記録された regression

- gen_version 不一致として **stale**（再生しない）。`RegressionSummary.stale` に `gen_version_mismatch` として入り、`*OrError` が印字する（§4.5-4.6）。
- **ベストエフォートの再生はしない**。理由は §4.5（値が不明で、pass しても何も保証しない）。
- **移行ツールは作らない**。理由: (a) 正規化済みの非再帰型のエントリは意味上は互換だが（§2.5）、それを型ごとに判定して通すと「gen_version を型ごとに解釈する」規則が生まれる。誤ると黙って別の値を再生することになり、I6 で潰そうとしている失敗そのものになる。(b) 利用者は少なく、再記録は「テストを1回走らせて印字を貼る」だけで済む。
- **v1 生成器の切り替えスイッチは置かない**。2つの生成器を保守するコストに見合わない。

### 7.4 golden replay の固定の拡張（M1。生成を変える前に置く）

2種類に分ける。

- **(R) replay の固定**: 与えた値列 → 生成値、再記録された choice（bound を含む）、keys、skips、消費数。**replay 互換の証拠**。
- **(S) random の固定**: seed → 記録列。**seed 互換の証拠**。変わったら差分をレビューして再記録する。

固定する形状（M1 では全て v0.2.1 の挙動を記録する）:

| 群 | 形状 | 種類 |
|---|---|---|
| 整数（符号なし） | u0, u1, u8, u16, u17, u32, u64 × class 0/1/2/3 | R（各幅・各クラスで1つ以上）、S（各幅1つ） |
| 整数（符号付き） | i1, i8, i16, i17, i32, i64 × class 0/1/2/3（ランクの奇数・偶数の両方） | R、S |
| 境界の幅 | W = 16（class 2 の bound = R）と W = 17（bound < R）の境目、W = 8（class 0 の bound = R） | R |
| float | f16, f32, f64 × class 0/1/2/3。NaN の写像（f32/f64 で負符号と複数のペイロード。レビュー §5.5 の穴を塞ぐ）。±0 | R、S |
| enum | 明示値付き、non-exhaustive | R |
| optional | `?u8` の null と非 null、`??u8` | R |
| 配列 | `[3]u8`、`[0]u8`、`[2][]const u8` | R |
| 入れ子の slice | `[][]const u8`、`[]const ?i16` | R、S |
| struct / union | 既存の2形状（meta5.zig:21-54。S として残す）、void バリアント、非 void バリアント | R、S |
| 再帰（切断） | `Tree` の max_depth = 0/1、`Json` の max_depth = 0、`List`、`Node`、`ZNode`、`Tree2`（非再帰チャネル付き） | R（**M7 で意図して書き換える群**として別ファイルにまとめる） |

- M6（I4）の終了基準: (R) は全て無変更、(S) の整数と float は再記録（差分をレビュー）、再帰型の (S) も再記録。
- M7（I2）の終了基準: 非再帰の (R) は全て無変更、再帰の切断の (R) は書き換え、再帰型の (S) は再記録。
- v1 の再帰切断の固定は M7 で**廃止**する。書き換え前の値は、テストのコメントと verification.md の行に履歴として残す。
- **表示文字列の固定はしない。** v0.2 §0 の「表示文字列を固定」は事実と違うので撤回する（F1）。表示は `{any}` / `{f}` の std の実装に依存し、互換性の面ではない。

### 7.5 `Limits` などのソース互換規則（v0.2 §0 を引き継ぎ、拡張する）

- v0.2 §0 の規則を引き継ぐ: 既定値付きのフィールドを `Limits` に追加することは、フィールド名を指定したリテラルについてはソース互換である。reflection からは新しいフィールドが見える。v0.3 は `Limits` にフィールドを足さない。
- 同じ規則を `Config` と `Regression` にも適用する（`fail_on_stale` と `fingerprint` は既定値付き）。ZON の場合は、既定値付きのフィールドを欠いたエントリが読めることをテストで固定する（§4.8）。
- **Report の variant の集合（`passed` / `failed` / `gave_up`）は v0.3 で凍結する。** variant を足すことは、利用者の網羅的な `switch` を壊すので、破壊的変更として扱う。ペイロード struct へのフィールド追加は互換とする（利用者は Report を構築しない）。

---

## 8. 検証ターゲット（事前登録、v2 §9 / v0.2 §4 の枠組み）

共通条件:
- seed 0〜9、`max_cases = 200`、既定の Limits（target ごとに明記したものを除く）、`shrink_budget = 2000`。
- **発見**（`max_cases` 以内に failed）と**最小性**（shrunk 後の値が登録した最小形と一致）は別々に数える。最小性は発見した seed の中で数え、分母も報告する。
- 各 target に**正しい実装の対照**を置き、同じ条件で 10/10 pass しなければならない。
- 手書きの乱数ループとの比較は、T1〜T4 と同じ形式で併記する（測定のみ）。
- 実行は `zig build validation` で行い、結果は verification.md に行として記録する。

### 8.1 T1〜T4 の扱い

| target | 扱い | 理由 |
|---|---|---|
| T1 varint u32 | **新しい分布で再実行**（ゲートは不変: 発見 ≥ 8 かつ 2^28 一致 ≥ 8） | I4 で class 2 が変わる。最小性はキー順序のうえで不変（キー = ランク） |
| T2 RLE（カスタム生成器） | **再実行**（ゲートは不変） | 生成器は primitive を直接使うので分布は不変。API の移行（B1）と、shrinker の変更（P1b）の影響だけを受ける |
| T3 f32 codec | **新しい分布で再実行**（ゲートは不変: 発見 ≥ 8 かつ非正規数到達 ≥ 8、厳密最小は測定のみ） | I4 で class 4 が増える。v0.2 §4 で記録した「どの経路で縮むかを分離していない」という限界は引き続き残る |
| T4 再帰 union | **再実行**（ゲートは不変） | I2 で切断が変わり、I4 で i64 の分布も変わる。最小形 `list[int 0 ×3]` は切断地点に関わらない（深さ 1）ので、§4 の論証はそのまま成り立つ |

T1〜T4 は各マイルストーン（M2〜M7）の終わりに再実行し、どのマイルストーンで数値が動いたかを記録する。ゲートを下回ったら、そのマイルストーンを差し戻す。

### 8.2 新しいターゲット

**T5 中域 varint（u64、I4）**
- SUT: u64 の LEB128 符号化と復号（最大 10 バイト）。
- mutant（意味を固定）: 復号器は、**符号がちょうど 4 バイトのときに 4 バイト目を無視する**。それ以外の長さは正しく復号する。→ 失敗域は、符号が 4 バイトになる x、つまり x ∈ [2^21, 2^28)。
- 期待する最小反例: **x = 2^21 = 2097152**。根拠: u64 の生成はどのクラスでも組1つで、キー列はちょうど1個（ランク = 値）である。したがって失敗する列のキー列は `[x]`（x ∈ [2^21, 2^28)）であり、shortlex の最小は 2^21 で一意である。
- 予測（事前登録）:
  - v0.3: 1 ケースの発見確率 ≈ 1/4 · 7/65 ≈ 2.7%（幅 22〜28）。200 ケースで約 99.6%。
  - v0.2.1: ≤ 200·2^-38 / seed。
- ゲート（v0.3）: 発見 ≥ 8/10 かつ 2^21 一致 ≥ 8/10。
- 対照: 正しい復号器で 10/10 pass。
- 分離用の対照: **同じ target を v0.2.1 で走らせ（M0-e）、発見 0/10 を予測する**。これで、発見が I4 によるものであることを分離する。0 でなければ §2.1 の算術が誤りなので設計を見直す。
- 測定のみ: 評価回数、P4 が受理された回数。
- 分離していないこと: 最小への到達が、class 2 からの直接の P3 降下によるのか、P4 の後の降下によるのかは区別しない（区別するとも主張しない）。

**T5s 中域 zigzag varint（i64、I4 の符号付き）**
- SUT: i64 → zigzag（protobuf 方式。0→0, −1→1, 1→2 で、zigprop のランクと一致する）→ T5 と同じ LEB128。
- mutant: T5 と同じ。→ 失敗域はランク ∈ [2^21, 2^28)。
- 期待する最小反例: ランク 2^21、すなわち **x = 2^20 = 1048576**（偶数のランクは r/2）。根拠は T5 と同じで、キーが1個、キー = ランクである。
- ゲート、対照、予測は T5 と同じ。

**T5-F float の普通の値（I4、測定のみ）**
- f64 を seed 0〜9 × 200 ケースで生成し、「指数 ∈ [−20, 20] かつ仮数の下位 20 bit ≠ 0」の比率を測る。v0.2.1 と v0.3 で比べる。
- ゲートは置かない。この性質を検出する mutant で、キー順序のうえの最小形を厳密に事前登録できるものを、私は設計できなかった（丸め誤差による失敗の最小ランクは実装依存になる）。

**T6 木の部分木昇格（I5）**
- 型: `Tree = struct { value: i64, kids: []const Tree }`。Limits は `max_len = 4`、`max_depth = 3`。
- 埋め込む故障（意味を固定）: SUT `process(t)` は、**どこかのノードの value が 7 なら**誤った結果を返す。property は `process(t) == reference(t)`。正しい実装は全ての木で一致する。
- 期待する最小反例: `Tree{ .value = 7, .kids = &.{} }`、キー列 `[14, 0]`。根拠:
  - 失敗する木は value 7（ランク 14）のノードを含む。
  - 木のキー列は、ノードを先行順に並べた [ランク, 長さ] の連結である。根は切断されない（初回進入）ので必ず2キーを持ち、切断されたノードは1キーである。
  - よってキー列の長さの最小は 2（根だけの木）で、その場合は根 = 7 かつ長さ 0。`[14, 0]` が一意の最小。
- 予測: ノード数の平均は約 31（kids の長さの平均 2、深さ 3 + 切断の1段）。1 ノードが 7 になる確率は v0.3 で約 1/686（class 0: 1/1024、class 2: 1/2080）。よって 1 ケースあたり約 4.5%、200 ケースではほぼ確実に発見する。**この推定は粗い**（レビューで突いてほしい点 H6）。
- ゲート: 発見 ≥ 8/10 かつ 最小一致 ≥ 8/10。
- 対照: 正しい実装で 10/10 pass。
- 分離用の対照:
  - (a) v0.2.1 での実行（M0-e）。7 が根に出た seed でしか最小にならないと予測し、測定する。
  - (b) v0.3 で **P6 を無効にした**実行（内部のパスマスク）。最小一致の率が下がると予測し、測定する。
  これで、改善が P6 によるものか、P5 / P1b によるものかを分ける。
- 分離していないこと: 発見は I4（class 2 の変化）の影響も受ける。発見率の変化を I5 に帰することはしない（T6 の主張は最小性だけ）。

**T7 slice の要素削除（I5）**
- 型: `[]const u8`、既定の Limits。
- 埋め込む故障: SUT は、**要素に 7 があると**誤った結果を返す。
- 期待する最小反例: `[7]`、キー列 `[1, 7]`。根拠:
  - 失敗には長さ ≥ 1 と、7（ランク 7）の要素が要る。
  - キー列は [長さ, ランク…] で、長さの最小は 2（長さ 1）。そのとき唯一の要素が 7 でなければならない。一意。
- 予測: v0.3 で 1 要素が 7 になる確率は約 0.9%（class 2 の幅 3 を含む）。平均 16 要素なので 1 ケースあたり約 13%。
- ゲート: 発見 ≥ 8/10 かつ `[7]` 一致 ≥ 8/10。
- 対照: 正しい実装で 10/10 pass。
- 分離用の対照: v0.2.1（M0-e。7 が先頭以外にあると `[0, …, 0, 7]` で止まると予測し、測定する）と、P5 を無効にした v0.3。

**T8 stale の検出（I6）**
- この target は**決定的**であり、「発見」と「最小性」は当てはまらない。数えるのは「stale と判定された件数」と「判定されなかった件数」で、10 個のエントリそれぞれに対して行う。
- エントリの作り方: seed 0〜9 について、T1（u32）と T6 の木と `[]const u8`（T7）で失敗させ、`regressionEntry` が出すエントリ（fingerprint 付き）を使う。

| 場合 | 期待 | ゲート |
|---|---|---|
| (a) 同じ設定・同じ mutant で再生 | 失敗として報告される（stale ではない） | 10/10 |
| (b) 同じ設定・**正しい実装**で再生（対照） | passed、stale 0、unverified 0 | 10/10（誤検出 0） |
| (c) `[]const u8` で `max_len` を 32 → 16 | stale（`fingerprint_mismatch`。max_len） | 10/10 |
| (d) u32 で `max_len` を変更 | **stale にならない**（slice を含まないので 0 に正規化される） | 10/10 |
| (e) 木で `max_depth` を 3 → 2 | stale（max_depth） | 10/10 |
| (f) 型の変更: u32 → u64、フィールドの並べ替え、バリアントの追加 | stale（type_hash） | 各 10/10 |
| (g) 型の改名、フィールドの改名 | stale にならない | 各 10/10 |
| (h) エントリの末尾に値を1つ追加し、正しい実装で再生 | stale（`unconsumed_suffix`）で、passed に数えない | 10/10 |
| (i) fingerprint を消したエントリを、正しい実装で再生 | passed、unverified に数える | 10/10 |
| (j) **既知の見逃し**: カスタム生成器の写像を、draw の形を変えずに変更 | stale に**ならない**（見逃しとして固定し、文書化する） | 10/10 見逃す（限界の証拠） |

**T9 現実的な property での新 API（I7）**
- T4 と同じ型、同じ mutant（リストを 2 要素に切り詰める）、同じ seed。property は `checkWith` で書く。Ctx は codec の設定、符号化と復号は `case.allocator` を使い、グローバルバッファは使わない。
- ゲート:
  - (1) 発見 ≥ 8/10 かつ構造一致 ≥ 8/10（T4 と同じ）。
  - (2) **seed ごとの shrunk choices が T4 と完全に一致**する。生成器も述語も同じなので、API の経路だけを分離できる。不一致なら API の層が挙動を変えたことになる。
  - (3) gpa として `std.heap.DebugAllocator` を使い、リークが 0（T4 の対照も同様）。
  - (4) validation のファイルに T9 用のコンテナレベルの `var` バッファがない（コードレビュー）。
- **T9e（エラー経路）**: mutant の復号器は、3 要素以上のリストで `error.UnexpectedLength` を返す。失敗域は T4 と同じで、期待する最小形も同じ `list[int 0 ×3]`。`Failure = returned_error(UnexpectedLength)` で報告されること、shrink の全ての受理でこの種類が保たれること（§3.9 の内部フック）をゲートにする。
- 対照: 正しい codec で 10/10 pass、リーク 0。
- 分離していないこと: T9e の発見は T4 と同じ生成に依存するので、新しい情報は「エラー経路と種類の保存」だけである。

**stateful の target**: OUT のため置かない。

### 8.3 ゲートと測定のみの区別

- ゲート: T1〜T4（既存の基準）、T5、T5s、T6、T7、T8 の各行、T9、T9e。
- 測定のみ: 評価回数、P4 の受理回数、T5-F、T6/T7 のアブレーションと v0.2.1 の値、T4 の discard 数（I2 の影響）、span によるベンチのオーバーヘッド、多経路の型のコンパイル時間。

---

## 9. マイルストーン

原則:
- 生成を変えない作業を先に、変える作業を後に置く。
- 生成を変える作業は、random だけを変えるもの（M6）と replay を変えるもの（M7）に分ける。
- 各マイルストーンの終わりに `zig build test` と `zig build validation` を実行し、T1〜T4 の数値を記録する。

| M | 範囲 | 触るファイル | 追加するテスト | 終了基準 | **含まないもの** | 見送れるか |
|---|---|---|---|---|---|---|
| **M0** 事前実験（リポジトリの外、`/tmp` などで） | (z) ベースラインの記録: v0.2.1 で `zig build test --summary all`（89 件の予定）と `zig build validation`（T1〜T4）。(a) `reaches` と新しい切断の comptime 実装で meta8 の型がコンパイルできるか、そのコンパイル時間。(b) 再帰型の構造ハッシュ（後方参照）が comptime で書けるか、必要な branch quota。(c) 任意フィールドに既定値を持つ ZON を `RegressionFile` に `@import` できるか。(d) `@hasDecl(T, "format")` と `{f}` の挙動。(e) T5/T5s/T6/T7 を v0.2.1 で実行して基準値を取る | なし（スクラッチ） | — | 結果を研究ノートに記録する。(a)〜(c) のどれかが不可なら、該当する決定（D12, D23, D31）を改訂してからレビューに戻す | 実装 | 見送れない |
| **M1** golden の拡張 | §7.4 の (R) と (S) を全て追加（v0.2.1 の挙動を記録）。v0.2 §0 の表示文字列に関する記述を撤回 | tests/meta10.zig（新）、docs/design-v0.2.md の1行 | 約 60 件の固定（ファイル数は少なくする） | v0.2.1 の src のまま全て pass | src の変更 | 見送れない |
| **M2** span の記録 | Source に span を追加し、gen が記録し、AttemptResult と shrink の best が span を持つ。パスは使わない | src/source.zig, gen.zig, shrink.zig | meta9 "spans: …" | **M1 の固定（R と S）が全て無変更**。meta3 の評価回数が無変更 | 新しいパス | M3 と一緒に見送れる |
| **M3** 新しいパス | P6, P5, P1b、予算切れ後の早期脱出、巡の構成（§3.2）。meta7 の期待値の変更 | src/shrink.zig, tests/meta7.zig | meta9 の shrink 系、meta7 の書き換え、内部のパスマスク | T6, T7 のゲート、T1〜T4 の維持、meta3 は無変更で pass | 生成の変更 | P6 と P5 は別々に見送れる（T6 / T7 も対応して取り下げ） |
| **M4a** 内部名前空間 | `zigprop.internal`、GenContext のメソッド化、テストと validation の機械的な移行 | src/root.zig, source.zig, 全ての tests, validation | — | 全テストが pass（挙動の変化なし）、M1 の固定は無変更、examples.zig が internal を使わない | 新しい入口 | 見送れない（M4b, M5 の前提） |
| **M4b** 新しい API | `checkWith`、`Case`、`Failure` と P(C) の種類、名前付きの Report 型と Origin、表示の再生成、`*OrError` 3種、`regressionEntry`、`RegressionFile`、README の例の修正 | src/runner.zig, shrink.zig, root.zig, README.md, tests/examples.zig | meta12、`regressions.zon` の import テスト | T9, T9e のゲート、M1 の固定は無変更 | fingerprint | 見送れるが、v0.3 の目的（API の確定）を失う |
| **M5** fingerprint と stale | 構造ハッシュ、関連 Limits の正規化、stale の判定表（§4.5）、中核からの印字の撤去、`fail_on_stale` | src/runner.zig、新しい src/fingerprint.zig | meta11 | T8 の全行、M1 の固定は無変更 | 生成の変更 | 独立して見送れる（T8 を取り下げ） |
| **M6** 分布（random のみ） | 整数 class 2 の対数一様、float class 4、Source の内部 primitive | src/gen.zig, source.zig | meta10 の分布と P4 のテスト | **(R) が全て無変更**、(S) を差分レビューのうえ再記録、固定 seed に依存するテスト（§2.6）を再検証、T5/T5s のゲート、T1〜T4 の維持 | replay の意味の変更、gen_version の変更 | 独立して見送れる（T5/T5s を取り下げ） |
| **M7** 切断の範囲と gen_version 2 | `reaches`、`admissible`、`cutRel`、post-limit、`generator_version = 2` | src/gen.zig, tests/meta8.zig, meta9 | meta9 の切断系、一致テスト | **非再帰の (R) が無変更**、再帰の切断の (R) を書き換え、meta8 のコンパイル時間を記録、T4 の維持 | 他の生成の変更 | 独立して見送れる（gen_version は 1 のまま。§7.2） |
| **M8** 記録と文書 | verification.md の行の追加と修正、README、この設計の vendoring、最終的な validation の記録 | docs/, README.md | — | §8 の全ゲートを記録し、verification.md の新しい行（§11）を入れる | コードの変更 | 見送れない |

依存関係: M1 → M2 → M3。M1 → M4a → M4b → M5。M1 → M6。M1 → M7（M5 の後が望ましい。stale の仕組みがあれば、v1 エントリの stale が Report に出る）。M3 と M6 と M7 は互いに独立なので、T1〜T4 の変化をマイルストーンごとに切り分けられる。

各マイルストーンの大きさの見込み: M2 は約 150 行、M3 は約 300 行、M4a は機械的な数百行、M4b は約 400 行、M5 は約 300 行、M6 は約 150 行、M7 は約 250 行。M4a は機械的だが大きいので、テストファイル単位でコミットを分ける。

---

## 10. 読んでいて見つけたもの（範囲外。決定には含めない）

| # | 内容 | 根拠 | 重大度 | 推奨 |
|---|---|---|---|---|
| F1 | v0.2 §0 は golden テストが「表示文字列」も固定すると書くが、固定していない | design-v0.2.md:17、meta5.zig:15-19（choices、keys、skips だけ） | 低（文書の誇張） | M1 で撤回する（§7.4。golden の拡張そのものは v0.3 の範囲内） |
| F2 | 固定 seed で走査して決めた期待値（「seed 0 の最初の3ケースは pass」）は、分布の変更で黙って壊れる | meta5.zig:236-237 | 低 | M6 で再走査し、可能なら regression エントリで書き直す（§2.6。I4 のコストとして扱う） |
| F3 | カスタム生成器が返すエラーは `check` のエラー集合に流れ、ライブラリのエラー（`InvalidConfig` など）と名前で区別できない | shrink.zig:61-66、runner.zig:207, 246 | 中（I7 の精神に反する） | v0.3 では文書化だけ。v0.4 で `Report` に生成器のエラーの variant を足すかを検討する（variant の追加は §7.5 の規則で破壊的変更になる。Q4） |
| F4 | `build.zig.zon` の `.paths` に `validation` がない一方、`build.zig` は `validation/main.zig` の実行ファイルを宣言している。テンプレートのコメントも残っている | build.zig.zon:71-83、build.zig:58-66 | 低（利用者側で壊れるかは未確認） | M8 で `.paths` を整理する（Q4） |
| F5 | CI の `zig fmt --check` は validation を対象にしていない | ci.yml:26 | 低 | M8 で `validation` を加える（Q4） |
| F6 | `struct { x: void }` のフィールドはコンパイルエラーだが、union の void ペイロードは受け付ける | gen.zig:137-194（`.void` の分岐がない）、gen.zig:576 | 低 | 対象外。v0.4 で対応するか、文書化する |
| F7 | `index(0)` は draws を増やさずに記録する | source.zig:190-195 | 極低（sticky error なので無害） | 対象外 |
| F8 | 巨大な `max_len`（例: 2^40）は InvalidConfig ではなく OOM になる | runner.zig:175 | 低 | 対象外（Q4 の小修正群に入れてもよい） |

---

## 11. verification.md に追加する予定の行

| # | 性質 | 証拠（予定） | 種別 |
|---|---|---|---|
| 24 | golden の拡張: 全ての形状の replay と random の固定 | tests/meta10.zig（M1） | テストで固定 |
| 25 | span の記録は choice、キー、skip を変えない。span の形 | M2 の終了基準、meta9 | テストで固定 |
| 26 | P5/P6/P1b は通常受理だけを使う。meta7 の木 → `{7,[]}`、slice → `[7]` | meta7、meta9、受理の単調性フック | テストで固定。停止は**論証のみ**（§3.4） |
| 27 | T6/T7 | validation | ゲート。アブレーションは測定のみ |
| 28 | `checkWith`、失敗の種類、エラー経路の分離、表示の再生成、貼れるエントリ、`RegressionFile` | meta12、meta11、T9/T9e | テストで固定、ゲート |
| 29 | fingerprint と stale の判定表、既知の見逃し | meta11、T8 | テストで固定、ゲート |
| 30 | 対数一様と class 4 の意味（R）とサンプリング。I4 は replay を変えない | meta10、M6 の終了基準 | テストで固定 |
| 31 | T5/T5s（と v0.2.1 の基準値）、T5-F | validation | ゲート、測定 |
| 32 | 切断の範囲: 一致テスト、非再帰チャネル、tag の draw、有界性 | meta9 | テストで固定。生成の停止と comptime の停止は**論証のみ**（§1.3） |
| 33 | gen_version 2 と v1 エントリの stale | meta11、meta2 の書き換え | テストで固定 |

修正する既存の行:
- 行 16: P4 の例外を本文に統合し、「厳密な減少だけ」という表現をやめる。
- 行 21: 「max_depth = 0 は全ての再帰の出現を切断する」の意味を、v0.3 の切断形に合わせて書き直す。

既知の欠落の節に追加する: 「v0.3 の新しいパスの停止と、切断形の生成の停止は論証のみ」と「構造ハッシュはカスタム生成器の変更と、形が同じままの意味の変更を検出しない（T8 (j)）」。

### Lean / TLA+ への影響

- **Lean（normalize、zigzag、shortlex）: 変更なし。**
  - 正規化（`% bound`）、zigzag によるランク、キーの比較はどれも変えない。
  - I4 は random モードのサンプリングだけを変え、Lean はサンプリングをモデル化していない。
  - shortlex の整礎性が未証明であることは既存の既知の欠落のままで、v0.3 の停止の論証もこの欠落に依存する（§3.4）。
  - 追加を検討するもの（任意）: shortlex の整礎性の証明（`List Nat` で長さを先に比べる順序。Mathlib なしで書ける見込み）。v0.3 の範囲には入れない。
- **TLA+（ZigpropRunner.tla）: 構造の変更なし。抽象化はそのまま当てはまる。**
  - 新しいパス（P5/P6/P1b）の受理は、どれも `ShrinkAccept`（`r < best` かつ `r ∈ Failing`）の具体例であり、モデルの範囲に入る。P4 の横移動はもともとモデル化されておらず、既知の欠落のままである。
  - 失敗の種類（D27）は、元の失敗の種類 k に対して `Failing := Failing_k` と読み替えれば、定数の集合のままである。
  - stale（§4.5）は観測上「regression が失敗しなかった」なので、`RegressionPass` に含まれる。stale の数え方はモデル化しない（モデルは数を持たない）。
  - 再検査は不要だが、ファイル冒頭のコメントに「v0.3 のパスは ShrinkAccept の具体例、stale は RegressionPass に吸収」と一行足す（M8）。

---

## 12. 決定の一覧（D12〜）

| id | 論点 | 決定 | 根拠（一行） | 依存 |
|---|---|---|---|---|
| D12 | I2 切断の範囲 | **IN**: R に到達するチャネルだけを切断し、他は post-limit（∅, cap）で通常生成する | 補題により判定は経路に依存せず、生成も comptime 展開も有界になる | — |
| D13 | 切断地点の union | **IN**: 許容バリアントが m ≥ 2 なら `index(m)` を draw、m = 1 なら draw なし。許容バリアントの判定は一つの関数にする | `str` の葉を切断地点に出し、I1 型の不一致を構成で防ぐ | D12 |
| D14 | I4 整数 | **IN**: class 2 を対数一様に置き換える（bound R、値 = ランク、組の形は不変、class draw は `range(4)`） | 組の形と P4 を変えずに中域を埋め、正規化済み列の replay を変えない | — |
| D15 | I4 float | **IN**: class 4（中程度の大きさ）を追加し、class draw を `range(5)` にする。正規形は class 3 | 普通の値を出す。class 0〜3 と P4 は変えない | — |
| D16 | `generator_version` の意味 | **IN**: replay の意味（正規化済み列）だけを追う。seed 互換はバージョン間で約束しない | I4 が上げずに済む根拠になり、互換の対象を明確にする | D14, D15 |
| D17 | P1 のサイズ | **PARTIAL**: 2 の冪は今のまま。{3,5,6,7} は不動点の直前だけで走る P1b にする | 不動点の近傍を広げつつ、通常の巡のコストを抑える | — |
| D18 | span 注釈 | **IN**: Source が span をメタデータとして記録する。順序にも受理にも入れない。内部のみ | P5/P6 に構造が要り、健全性は受理規則だけで保たれる | — |
| D19 | P5 要素削除 | **IN**（長さ draw を v−1 にして要素 span を除く） | `[0,7]` で止まる問題を解く | D18 |
| D20 | P6 部分木昇格 | **IN**（最も近い同じ型の子の出現で親を置き換える。1段ずつ） | meta7 の非最小を解き、候補数は線形に収まる | D18 |
| D21 | 契約として固定する範囲 | **IN**: 最小形は値とキー列で固定し、生の choice は測定のみ | パスの順序や P4 の有無で変わる表現を契約にしない | D19, D20 |
| D22 | 巡の構成と予算 | **IN**: P6→P5→P1→P4→P2→P3（+P1b）。既定の予算 2000 は不変。flag による制御を維持 | 大きく縮むパスを先に置く。meta3 の固定を壊さない | D17, D19, D20 |
| D23 | fingerprint の中身 | **IN**: 構造ハッシュ + max_len（slice に到達する場合）+ max_depth（再帰型の場合）+ カスタム生成器のフラグ。カスタム生成器では Limits を正規化しない | 生成に影響するものを全て含め、無害な変更では stale にしない | D12 |
| D24 | stale の判定と扱い | **IN**: §4.5 の表（バージョンか fingerprint が不一致なら再生しない。suffix、枯渇、discard は stale。失敗は常に失敗として報告。fingerprint が null なら unverified） | 黙った誤った pass を無くし、本物の反例は隠さない | D23 |
| D25 | stale の方針 | **IN**: Report に必ず記録し、`*OrError` が印字する。`fail_on_stale` の既定は false（Q2） | アップグレード時に全利用者のテストが落ちるのを避ける | D24, D34 |
| D26 | 印字の責任 | **IN**: 中核は印字しない。`*OrError` だけが `std.debug.print` を使う | ライブラリとして埋め込めるようにし、テストでの使いやすさはラッパーに任せる | — |
| D27 | property の API と P(C) | **IN**: `checkWith(…, Ctx, ctx, ?GeneratorWith, PropertyWith, config)`、`*Case`、`anyerror!bool`、`Failure`。P(C) は同じ種類の失敗。property のエラーは名前によらず全て失敗 | 文脈・allocator・エラーを持たせつつ、エラー名の interning による取り違えを経路の分離で防ぐ | — |
| D28 | 公開と内部 | **IN**: GenContext はメソッドだけ。Source、deriveSeed、shrink、span は `zigprop.internal` | 内部を誤用できる経路を塞ぎ、P4 の理論上の穴を公開面から消す | D27 |
| D29 | Report の型 | **IN**: 名前付きのペイロード型、`Origin`、`RegressionSummary`、variant の集合を凍結 | regression による失敗の誤った seed 表示を直し、型を参照できるようにする | D24, D27 |
| D30 | 表示 | **IN**: 確定した choice 列から property を呼ばずに再生成してフォーマットする。format 宣言があれば `{f}`（M0-d で確認） | 変形する property でも正しく、試行ごとのコストはゼロ | D27 |
| D31 | ZON のワークフロー | **IN**: `regressionEntry` と貼れる印字、型付きの `RegressionFile` の import テスト。**実行時パースは OUT、自動追記も OUT** | v2 §7 の運用を comptime で完結させ、build のキャッシュと IO の問題を避ける | D23, D29 |
| D32 | 破壊的変更の進め方 | **IN**: 互換層なしで一度に切り替える。check / checkCustom / checkOrError のシグネチャは保つ（Q1） | 互換層は隠したい状態を公開し続け、目的と矛盾する | D27〜D29 |
| D33 | stateful | **OUT**（v0.4 で再評価。条件は §6.2）。`*Case` で将来の拡張を確保する | 対話的な draw という前提がなく、v0.3 の範囲がすでに大きい | D27 |
| D34 | v1 のエントリ | **IN**: stale（再生しない）。移行ツールなし、v1 生成器のスイッチなし、v1 の再帰切断の固定は廃止 | 型ごとの互換判定は I6 が潰そうとしている黙った誤りを再び招く | D16, D12 |
| D35 | golden の固定 | **IN**: (R) replay と (S) random の2種類を M1 で全形状について置く。表示の固定はせず、v0.2 の記述を撤回 | 生成を変える前に、replay と seed の互換を別々に検査できるようにする | — |
| D36 | ソース互換の規則 | **IN**: v0.2 §0 を引き継ぎ、Config と Regression にも適用する。Report の variant を凍結 | 拡張できる場所とできない場所を明示する | D29 |
| D37 | T1〜T4 | **IN**: v0.3 の各マイルストーンで、ゲートを変えずに再実行する（T1/T3/T4 は新しい分布、T2 は分布不変） | 既存の主張が退行しないことを、マイルストーンごとに帰属させて確認する | D14, D15, D12 |

集計: IN 24（D12〜D16, D18〜D32, D34〜D37）/ PARTIAL 1（D17）/ OUT 1（D33）。実行時パースと自動追記の OUT は D31 の中に含む。

---

## 13. ユーザーに決めてほしいこと

1. **Q1: 破壊的変更は一度に入れてよいか（互換層なし）？**
   - 推奨: 一度に入れる（D32）。check / checkCustom / checkOrError を使うだけの利用者は壊れない。壊れるのはカスタム生成器（`ctx.src.` → `ctx.`）、Source を直接使うコード、Report のフィールド名である。
   - 反対の場合: v0.3 では `GenContext.src` と Report の旧フィールドを非推奨として1版だけ残す。その間は `annotatePair` の経路が開いたままなので、D28 の効果は v0.4 まで遅れる。
2. **Q2: stale を既定でテスト失敗にするか？**
   - 推奨: v0.3 では `fail_on_stale = false`（報告と印字だけ）にし、v0.4 で既定を true にするかを再検討する。
   - 反対の場合: v0.3 にアップグレードした時点で、v1 のエントリを持つ全てのテストが `error.StaleRegression` で落ちる。再記録を強制できるが、移行の手間が一度に来る。
3. **Q3: v0.3 で gen_version を 2 に上げてよいか（I2 の範囲）？**
   - 推奨: 上げる（M7 を含める）。切断地点の不自然な値（`str` が出ない、`name = ""` 固定）は再帰型のテストの質を直接下げている。
   - 反対の場合: M7 を見送ると、v0.3 は gen_version 1 のまま出せ、記録済みのエントリが全て有効なまま残る（§7.2）。I2 は v0.4 に回る。
4. **Q4: 読んでいて見つけた小さな修正（F3 の文書化、F4 の `.paths`、F5 の fmt、F8）を v0.3 の M8 に含めるか、別のパッチにするか？**
   - 推奨: F4、F5 は M8 に含める（コードの挙動を変えない衛生作業）。F3 と F8 は文書化だけにする。
   - 反対の場合: 別パッチにすれば、v0.3 の diff はレビュー対象の決定だけになる。
5. **Q5: 汎用の入口の名前。**
   - 推奨: `checkWith`。`forAll` は D3 のとおり予約のままにする。
   - 反対の場合（`forAll` を今使う）: v0.4 の stateful や対話的な draw の入口に使える名前が一つ減る。好みの問題なので、ユーザーに委ねる。

---

## 14. レビューで最初に突いてほしい点

- **H1（§1.3）**: 補題「Set に到達 ⇔ R に到達」と、post-limit（∅, cap）が挙動を変えないという主張（特に `depth ≥ n` の不変条件と、カスタム生成器が `generate` を呼ぶ場合）。ここが誤っていると、切断地点で実行時の再帰が止まらない。
- **H2（§2.5）**: 「正規化済みの v1 列は I4 の後も同じ値に replay される」。これが I4 単独では gen_version を上げないことの根拠である。正規化されていない値を記録しうる経路を、私が見落としていないか。
- **H3（§3.4）**: 新しいパスが `tryAccept` 以外で best を置き換えないこと、span が誤っても健全性が崩れないこと。P5 の候補で、0 埋めが起きたときに再記録された列が予想外に長くならないか（長くなるならキー列も長くなり、受理されないだけのはず）。
- **H4（§4.3）**: 構造ハッシュが Zig 0.17.1 の comptime で、再帰型について現実的な時間で計算できるか（未確認。M0-b）。直列化の定義に、生成の形に影響するのに含めていない要素（例: packed struct、extern struct、`align`）がないか。
- **H5（§5.4）**: P(C) に失敗の種類を加えたとき、P4 の横移動（種類が同じであることも要求する）と組み合わせても、測度の議論が崩れないか。
- **H6（§8 T6）**: 発見確率の見積もり（約 4.5%/ケース）が粗い。ゲートの 8/10 が現実的かを、M0-e の v0.2.1 の値と合わせて疑ってほしい。
- **H7（§5.5）**: `GeneratorWith` が Ctx を受け取る場合、表示の再生成と shrink の決定性が「生成器は property が書き換える状態に依存しない」という契約だけに頼っている。この契約を検出できないまま許容してよいか。
- **H8（レビュー主張の再確認、付録 A）**: 私の判定（特に「stale」と判定したもの）が、実行で確かめていない読解にもとづいていること。

---

## 付録 A. レビュー主張の再確認（v0.2.1 時点）

| レビューの主張 | v0.2.1 での状態 | 根拠 |
|---|---|---|
| C1 多経路の再帰で comptime が爆発する | **修正済み**（読解で確認。コンパイルは実行していない） | gen.zig:34-45, 65-119（正準集合 + n）、meta8.zig:15-32, 92-166 |
| I1 `cutExists(void)` が偽、`[0]X` | **修正済み** | gen.zig:214, 217, 279-281、meta8.zig:172-217 |
| I2 切断で非再帰チャネルも消える | **残っている**。加えて、union の切断は tag を draw しない（レビューに無かった細部） | gen.zig:240, 250-260, 273-286 |
| I3 float の class-0 regression のテストが空疎 | **修正済み**（index 31、`regression_index` を確認） | meta5.zig:210-229 |
| I4 中域の算術 | **確認**（数値はレビューと一致）。ただし「2^28 は u32 の上位 1/16」は不正確（失敗域は 15/16）。穴は W > 16 だけ | gen.zig:356-368、§2.1 |
| I5 P1 は 2 の冪だけ、要素と長さの同時削除がない、meta7 の非最小 | **残っている** | shrink.zig:250-272、meta7.zig:154-179 |
| I6 replay が Limits と suffix を見ない | **残っている** | source.zig:176、gen.zig:166, 128-131、runner.zig:198-215、meta.zig:102-114 |
| I7 API（文脈がない、checkCustomOrError がない、ZON を印字しない、Source の内部を公開、無名の Report、debug.print） | **残っている**。加えて `shrink` / `ShrinkResult` / `deriveSeed` も公開されている | runner.zig:89-132, 46-74, 195, 212、root.zig:12-13, 19-20、source.zig:70-78, 136-143 |
| I8 表示は property の後に作られ、README は入力を変形する | **残っている**（examples.zig:55 も同じ） | shrink.zig:76, 83、README.md:28-33 |
| §4 `tryRatchet` は他の位置を確かめない | 残っている（D28 で公開面からは塞ぐ） | shrink.zig:228-232 |
| §4 予算切れの後も候補を作り続ける | 残っている（M3 で直す） | shrink.zig:209, 257-260, 280, 303 |
| §4 相互再帰では一巡ごとに深さを 2 使う、`max_depth = 0` でも根の kids は生成する | 挙動は残っている。README には説明がない | gen.zig:123-136、meta7.zig:61-64 |
| §4 `index(0)` が draws を増やさない | 残っている（F7） | source.zig:190-195 |
| §4 `max_cases = 0` | **修正済み** | runner.zig:184、meta2.zig:233-236 |
| §4 巨大な `max_len` が OOM になる | 残っている（F8） | runner.zig:175 |
| §4 regression による失敗が seed と attempt 0 を報告する | 残っている（D29 の `Origin` で直す） | runner.zig:214 |
| §4 `struct{ x: void }` がコンパイルエラー | 残っている（F6） | gen.zig:137-194 |
| §4 CI が validation をビルドしない | **古い（もう当てはまらない）**: CI は `zig build validation` を実行している。fmt の対象外であることは残っている | ci.yml:29-30, 26 |
| §4 build.zig:67 の説明が「T1, T2」のまま | **古い**: T1〜T4 を挙げている | build.zig:67 |
| §4 build.zig.zon のテンプレートと `.paths` | 残っている（F4） | build.zig.zon:1-84 |
| §4 README のテスト数 54、使い方に float と union がない | **修正済み**（89。静的に数えて一致）、使い方も修正済み | README.md:41-45, 52 |
| §4 f16 の class 3 で ±∞ が約 5% | おおむね確認: class 3 の NaN → ∞ が 2046/65536 × 1/4 ≈ 0.8%、境界クラスが 2/14 × 1/4 ≈ 3.6%、計 ≈ 4.4% | gen.zig:401-410, 466-495 |
| §5.1 行 21 は多経路のコンパイルを主張していない | **修正済み**（行 21 は meta8 を引用している） | verification.md:35 |
| §5.2 行 19 | **修正済み** | verification.md:33 |
| §5.3 T3 は登録した仮説（P3 の降下）を検証していない | **部分的に修正**: 行 22 と v0.2 §4 に「経路を分離していない」と追記された。T3 の設計自体は変わっていない | verification.md:36、design-v0.2.md:116 |
| §5.4 golden は表示を固定しておらず、形状は2つだけ | **残っている**（F1、M1 で解消） | meta5.zig:15-54、design-v0.2.md:17 |
| §5.5 f32/f64 の NaN のペイロードが1つだけ、float の P4 のテストがない | 残っている（M1 と M6 で解消） | meta5.zig:149 |
| §5.6 行 16 が P4 で更新されていない | **部分的に修正**（行の末尾に P4 の例外を追記） | verification.md:30 |
| §5.7 `regressions.zon` を誰も import しない | 残っている（D31 で解消） | grep の結果: tests/、src/、validation/ に import なし |
| §5.8 README の「全ての設計主張を対応づける」 | 残っている | README.md:18-20 |
| §5.9 verification.md の表の構造 | **修正済み**（行 1〜23 が一つの表になった） | verification.md:13-37 |

---

## Amendments

### A1 (2026-11-19, directing decision after the M0/M1 implementation report)

§7.4 and the M6 exit criterion say the replay pins stay unchanged, but
replay pins record each draw's bound, and D14/D15 intentionally change
two distributions: the integer class-2 draw's bound (65536 → R) and the
float class draw's bound (range(4) → range(5)). Those pins therefore
cannot stay literally unchanged. Resolution: at M6, the affected pins
are updated with **only the bound fields changed** — values, keys,
skips and consumed counts must stay identical, and this is verified
mechanically (a diff of the pin files may touch nothing but the bound
of a class draw whose distribution D14 or D15 changes). Every other
pin stays byte-identical. This matches D16: `generator_version` tracks
the replay meaning of normalized sequences, and a bound change with
the same normalized value is exactly a distribution change, not a
meaning change.

### A2 (2026-11-19, recorded from the M0 measurements)

T7's pre-registered prediction was wrong on the v0.2.1 baseline:
v0.2.1 already shrinks T7 to `[7]` in 8/10 seeds, so T7's gate does
not discriminate v0.3 from v0.2.1 on those seeds. The target and its
gate stay as registered (no post-hoc goalpost moves); the baseline is
recorded honestly in verification.md and the M3 report.
