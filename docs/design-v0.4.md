# zigprop v0.4 設計（確定版、2026-11-22）

状態: **確定**。§9 の Q1〜Q6 は 2026-11-22 にユーザーが全て設計者の推奨どおりに確定した（Q1: 目玉は対話的な draw、モデルベーステストはレシピ。Q2: in-repo の SlotMap で進め、(d) 未充足を明記。Q3: `case.reject()` は入れない。Q4: D48 の再現確認を受け入れる。Q5: `property_version` は入れない。Q6: Nat↔u64 ブリッジは v0.4 に入れない）。
拡張元: `zigprop/docs/design-v0.3.md`（以下「v0.3 §n」、決定は D12〜D37）。決定番号は D38 から、検証ターゲットは T10 から続ける。
基準バージョン: **v0.3.1**（`eb37a0a`、リリース済み、`generator_version = 2`）。作業ツリーの HEAD は `4e9e6f9`（v0.3.1 の後に lint と文書の修正 3 件）。
入力: ブリーフ `research_notes/zigprop-v0.4-design-brief-by-sonnet-2026-11-21.md`。

改訂履歴:
- v1 (2026-11-21): 初版。

### この文書の検証状況（最初に読むこと）

- **実行したもの**: `git log --oneline`、`git tag`、`git diff --stat v0.3.0 v0.3.1 -- src tests/api_surface.zig`、`git diff --stat v0.3.1 HEAD -- src tests validation`（出力なし）、`git diff v0.3.0 v0.3.1 -- src`（全文を読んだ）、`ls` と `grep`。どれも読み取りだけである。
- **実行できなかったもの**: `gh run list`（承認が必要で拒否された）。したがって GitHub Actions 上の nightly の結果は見ていない。
- **実行しなかったもの**: `zig`（build、test、validation のどれも）、`lake`、TLC。ブリーフの制約（リポジトリを変えない、書くのはこの文書だけ）により、スクラッチでの試作もしていない。**この文書の予測はすべて、コードを読んで立てた算術と推論であり、実行による確認は一つもない。**
- 現状のコードに関する記述には `file:line` を付けた。行番号は HEAD `4e9e6f9` で読んだものである（`src/` は v0.3.1 から変わっていない。上の diff --stat が空だった）。
- 主張には v0.3 と同じ 4 つの種別を付ける: **テストで固定**、**ゲート**、**測定のみ**、**論証のみ**。この文書の中の主張の大半は、まだ存在しないテストやゲートを予定するものなので「(予定)」を付ける。
- 私が書いたファイルはこの文書だけである。

---

## 0. 要約

- **判定**: 「stateful testing のフレームワーク」を v0.4 の目玉にする条件は**揃っていない**（§1）。(d) は満たされておらず、(a) は形式上だけ満たされている。(b) の前提「P5 がコマンド列を縮める」は、推奨する書き方（各ステップで検査して即座に返す）については**誤りと予測する**。P5 が必要になるのは判定が列の末尾に依存する場合だけである（§1.2、T14）。
- **提案**: v0.4 の目玉は**対話的な draw**（`case.generate(T)` と、そのための小さな primitive）にする。モデルベーステストはその最初の用途とし、README のレシピと in-repo のシナリオ（T10）で示す。comptime のコマンド interface を持つフレームワークは OUT とする（D53）。
- **正直に書いておく発見**: v0.3 でも「`[]const Command` を先に生成し、property の中で『生きているハンドルの `idx % n` 番目』と解釈する」書き方（以下 **B2**）はできる。T10 では、B2 の発見率と最小キー列は v0.4 と**同じ**になると予測する（§4 T10）。v0.4 の対話的な draw が B2 に対して加えるのは、発見力ではなく次の4つである。
  - (1) 素直な書き方（盲目的な生成、**B1**）がほぼ 0 になる落とし穴を、利用者が知らなくても避けられる。
  - (2) 記録される choice が状態に依存する bound を持つので、replay の正規化（`% bound`）と shrink のキーが、利用者の書く `%` ではなくライブラリの規則で決まる。
  - (3) 実行されたものだけを、実行された順に表示できる。
  - (4) 固定のプールなしに、状態に依存する数と型の draw ができる。
  v0.4 の目玉はこの範囲の主張に限るべきである。
- **(b) を強める方法**: 現在のツリー（v0.3.1）のまま M0 で測れるターゲット T14 を置く。P5 を切った shrinker は、発見したケースの最初の 7 の位置 f について、f 個の 0 要素の後に 7 が続く形で必ず止まると予測する。7 の位置が 0 になる確率は約 6.7% なので、P5 なしの最小一致は 10 seed 中 2 以下と予測する（算術は T14）。

---

## 1. v0.3 §6.2 の4条件の監査（最初に読む節）

### 1.1 表

| 条件 | v0.3 §6.2 の文言（design-v0.3.md:774-777） | ディレクターの判定 | この文書の判定 | 証拠 |
|---|---|---|---|---|
| (a) | `checkWith` と `*Case` が1リリースのあいだ変更なしで使われていること | 満たす | **形式上は満たす。実質的な証拠は薄い** | 下の 1.1(a) |
| (b) | T7 が v0.3 でゲートを満たし、`[]const union` の削除が実測で効くこと | 一部満たす | **一部満たす。前提そのものを修正する**（P5 が要るのは末尾に依存する判定だけ）。v0.4 では T14（判別できる）を M0 で測り、T10 の P5 無効化を測定する | 1.2 |
| (c) | `case.generate(T)` の設計（表示、キー注釈、span、replay） | この文書で解消 | **この文書で解消する**: 表示は D46・D47、キー注釈は D43、span は D43・D45、replay は D40・D41（加えて discard は D42、決定性は D48） | §2 |
| (d) | 実際の利用者のシナリオ（状態を持つ SUT）が1件あること | 満たさない | **満たさない**。in-repo の SlotMap（T10）を採るが、これは設計者が自分で埋め込んだバグであり、利用者のシナリオの代わりにはならない | 1.3 |

### 1.1(a) の詳細

- **シグネチャは変わっていない**（git で確認した）。`git diff v0.3.0 v0.3.1 -- src` の差分は3箇所だけである。
  - `src/gen.zig` の `floatRankToValue` の括弧（演算子の優先順位）。
  - `src/shrink.zig` の internal の `AcceptEvent` に2フィールド（`before_choices`、`after_choices`。shrink.zig:71-76）。
  - `passChunks` の cast（shrink.zig:496）。
- `src/runner.zig` と `src/root.zig` に差分はない。v0.3.1 から HEAD まで、`src/`、`tests/`、`validation/` に差分はない。
- したがって、次の宣言は v0.3.0 から HEAD まで同一である。
  - `Case`（shrink.zig:85-89、フィールドは `allocator` だけ）。
  - `Failure` と `eql`（shrink.zig:93-107）。
  - `PropertyWith`（shrink.zig:117-119）。
  - `checkWith`（runner.zig:221-231）。
  - root の公開名（root.zig:12-47）。
- **`tests/api_surface.zig` はこれを固定していない**。固定しているのは次の3つだけで、`Case` のフィールド、`checkWith` のシグネチャ、`Report.Failed` のフィールドは見ていない。
  - root の pub 宣言名（api_surface.zig:66-77）。
  - `Report` と `Failure` の tag 名（:79-82）。
  - `Config` と `Limits` のフィールド名と既定値の有無（:84-94）。
  → 「変わっていない」の証拠は git の diff であり、テストではない。D61 で固定を足す。
- **「使われた」のは zigprop 自身だけである**。`*Case` を受け取る property は次のものしかない。外部の利用者は知られていない。
  - `tests/examples.zig:51`。
  - `tests/oom.zig:210, 217, 222`。
  - `tests/meta12.zig`（:22, 27, 49, 94 など）。
  - `validation/main.zig:378`（T9/T9e）。
- **期間は1日である**: v0.3.0 は 2026-11-19、v0.3.1 は 2026-11-20（git log）。
- 判定: 条件の文言は満たす。条件の目的、つまり「実際の利用で API が壊れずに持ちこたえること」の証拠にはならない。この判定は弱めも強めもせず、範囲を正確にしたものである。

### 1.2 (b) の詳細と、前提の修正

**v0.3 で分かっていること（verification.md:42、行 27）**:
- T7 は v0.3 で発見 10/10、`[7]` 10/10 だった。
- v0.2.1（M0-e）でも `[7]` は 8/10 だった。予測した「`[0, …, 0, 7]` で止まる」は 10 seed 中 8 seed で外れた（Amendment A2、design-v0.3.md:1165-1171）。
- P5 を切っても、M3 では 8/10、M6 以降は 10/10 だった。
- → **T7 は P5 の効果を証明していない**。

**A3 の nightly の掃引について**:
- `.github/workflows/nightly.yml:16-52` は存在するが、verification.md に結果の行はない。
- Actions の結果は見られなかった（`gh` が拒否された）。
- 手元での実行が1回だけ、実装報告に記録されている（`research_notes/verification-pipeline-implementation-report-by-opus-2026-11-20.md:467`。seeds 10..109 で T7 は 100%）。
- この実行は v0.3 の構成だけを走らせたもので、v0.2.1 の値も P5 無効の値も同じ seed で取っていない。**分離の証拠にはならないので、引用しない。** 判別の観点では「測定されていない」と扱う。

**T7 が判別しなかった理由（論証のみ。測っていない）**:
- P5 なしでも、P1 は要素1個分の chunk を消せる。長さ draw は下がらないので、列の末尾はゼロ埋めされる。
- 7 より前の要素を消すと、7 が左にずれる。消した要素がその次の要素より大きければ、キー列は辞書式で小さくなり、受理される。
- 1巡目は P1 が P2 より前に走るので、7 より前の値はまだ乱数のままであり、ほとんどが 7 より大きい。だから削除の連鎖が通る。
- 最後に、P3 で長さを下げて末尾のゼロを落とす。
- 「`[0, …, 0, 7]` で止まる」は、P2 が先に 0 にした後の状況だけを考えていた。

**前提の修正（論証のみ、T10 と T14 で測る）**:
- **推奨する書き方では、コマンドの削除に P5 は要らない**と予測する。推奨する書き方とは、各ステップで事後条件を検査し、違反したらその場で返すものである（D45、D56）。
  - 失敗が起きたステップより後の draw は起きない。だから長さ draw にはたいてい余り（実行されなかったステップの分）がある。
  - P1 が途中のステップの chunk を長さを変えずに消しても、property は前にずれた位置で失敗して返るので、ゼロ埋めは起きない。
  - その後、P3 が長さ draw を実行された数まで下げる。
  - P5 はこれを1回の評価で行うので、評価の回数を減らすだけである（T10 の P5 無効化で測る。測定のみ）。
- **P5 が最小性に必要なのは、判定が列の末尾に依存する場合である**（例えば、最後の要素に依存する判定や、最後にだけ検査する不変条件）。長さを変えない削除は末尾をゼロ埋めし、そのゼロが判定を変えてしまう。
  - これを分離するのが T14 である。要素型を `struct { a: u8, flag: bool }`（要素あたり 3 choice）にし、判定を「7 を含み、かつ最後の要素の a が 0 でない」とする。
  - すると、P5 なしで消せる経路は全て塞がれる（§4 T14 で場合を尽くした）。
  - P5 なしの shrinker は、**発見したケースの最初の 7 の位置 f について、f 個の `{0, false}` の後に `{7, false}` が続く形で必ず止まる**と予測する。
  - f = 0 の確率は約 6.7% である。
  - この予測は seed ごとに検査できる（発見したケースから f を読めば、止まる形が決まる）。A2 の教訓（割合だけを予測すると外れたときに何が外れたか分からない）への対策である。
- T14 は v0.3.1 のツリーのまま、内部のパスマスク（`ShrinkPassMask`、shrink.zig:48-56）で測れる。だから **v0.4 のコードを書く前（M0）に、(b) の残りの半分を判別できる形で測れる**。

### 1.3 (d) の詳細

- in-repo のシナリオとして、世代付きハンドルを持つスロットマップ（SlotMap）を採る（T10）。
- **これで示せること**: 対話的な draw が、状態に依存する生成、shrink、表示、replay を一つの SUT の上で正しく通すこと。ただしその SUT とバグは、設計者が仕組みに合うように選んだものである。
- **示せないこと**: 利用者が実際に書く SUT の形（外部の資源、非決定性、長いセットアップ）に API が合うこと。comptime の interface が要るかどうか（D53）。表示に何が要るか（モデルと SUT の状態を出すべきか。D57）。
- (d) が満たされていないことで弱まるもの: API の形を凍結する根拠。そこで v0.4 では、**凍結する面を Case の4つのメソッドと `Report.Failed` の追加フィールドだけに限る**（D38、D53）。フレームワークの形は、利用者が現れるまで決めない。

### 1.4 判定: 目玉の地位は得られているか

- 「stateful testing（フレームワーク）」としては**得られていない**。理由は次の3つで、これを D53 の OUT の根拠にする。
  - (d) が満たされていない。
  - (a) は形式上だけ満たされている。
  - T10 で B2 が v0.4 と同等になると予測した（§0）。
- 「対話的な draw」としては、**M0 の2つの測定を条件として、得られると判断する**。
  - **T14**: P5 無効で最小一致が 4/10 以下。
  - **T10-B1**: 盲目的な符号化で発見が 0/10。
  - どちらかが予測と違えば、M0 の後に目玉の判定を見直す。その場合は、この文書に Amendment を足してからレビューに戻す。
- v0.4 が出すもの: `Case.generate` / `index` / `choose` / `steps`、表示のための draw ログ、再現の確認、`void` の生成、モデルベーステストのレシピ（README と T10）。
- 「No」の場合の代替（Q1 で反対された場合）: v0.4 では T14 と、B2 の書き方を README のレシピにすることだけを出す（コードの変更は T14 の validation だけ）。対話的な draw は v0.5 に回す。

---

## 2. 対話的な draw: `case.generate(T)`（要となる部分）

### 2.1 現状（確認済み）

- `Case` のフィールドは `allocator` だけで、`Source` には届かない（shrink.zig:85-89）。
- `evaluateAttempt` の処理の順は次のとおりである（shrink.zig:182-225）。
  1. `GenContext` を作る（:194-195）。
  2. 値を生成する（:196-202）。
  3. property の前の検査: `sticky_error` → `limit_exceeded` → 枯渇（runner と regression では discard）（:203-210）。
  4. `Case` を作り（:211）、property を呼ぶ（:212-216）。エラーは名前によらず失敗（:213）。
  5. 失敗のときだけ、記録された choice、キー、skip、span を結果の allocator に複製する（:217-224）。
- **複製は property が返った後に行われる**。だから property の中で同じ Source に draw すれば、それはそのまま失敗の列に入る。足りないのは、Case から Source に届く経路と、property の後の検査である。
- shrink の候補は bound = 0 の choice として replay され（shrink.zig:366）、`exhaustion_is_discard = false` で評価される（:369）。足りない分は `Source.draw` が 0 で埋める（source.zig:327-330）。
- runner の regression 段階と random 段階は `exhaustion_is_discard = true` で評価する（runner.zig:509, 563）。未消費の suffix は property の後に `src.pos` で判定される（runner.zig:510）。

### 2.2 D39: Case から試行の生成状態へ届く経路

- **選択肢**:
  - (A) `Case` に internal 型へのポインタのフィールド `impl` を足し、メソッドから使う。
  - (B) `Case` に `*GenContext` を公開フィールドとして持たせる。
  - (C) property のシグネチャに `*GenContext` を足す。
- **推奨: (A)**。
  ```zig
  pub const Case = struct {
      allocator: Allocator,
      /// internal（安定性の保証なし）。zigprop が作った Case だけが非 null。
      impl: ?*internal.CaseState = null,

      pub fn generate(self: *Case, comptime T: type) anyerror!T;     // D43
      pub fn index(self: *Case, n: u64) anyerror!u64;                // D44
      pub fn choose(self: *Case, comptime E: type, enabled: std.EnumSet(E)) anyerror!E; // D44
      pub fn steps(self: *Case, max: usize) Steps;                   // D45
      pub const Steps = struct { … pub fn next(self: *Steps) bool; };
  };
  ```
  `CaseState` は shrink.zig の internal 型である。中身は次のとおり。`evaluateAttempt` の frame に置き、`Case.impl` がそれを指す。
  - `gen: *GenContext`（:195 の gctx）。
  - `discard: bool`（D42）。
  - 現在の step の番号と、開いている step span の小さなスタック（D45）。
- **根拠**:
  - D27 が `*Case` をポインタにしたのは、まさにこの追加のためである（design-v0.3.md:783）。
  - D28 は Source と GenState を internal に置く。`GenContext.impl: *GenState`（source.zig:66）という前例があり、internal 型へのポインタを公開 struct のフィールドに持つことは、D28 の線引きの中にある。
  - (B) は、`GenContext` の `range` / `length` / `countElement` を property から呼べるようにしてしまう。このうち `countElement` は生成器のためのもので、property から呼ぶ意味がない。
  - (C) は `PropertyWith` を壊す。
  - `impl` に既定値（null）を付けるのは、v0.3 §7.5 の「既定値付きのフィールドの追加は互換」（design-v0.3.md:849-851）に合わせるためである。利用者が `Case` をリテラルで作っても、コンパイルは通り続ける。null の Case でメソッドを呼ぶのは誤用であり、`.?` の安全検査（Debug では panic）で止める。
- 層の規則: `Case` は shrink.zig にあり、shrink は gen を import している（shrink.zig:30）。`tools/lint/layers.zon` の順（source < fingerprint < gen < shrink < runner < root）の中に収まり、上向きの辺は増えない。
- 証拠: (予定) テストで固定（meta13 "case: draws record into the attempt's Source"）。

### 2.3 D40: 記録の形

- **決定**: property の中の draw は、値の生成と**同じ Source** に、値の draw の**後ろへ**続けて記録する。列は平らなままで、区切りは記録しない。
  - `Report.Failed.choices` と `shrunk_choices` の意味は、「確定した失敗で消費された列の全体（値の draw、続いて property の draw、それぞれ draw の順）」になる。v0.3 の意味「消費された列」（runner.zig:139-141）を一般化しただけで、property が draw しない場合は今と同じである。
  - `regressionEntry`（runner.zig:159-173）は変えない。replay では、生成が先頭を消費し、property が残りを消費する。
- **採らなかった案**: property の draw を別の列に分ける（2本の列）。
  - 受理規則（shortlex、shrink.zig:246-260）、P1〜P6、ZON のスキーマが全て1本の列を前提にしている。2本にすると、それら全てを一般化しなければならない。
  - 平らな列にしておけば、生成と property の境目を消す候補（P1 がまたぐ削除）も、ただの候補になる。健全性は `tryAccept` の再評価で保たれる（shrink.zig:410-420）。
- 証拠:
  - (予定) T11 の「カスタム生成器で同じ draw を行う形と、seed ごとに shrunk choices が完全に一致する」ゲート。
  - 論証: 同じ primitive が同じ順で同じ Source に呼ばれるので、列は同一になる。

### 2.4 D41: property の後の検査

- **決定**: property が返った直後に、次の順で検査し、**検査の結果が property の判定より優先する**。
  1. 開いている step span を閉じる（D45）。
  2. `src.sticky_error` → そのエラーを返す（インフラのエラー。check から伝播する）。
  3. `src.limit_exceeded`（`max_draws` の超過）または `CaseState.discard`（D42）→ `.discard`。
  4. `src.exhausted and exhaustion_is_discard` → `.discard`。
  5. ここで初めて property の判定を分類する（`pass`、`returned_false`、`returned_error`）。

  property の前の検査（shrink.zig:203-210）はそのまま残す。
- **各結果の意味**:

  | 状況 | shrinker（`exhaustion_is_discard = false`） | random 段階 | regression の replay（`true`） |
  |---|---|---|---|
  | property の中で列の終わりを越えた | 0 で埋めて続ける。埋めた分も記録され、受理はその列で比べる（今の生成と同じ） | 起きない（random） | **discard → stale `discarded`**（runner.zig:520）。黙って 0 で埋めた結果で pass や fail に数えることはない |
  | `max_draws` を超えた | discard（候補は拒否） | discard | stale `discarded` |
  | `case.generate` の要素予算超過（D42） | discard | discard | stale `discarded` |
  | 記録中の OOM（sticky） | エラーを伝播 | エラーを伝播 | エラーを伝播 |

- `StaleReason.discarded` の説明は、すでに「the replay was discarded (including exhaustion)」になっている（runner.zig:85）。variant は足さない。`StaleReason` は公開 enum なので、variant を足すと利用者の網羅的な switch が壊れる（v0.3 §7.5 の Report と同じ理由）。
- **根拠**:
  - 「判定より検査が優先する」は、既存の `sticky_error` が生成器のエラーより優先する規則（shrink.zig:197-199）と同じ形である。
  - 枯渇した replay で計算された判定は、エントリが表す値についての判定ではない。だから pass にも fail にも数えない。
- **既存の property への影響**: draw しない property では、property の前の検査から property が返るまでのあいだに、Source のフラグを変える操作が一つもない。したがって検査の結果は前の検査と同じであり、挙動は変わらない（論証）。
  - 機械的な検査: 各マイルストーンで T1〜T9e の validation の出力がバイト単位で一致すること（D59）と、既存のメタテストが無変更で pass すること。
- **例外として扱うもの**: 生成器が自分の `GenContext` のポインタを Ctx に隠しておき、property から draw する、という病的な使い方。今はその draw が検査されずに分類されるが、D41 の後は検査される。改善でしかないので、互換の対象にはしない。
- 証拠:
  - (予定) テストで固定（meta13 の4テスト: regression の replay で列の終わりを越えると stale `discarded` になる、`max_draws` を超えると discard、記録中の OOM はエラー、検査が判定より優先する）。
  - (予定) T12 (c) のゲート。

### 2.5 D42: property の途中での discard

- **背景**:
  - D27 により、property が返したエラーは名前によらず全て失敗である（design-v0.3.md:654、shrink.zig:213）。
  - 一方、`case.generate(T)` が中で呼ぶ `gen.generate` は、要素予算の超過（gen.zig:22-27）や m = 0 の切断（gen.zig:369）で `error.InvalidGeneration` を返す。
  - 利用者が `try case.generate(T)` と書けば、このエラーは property から返り、失敗として報告されてしまう。
  - エラー名は大域的に interning されるので、エラー名で制御を流してはいけない（AGENTS.md、v0.3 §5.3）。
- **選択肢**:
  - (A) フラグの経路。`case.generate` が `InvalidGeneration` を受けたら `CaseState.discard = true` にし、エラーは property を抜けるための運び手として返す。`evaluateAttempt` はフラグを見て discard にする（D41 の 3）。
  - (B) 判定をタグ付き union にする（`PropertyWith` を変える）。
  - (C) property の途中の discard を一切扱わない。
- **推奨: (A) をライブラリが起こす discard に使い、利用者が求める discard（`case.reject()` / `assume`）は OUT にする → PARTIAL**。
  - `InvalidGeneration` 以外の `gen.generate` のエラー（arena での OOM、gen.zig:191）は `src.sticky_error` に入れ（まだ null なら）、エラーとして返す。D41 の 2 により、インフラのエラーとして伝播する。
  - 比べるのは `error.InvalidGeneration` だけである。これは `tools/lint/error-contract.zon` の `comparable` に既にある名前で、比較の位置は Case のメソッドの中になる（ref に v0.4 の節を足す）。
  - 利用者の property が自分で `error.InvalidGeneration` を返した場合、フラグは立たないので失敗のままである。D27 は変わらない。
  - 利用者がエラーを catch して `false` を返しても、フラグが立っていれば discard になる。そのケースは不完全だからである（H7 で突いてほしい）。
- **根拠**:
  - (B) は `PropertyWith` を壊す。
  - (C) では要素予算の超過が失敗になり、原理的に壊れる。
  - 利用者が求める discard が要らない理由: 推奨する書き方では、前提条件は「有効なものの中から選ぶ」（D44）で表すので、discard する場面がない。
  - 利用者の discard は、`max_discards` と `gave_up` の数え方に新しい入力を加える。(d) の利用者がいない段階では、その需要を確かめられない。フラグの仕組みは (A) で既にあるので、後から足すのは1メソッドで済む（Q3）。
- 証拠: (予定) テストで固定（meta13 "case: an element-budget overflow inside the property is a discard, a property's own InvalidGeneration is a failure"）。

### 2.6 D43: キー注釈と span

- **決定**: `case.generate(T)` は、`CaseState.gen`（試行の `GenContext`）に対して `gen.generate(T, gctx)` を呼ぶ。生成時の draw と同じコードを通るので、注釈と span は構成によって同じになる。並行する別の経路は作らない。
  - 整数と float の組の注釈（`annotatePair`、source.zig:237-244。gen.zig:469, 652）。
  - slice の長さ draw と要素 span（gen.zig:189-201）。
  - struct と union の出現 span（gen.zig:161, 206）。
  - 深さ（`GenState.depth`）と要素予算（`elements_generated`）は、値の生成と共有する。property が呼ばれた時点で深さは 0 に戻っている（gen.zig:153-155 の defer で復元される）。
- **span が誤っていた場合の代償**: v0.3 の D18（source.zig:18-22）と同じで、効率だけであり、健全性は損なわない。受理の判定は `tryAccept` と `tryRatchet` だけが行い（shrink.zig:410-460）、どちらも再評価した列で判定する。
- 証拠:
  - (予定) T11 の seed ごとの完全一致（キーや span がずれれば、shrink の軌跡が変わり、choice が一致しなくなる）。
  - 論証（構成）。

### 2.7 D44: 動的な bound の draw: `index(n)` と `choose(E, enabled)`

- **決定**:
  - `case.index(n)`: `[0, n)` から1回 draw する（`Source.index`、source.zig:347-354 と同じ記録、キー = 値）。
  - `case.choose(E, enabled)`: enum E のうち有効なものを宣言順に並べ、その個数 m について `index(m)` を**常にちょうど1回** draw する。m = 1 でも draw する（bound 1、値 0 が記録される。source.zig:353 → :336）。
  - **n = 0、または有効な選択肢が空のときは discard**（D42 のフラグを立て、`error.InvalidGeneration` を運び手として返す）。
- **`GenContext.index(0)` との違い**: `GenContext.index(0)` は sticky の `InvalidBound`（source.zig:347-351、MF1）である。property の中の状態は、shrink の候補が作る「random 探索では起きなかった組み合わせ」に到達しうる。そこでインフラのエラーにすると、テスト側の前提条件の小さな穴で check 全体が止まる。discard なら候補が拒否されるだけで済む。
- **「常に1回 draw する」の根拠（choice 列のモデルから）**:
  - shrink でより前のステップを消すと、後のステップでの状態が変わり、有効な集合の大きさも変わる。
  - m = 1 のときに draw しない規則にすると、ステップごとの draw の数が状態に依存してしまう。その後のステップの列は全て1つずれて読まれ、コマンドの種類が別のものになる（効率の損失。健全性は保たれる）。
  - 常に1回 draw すれば、各ステップの最初の choice はいつも「どの種類か」を表す。値は replay の正規化（`% m`、source.zig:333）で新しい有効集合に収まる。
  - 切断の union で m = 1 のときに draw しない規則（gen.zig:371）とは事情が違う。切断の形は型だけで決まるので、draw の数がずれることがない。
- 前提条件は「payload を draw する前に、有効なものの中から選ぶ」形（状態に依存する生成）で自然に書ける（§3、D54）。読み飛ばしも discard も要らない。
- 証拠: (予定) テストで固定（meta13 "choose: always one draw, bound = enabled count; empty set discards"）。

### 2.8 D45: 繰り返しの構造: `case.steps(max)` と P5

これはブリーフ §2.3 item 5 の問題で、P5 は長さ draw なしには働かない、という点を正面から扱う。

**現状**:
- P5 は、要素 span の `length_pos` にある値が 0 でない slice について、長さを 1 下げ、その要素 span を除く（shrink.zig:677-711。値の確認は :694）。
- 対話的な draw のループには、作らない限り長さ draw がない。例えば `n = try case.generate(u8)` の後に n 回 draw する書き方では、次のようになる。
  - 長さは整数の組であり、長さ draw ではない。
  - 要素 span もない。
  - → P5 は候補を一つも作らない。
  - P1 がステップを消すと長さは変わらないので、列の末尾が 0 で埋まる。これは v0.2 の `[0, 7]` で止まる問題と同じ形である。

**選択肢**:
- (i) 長さを先に draw し、ステップごとに既存の `.element` span（その長さ draw の `length_pos` 付き）を開く。
- (ii) ステップの前に毎回「続けるか」の bool を draw する。
- (iii) `[]const Command` を先に生成する。今でもできるが、前提条件をモデルの状態に依存させられない（B1/B2 の形）。

**推奨: (i)**。
```zig
var s = case.steps(16);         // range(17) の長さ draw を1回。length_pos を覚える
while (s.next()) { … }          // next() は前のステップの span を閉じ、
                                // countElement を数え、次の .element span を開く
```
- **既存の `Span.Info.element`（source.zig:31）をそのまま使う。新しい variant も新しいパスも作らない。** P5 と P6 は変更なしで、ステップを slice の要素とまったく同じように扱う。
- property が途中で返った（失敗した）ときに開いていた span は、D41 の 1 で、その時点の記録位置で閉じる。
  - 開いた span は `beginSpan` で end = start のまま残るので（source.zig:201-208）、閉じないと空の span と区別できない。そのため、`CaseState` が開いている step span の番号を小さなスタックに持つ（入れ子の上限 8。超えた分は span を記録しない。これは効率だけの損失で、D18 に合う）。
- `next()` が `countElement`（gen.zig:22-27）で要素予算を超えたら、D42 のフラグを立てて false を返す。ループは止まり、試行は discard になる。
- `max` が `Limits.max_len` ではなく引数なのは、ステップの数は property のコードの一部であり、型の生成の形ではないからである（fingerprint への影響は D51）。

**(i) を採る根拠**:
- P5 がそのまま働く。
- 長さ draw のキーは1個（キー = 長さ）である。最小の列ではステップの数がそのままキーに出て、一意性の議論が簡単になる（T10）。
- **(ii) の代償**:
  - ステップごとにキーが1個増える（最小の列が長くなる）。
  - P5 は「長さを下げる」のではなく「印を消す」ものとして一般化する必要がある（新しい span の variant）。
  - さらに一様な bool では、ステップ数の分布が幾何分布（平均1ステップ）になってしまう。偏った bool の内部 sampler を足す必要がある（`rangeLogUniform` のような F-c 型の primitive）。
  - どれも新しい機構を足すのに、得るものは「上限が要らない」ことだけである。
- **(iii)** は、v0.4 が加えるもの（状態に依存する生成）を捨てる。

**(i) の弱点と、それが何を損なうか**:
- 失敗が早いと、長さ draw の値 n は実行されたステップ数より大きいままになる（余りがある）。
- これは損失ではない。§1.2 のとおり、余りがあるので、P1 がステップを消してもゼロ埋めは起きない。その後 P3 が n を実行された数まで下げる。
- P5 は「長さを 1 下げて span を除く」を1回の評価で行う。余りがある場合は、効率の改善にとどまる（T10 で P5 を無効にした値を測る）。

**健全性**: P5 の候補も `tryAccept` を通る（shrink.zig:702）。受理されるのは、失敗の種類が等しく、再記録したキー列が厳密に shortlex で小さい場合だけである（shrink.zig:410-420、:375）。状態に依存する draw で後のステップの意味が変わっても、変わった後の列が再評価され、その再記録された列が比べられる。だから「小さくない列を受理する」ことは起きない（構成による主張、v0.3 §3.4 と同じ）。

証拠:
- (予定) テストで固定（meta13 "steps: one length draw, one element span per step, an early return closes the open span"）。
- (予定) T10 の最小一致のゲート。
- (予定) T10 の P5 無効化（測定のみ）。

### 2.9 D46: 中で引いた値の表示: draw ログ

v0.3 §6.3（design-v0.3.md:788）が「難しくする可能性」と書いた点である。表示は、property を呼ばずに T の値を再生成して作っている（D30、runner.zig:355-375）。そのため、property の中で引いた値は表示に含まれない。

**選択肢**:
- (A) **draw ログ**: draw のたびに小さなエントリを Source に追加する。失敗した評価の分を結果の側に複製し、報告のときに再生成してフォーマットする。
- (B) 報告のときに、最終の列で **property をもう一度 replay** し、そのときに draw を記録してフォーマットする。
- (C) **draw のたびにフォーマット**する。
- (D) (A) と (B) の併用。

**推奨: (A)**。
- エントリは `{ start, end, step: ?usize, shown }` である。`shown` は次のどれかで、どれもフォーマットはせず、数語を書くだけである。
  - `regenerate`: T ごとに comptime で作る、型を消した関数ポインタ `*const fn (Allocator, Limits, []const Choice) anyerror![]u8`。`case.generate(T)` が使う。
  - `index: u64`（`case.index`）。
  - `tag: []const u8`（`case.choose` が選んだ tag の名前。comptime の静的な文字列）。
  - `step_marker`（`Steps.next()`）。
- **所有の規則**:
  - ログは Source の新しい内部リスト `recorded_draws` に置く。試行の arena で確保し、試行とともに消える（runner.zig:558-562、shrink.zig:362-368）。
  - `evaluateAttempt` は失敗のときだけ、span と同じ場所で結果の allocator に複製する（shrink.zig:217-224 の後）。`AttemptResult.fail` に `draws` を足す。
  - shrinker は best と一緒に置き換える（`best_spans` と同じ扱い、shrink.zig:392-401）。
  - internal の `ShrinkResult`（shrink.zig:227-232）は、最終の best のログを返す（今は span を捨てている、shrink.zig:784-786）。
  - `makeFailed` が、元の列と縮めた列それぞれについて、エントリごとに choice の部分列 `[start, end)` から再生成してフォーマットする。文字列は結果の allocator が所有する。arena の中を指すものは残らない。
- **再生成の正しさ（論証のみ。T11 と T10 の表示のゲートで検査する）**: 部分列だけを新しい `GenState` で `gen.generate(T)` に通すと、property が見た値と同じ値が出る。理由は次のとおりである。
  - (1) property の中では深さは 0 である（D43）。
  - (2) 要素予算と `max_draws` は「超えれば discard」にしか効かない。確定した失敗では超えていない。部分列だけなら数えられる量はさらに少ない。
  - (3) 記録された値は正規化済みである。同じ bound で replay すれば同じ値になる（Lean `normalize_idempotent_all`、verification.md:17）。
  - (4) shrinker で 0 埋めした分も記録に入っている（source.zig:336）。
- **フォーマットの関数を一つにまとめる**: `hasCustomFormat` と `{f}` / `{any}` の選択（runner.zig:344-375）を shrink.zig へ下ろし、`renderValue` と draw ログの両方がそれを使う（層の規則上、shrink から runner は参照できない）。

**根拠**:
- (A) は D30 の原則「表示のために property を呼ばない」（design-v0.3.md:1063）の上に乗る。試行ごとのコストは、draw ごとに数語を追加するだけである。これは v0.3 が D18 の span で受け入れたのと同じ形のコストである。
- (B) は D30 を覆す。副作用を持つ SUT をもう一度動かすことになり、property が非決定的なら、**表示が受理された評価とは別の実行の値になる**。表示がいちばん必要なときに、表示が誤る。
- (C): D30 が試行ごとのフォーマットを退けた理由（全ての試行で確保が要り、遅い。design-v0.3.md:676）は、中で引いた値だけを対象にしても成り立つ。shrink は数千回評価し、そのたびに全ての draw をフォーマットすることになるからである。
- (D) は (B) の欠点を引き継ぐ。決定性の確認は表示と切り離して D48 で行う。

証拠:
- (予定) テストで固定（meta13 "draw log: entries match the draws, are copied on failure and survive the arena"、oom.zig に property の中で draw する場合を追加）。
- (予定) T10 と T11 の表示のゲート。
- 正しさの論証。

### 2.10 D47: `Report.Failed` に足すもの

```zig
pub const Failed = struct {
    … // v0.3 のフィールドは全て不変（runner.zig:135-151）
    /// property の中で引いた値（draw の順、再生成して作る。D46）。property が draw しなければ空。
    original_draws: []Drawn = &.{},
    shrunk_draws: []Drawn = &.{},
    /// 最終の列で property が draw した場合だけ非 null。D48。
    reproduced: ?bool = null,

    pub const Drawn = struct { step: ?usize, text: []u8 };
};
```
- 互換性:
  - v0.3 §7.5 は「ペイロード struct へのフィールド追加は互換とする（利用者は Report を構築しない）」と定めている（design-v0.3.md:851）。凍結されているのは variant の集合（`passed` / `failed` / `gave_up`）だけである（runner.zig:113-115）。
  - `tests/api_surface.zig` は `Failed` のフィールドを固定していない（:79-82 は tag だけ）。
  - → 互換な追加である。それでも既定値を付けて、§7.5 の規則にそろえる。
  - root の pub 宣言は増えない（`Drawn` は `Failed` の入れ子にする）ので、api_surface.zig:66-77 の一覧も変わらない。
- `deinit` は各 `text` とスライスを解放する（runner.zig:176-189 に追加）。
- `*OrError` の印字（D26 により、印字するのはここだけ。runner.zig:315-338）: `shrunk:` の行の後に `drawn:` の節を置き、step ごとにまとめて出す。最後の step に `<- failed here` を付ける。
- 証拠: (予定) テストで固定（meta12 に追加: ownership、`deinit` でリークしない、印字の形）。(予定) T10 と T11。

### 2.11 D48: property の決定性の契約と、再現の確認

**契約（README と `Case` の doc comment に書く）**:
- property は、Ctx と、自分が引いた値と、`case.allocator` だけの決定的な関数でなければならない。
- 評価をまたいで状態を持ち越してはならない。SUT とモデルは評価ごとに作り直す（D55）。
- v0.3 §5.5 の「生成器は property が書き換える状態に依存してはならない」（design-v0.3.md:673）を、property 自身の draw に広げたものである。

**破られた場合に起きること（論証のみ）**:
- **健全性（「保存された best は失敗した列である」）は保たれる**。`tryAccept` と `tryRatchet` は、その評価で同じ種類で失敗した列しか受理しない（shrink.zig:375, 410-460）。TLA+ の `BestAlwaysFails`（verification.md:23）の具体例である。
- 損なわれるのは**再現性**である。
  - 報告された列を replay しても失敗しない可能性がある。
  - 貼ったエントリが pass して `passed` に数えられる（黙った見逃し）。
  - shrink の最小性が下がる。
- 表示は D46 により、受理された評価の値を正しく示す。

**検出の選択肢**:
- (A) 何もしない（v0.3 の H7 と同じ扱い）。
- (B) 報告の前に、縮めた列を **regression と同じ条件で1回 replay する**。条件は、bound = 0 の値、`exhaustion_is_discard = true`、そして「同じ `Failure` で失敗し、列を全て消費した」ことを要求する。その結果を `reproduced` に入れる。
- (C) 試行ごとに2回評価する。

**推奨: (B)。ただし、最終の列で property が draw した場合（draw ログが空でない場合）だけ行う。**
- コストは、報告される失敗1件につき評価1回で、shrink の予算には数えない。
- これは貼ったエントリが replay で失敗することの、その場での確認にもなる。
- **何を検出しないか**:
  - 確率 q で起きる非決定性を、1回の再実行で検出する確率は q 程度にとどまる。
  - 状態の持ち越しがあっても、確認の時点でたまたま同じ結果になるものは検出しない（T13 で測る）。
- **draw しない property には適用しない理由**: 適用すると、v0.3 の property でも、shrink の後に property が1回余分に動く。meta3 の生成器呼び出しのカウンタ（tests/meta3.zig:213 の `counting_calls`。予算の数え方を外部のカウンタで固定している）が変わり、固定されている挙動が動いてしまう。v0.4 の目標は既存の挙動を動かさないことなので、draw する property に限る。
- (C) はコストが2倍で、(B) より多くは検出しない。

**D30 との関係**: (B) は property を呼ぶが、それは表示のためではない。D30（表示のために呼ばない）とも、v2 §7 の「表示のために property を再実行しない」とも衝突しない。ただし副作用のある SUT を1回余分に動かすので、Q4 で確認する。

証拠:
- (予定) T13（測定のみ）。
- (予定) T10、T11、T12 で `reproduced == true` が 10/10（ゲート）。

---

## 3. stateful 層: レシピとして出し、フレームワークにしない

### 3.1 D53: comptime の command interface（フレームワーク）: OUT

**選択肢**:
- (A) comptime の interface。例えば次の宣言を持つ struct を `zigprop.stateful.run(Spec, case)` に渡す。
  - `Command`（union）。
  - `State`、`init`、`deinit`。
  - `enabled`、`draw`、`run`、`invariant`。
- (B) 関数を渡す形。
- (C) フレームワークを作らない。§2 の primitive と、文書化されたレシピだけにする。

**推奨: (C)。(A) と (B) は v0.4 では OUT。**

**根拠**:
- **choice 列のモデルから見ると、フレームワークが加えるものはない**。shrink に要るのは D44（状態に依存する bound の記録）と D45（長さ draw と要素 span）だけである。ループ、前提条件、事後条件、後片付けは、ふつうの Zig の制御フローと `defer` で書ける。
- **comptime のコスト**: (A) は宣言の検査と、`Command` の各 variant についての `inline` の分岐を、利用者の型ごとにインスタンス化する。v0.2 と v0.3 では comptime の爆発（K1）があり、`tests/compile_budget.zig` がその再発を見張っている。(C) は `gen.generate(T)` を引いた型ごとにインスタンス化するだけで、これは今の生成と同じコストである。
- **エラーメッセージ**: (A) の誤用は「Spec に `enabled` がない」といった `@compileError` で報告され、利用者は interface の規約を覚えなければならない。(C) の誤用は、ふつうの Zig の型エラーとして報告される。
- **(d) がない**: interface の形（モデルと SUT を分けるか、`run` が値を返すか、セットアップが失敗しうるか）を決める材料は、利用者のシナリオからしか得られない。凍結する面を増やすのは、利用者が現れてからにする。
- 取り込む条件（v0.5 以降）: 利用者のシナリオが1件以上あり、同じ形のコードがレシピから3回以上コピーされていること。

### 3.2 D54: コマンドの表現（レシピ）

**選択肢**:
- (A) 利用者の `union(enum)` を `case.generate(Command)` で生成する（tag の draw に続けて payload の draw）。
- (B) 種類を表す `enum` を `case.choose(Op, enabled)` で選び、payload は種類ごとに `case.generate` / `case.index` で引く。
- (C) (A) の `union(enum)` を状態から作った有効集合でふるい落とし、無効なら引き直す。

**推奨: (B)**。
- (A) は、payload の型が状態に依存できない。例えば「既存のハンドル」は u64 として盲目的に引くことになり、T10 の B1 と同じ発見率になる。tag もモデルの状態と無関係に選ばれる。
- (C) は引き直しで draw の数が状態に依存し、D44 の「各ステップの最初の choice は種類を表す」が崩れる。

**(B) の形の例（T10 の property。README に載せる）**:
```zig
const Op = enum { insert, remove, get };
fn slotMapProp(cfg: *const Cfg, case: *zigprop.Case, _: void) anyerror!bool {
    var sut = try SlotMap.init(case.allocator, 4, cfg.mutant);
    var model: Model = .init(case.allocator);           // live / issued / 値
    var s = case.steps(16);
    while (s.next()) {
        var en: std.EnumSet(Op) = .empty;
        if (model.live.items.len < 4) en.insert(.insert);
        if (model.live.items.len > 0) en.insert(.remove);
        if (model.issued.items.len > 0) en.insert(.get);
        switch (try case.choose(Op, en)) {
            .insert => {
                const v = try case.generate(u8);
                const h = try sut.insert(v);
                if (model.wasIssued(h)) return error.HandleReused;
                try model.insert(h, v);
            },
            .remove => {
                const h = model.live.items[try case.index(model.live.items.len)];
                if (!sut.remove(h)) return error.RemoveMismatch;
                model.remove(h);
            },
            .get => {
                const h = model.issued.items[try case.index(model.issued.items.len)];
                if (!std.meta.eql(sut.get(h), model.get(h))) return error.GetMismatch;
            },
        }
    }
    return true;
}
try zigprop.checkWithOrError(gpa, void, *const Cfg, &cfg, null, slotMapProp, .{});
```

### 3.3 D55: モデルと SUT の寿命、状態のリセット、後片付け

**選択肢**:
- (A) 評価ごとに property の中で `case.allocator` から作る。
- (B) Ctx にファクトリを持たせる。
- (C) Ctx に作り置きを持たせ、評価ごとにリセットさせる。

**推奨: (A)**。Ctx には変更しない設定（容量、mutant の切り替えなど）だけを持たせる。
- `case.allocator` は試行の arena である（shrink.zig:86-88）。評価ごとに作られ、評価とともに消える（runner.zig:558-562、shrink.zig:362-363）。shrink で数千回評価しても、リセットは構成によって起き、利用者が書く必要はない。
- 外部の資源（ファイル、ソケット）は利用者の `defer` で閉じる。`defer` は `return false`、エラーの返却、`try` で抜けるどの経路でも走る。ライブラリは後片付けに関与しない。
- (B) は Ctx の型に関数ポインタを持たせるだけで、(A) と何も変わらない。(C) は D48 の契約（持ち越さない）を利用者の注意に頼ることになる。

**OOM とリーク**:
- arena なのでリークは構成上起きない。T9 と同じく、gpa を `DebugAllocator` にしてリーク 0 をゲートにする（T10）。
- `case.generate` の中の OOM はインフラのエラーになる（D42）。property 自身の確保の OOM は、v0.3 §5.3 のとおり失敗になる。

§3.7 のセットアップと後片付けもこの決定に含める（答えが同じなので統合した）。

証拠: (予定) T10 のリーク 0（ゲート）。

### 3.4 D44 の再掲: 前提条件

- 前提条件は、**payload を draw する前に**、有効な種類だけを `choose` の候補にする形で表す（状態に依存する生成）。
- 読み飛ばし（v0.3 §6.3 の注、design-v0.3.md:791）と discard は使わない。

choice 列への効果の比較:

| 書き方 | 列への効果 | shrink への効果 |
|---|---|---|
| 読み飛ばし（B1/B2） | 無効なコマンドも draw を消費し、列に残る | 消せば純粋な得になる（キーが減る）。最小の列には残らない。ただし random 探索の段階では、ステップが無駄になり、発見率が下がる |
| discard | ケースが一つ失われ、`max_discards` に近づく（runner.zig:550-557） | 候補は拒否される |
| 有効なものから選ぶ（D44） | どのステップも何かを実行する | 列にはいつも意味のある draw だけが並ぶ |

### 3.5 D56: 不変条件と事後条件

- **決定**: ライブラリの機構は足さない。利用者が、各ステップの後（`while` の本体の最後）、最後（ループの後）、またはその両方で検査する。どこで検査するかは利用者のコードで選べる。
- **どの検査が失敗したかを区別する方法**: 検査ごとに別のエラー名を返す（`error.HandleReused`、`error.GetMismatch` など）。
  - `Failure` はエラー値まで比べる（shrink.zig:98-106）。shrink は同じ種類だけを受理するので（:375）、別の違反に滑ることはない（D27、v0.3 §5.4）。
  - `return false` だけを使うと、種類は `returned_false` の一つになり、別の違反に滑りうる。README でこれを明記する。
- ステップごとに検査することは、§1.2 で述べた理由により、P5 なしでも縮むことの前提になっている。
- 最後だけで検査する書き方は P5 に依存する（T14 がその形を分離する）。
- 証拠: (予定) T10 の「全ての発見で `returned_error(HandleReused)`」（ゲート）。

### 3.6 D45 の続き: コマンド列の shrink と、新しいパスは要るか

- T10 の最小の列は §4 T10 で予測する（キー列 `[3, 0, 0, 1, 0, 0, 0]`）。
- 「前のステップを消すと後のステップの状態が変わり、状態に依存する draw の意味が変わる」ことは、次の2つで扱える。
  - D44 の「各ステップの最初の choice は種類を表す」。
  - replay の正規化（`% bound`）。
- 新しいパスを要するターゲットはない。**新しいパスは足さない**（v0.3 §3 と同じ「名前の付いたターゲットが必要とするまで足さない」）。

### 3.7 D57: 失敗の報告

- **IN**: 何ステップ目で失敗したか、各ステップで何を引いたか。どちらも D46 の draw ログ（`step_marker` と各エントリの `step`）から作り、property を呼ばない。
- **OUT**: 失敗の時点のモデルと SUT の状態の表示。
  - property を呼ばずにこれを得るには、試行ごとに利用者のフォーマットを走らせるか（D30 が退けたコスト）、報告のときに property を再実行するか（D46 (B) の欠点）のどちらかが要る。
  - 利用者は、印字された regression エントリを replay し、デバッガで状態を見ることができる。
- → **PARTIAL**。

---

## 4. 検証ターゲット（事前登録、T10〜T14）

### 4.0 共通条件と手順

- v0.3 §8 と同じ: seed 0〜9、`max_cases = 200`、`shrink_budget = 2000`、既定の Limits（target ごとに明記したものを除く）。
- 発見と最小性は別々に数え、最小性の分母は発見した seed 数とする。
- 正しい実装の対照は 10/10 pass。
- 実行は `zig build validation`（build.zig:87）で行い、結果は verification.md に行として記録する。
- **A2 の教訓の適用**:
  - 各ターゲットに「なぜ判別できるか」を独立した一行で書く。
  - 各ターゲットに、算術の予測を付けた分離用の対照を置く。
  - **v0.3.1 のツリーで測れる基準値（T10-B1、T10-B2、T11 の生成器の形、T14 の P5 無効と P5 有効）は、v0.4 のコードを書く前に M0 で測る。** ゲートを凍結するのはその後である。
  - この文書の予測は M0 の前に登録する（いま、ここで）。M0 の値が予測と違っても、予測を書き換えずに Amendment として記録する（A2 と同じ）。ゲートの基準を見てから動かすことはしない。
  - **私は基準値をどれも測っていない**（この文書の検証状況のとおり）。

### T10 モデルベーステスト: 世代付きハンドルのスロットマップ

**SUT**:
- `SlotMap`。容量 C = 4、値は `u8`。
- ハンドルは u64 で、`(generation << 32) | slot` である。generation は 1 から始まる。
- 操作:
  - `insert(v) -> Handle`（空きスロットは LIFO の free list から先に使い、なければ新しいスロットを使う）。
  - `remove(h) -> bool`（h が生きていれば true）。
  - `get(h) -> ?u8`。
- 正しい実装は、`remove` でそのスロットの generation を 1 増やす。

**モデル**:
- 生きているハンドルの列 `live`、発行したハンドル全ての列 `issued`、ハンドルから値への対応。
- 事後条件:
  - `insert` は `issued` にないハンドルを返す（`error.HandleReused`）。
  - `remove(h)` は、h が生きていれば true を返す（`error.RemoveMismatch`）。
  - `get(h)` はモデルと等しい（`error.GetMismatch`）。

**mutant（意味を固定）**: `remove` が generation を増やさない。
- 解放されたスロットは、同じハンドルのまま再利用される。
- → **remove の後の最初の insert が、発行済みのハンドルを返す**（`HandleReused`）。
- remove の前には free list が空なので、再利用は起きない。

**property**: §3.2 の `slotMapProp`。T = `void`（D49）で、Ctx は `*const Cfg`（mutant の切り替え）。

**期待する最小反例**: ステップは `[insert 0, remove(index 0), insert 0]`、**キー列は `[3, 0, 0, 1, 0, 0, 0]`**。

**一意性（キー順序による論証）**:
- 失敗には、remove の後の insert が要る。remove には生きているハンドルが要り、それには先に insert が要る。→ ステップは3以上である。
- D44 によりどのステップにも choose の draw が1回あり、どの種類も payload の draw を1つ持つ。
  - insert の u8 は組で、キーは1個。
  - remove と get の index はキー1個。
  - → 1ステップあたりのキーは2個。
- 長さ draw のキー1個を加えて、キー数は 1 + 2·3 = 7 以上である。
- キー数 7 の失敗する列は、ちょうど3ステップで、次の順に決まる。
  - ステップ 0: 有効なのは insert だけ。choose の bound は 1、値は 0。
  - ステップ 1: remove でなければならない。有効集合は {insert, remove, get} なので、choose の値は 1。index は bound 1 なので 0。
  - ステップ 2: insert でなければならない。有効集合は {insert, get} なので、choose の値は 0。
  - 自由に選べるのは2つの u8 の値と長さ n だけで、辞書式の最小は n = 3、v = 0、v = 0。
- → 一意である。
- 生の choice（組の class）は P4 の有無で変わるので、固定するのはキー列と値である（D21 と同じ）。

**予測（事前登録）**:
- **v0.4 の発見**: 失敗するのは「あるステップ r ≥ 1 で remove、その後のステップ s > r で insert」が起きるときである。
  - remove の前の各ステップで remove が選ばれる確率は 1/3 以上（満杯なら 1/2）。remove の後の各ステップで insert が選ばれる確率は 1/3 以上（live = 0 なら 1/2）。
  - n ∈ {0..16} は一様である。
  - P(失敗 | n = 3) = (1/3)(1/2) ≈ 0.17。n = 16 では ≈ 0.97。n について平均すると ≈ 0.6 / ケース。
  - 200 ケースで見つからない確率は 0.4^200 で、事実上 0。→ **発見 10/10**。
- **v0.4 の最小一致**: 失敗は早く返るので、長さ draw には余りがある。
  - P5 は余計なステップの span を長さを下げながら消す。P1/P1b も、長さを変えずに消しても受理される（§1.2）。
  - P3 が n を 3 まで下げる。P2/P3 が u8 を 0 にする。
  - ステップ 1 の choose の値 1 を 0 に下げると remove がなくなり pass するので、拒否される。
  - → **最小一致 ≥ 9/10** と予測する（余裕を見て 9）。
- **B1（v0.3 で書ける盲目的な符号化）**: `[]const Cmd`。`Cmd = union(enum) { insert: u8, remove: u64, get: u64 }`、`max_len = 16`。無効なハンドルの remove は SUT もモデルも false を返す、ふつうの何もしない操作である。
  - 失敗には、生きているハンドル（< 2^32 + 4 の4つの値 `2^32 + slot`）にちょうど一致する u64 の remove が要る。
  - u64 の生成で特定の値が出る確率:
    - class 0（< 256）と class 1（{0, 1, max−1, max}、gen.zig:416-439）では 0。
    - class 2（対数一様、source.zig:295-300）では、幅 33 が 1/65 で、その中は 2^32 通りに一様。→ 4 値で 4·2^-32/65 ≈ 1.4·10^-11。class の確率 1/4 を掛けて 3.6·10^-12。
    - class 3 では 4·2^-64。
  - 1 ケースあたり remove は平均 16·(1/3)/2 ≈ 2.7 回（n の平均は 8）。→ ≈ 10^-11 / ケース。200 × 10 ケースで ≈ 2·10^-8。
  - → **B1 の発見 0/10**。
- **B2（v0.3 で書ける、状態に照らして解釈する符号化）**: `Cmd = union(enum) { insert: u8, remove: u8, get: u8 }`、`max_len = 16`。remove は `live[idx % live.len]`、get は `issued[idx % issued.len]` と解釈し、適用できなければ読み飛ばす。
  - tag が盲目的に選ばれて無駄になるステップがあるので、発見は v0.4 より少し下がるが、≈ 0.5 / ケースで **発見 10/10**。
  - 最小は `[insert 0, remove 0, insert 0]` で、キー列は `[3, 0, 0, 1, 0, 0, 0]`。union の tag のキーは index で、宣言の順が v0.4 の `Op` と同じなので、**v0.4 とキー列まで一致する**。→ **最小一致 ≥ 8/10**。

**ゲート（v0.4、M0 で B1 を確かめてから凍結する）**:
- 発見 ≥ 8/10、かつキー列 `[3, 0, 0, 1, 0, 0, 0]` の一致 ≥ 8/10。
- 全ての発見で `Failure = returned_error(HandleReused)`。T9e と同じ内部フックで、受理の全てでこの種類が保たれていること。
- `reproduced == true` が 10/10（D48）。
- `DebugAllocator` でリーク 0。
- 最小に達した seed で、`shrunk_draws` のテキストが次と一致する。step 0 は `.insert` と u8 の 0、step 1 は `.remove` と 0、step 2 は `.insert` と 0。期待するテキストはターゲットの中で値から `std.fmt` で作り、文字列の literal は固定しない。

**対照**: 正しい実装（generation を増やす）で 10/10 pass、リーク 0。

**分離用の対照**:
- B1: 予測 0/10。M0 で v0.3.1 のまま測る。
- B2: 予測は v0.4 と同等（測定のみ）。

**なぜ判別できるか: property の中の draw が状態に依存しなかったら（v0.4 が盲目的な生成と同じだったら）、発見は B1 の算術（≈ 10^-11 / ケース）に従って 0/10 になり、発見のゲートが落ちる。draw が列に記録されていなかったら、shrink は再現できず、最小一致と `reproduced` のゲートが落ちる。**

**分離していないこと**:
- **v0.4 と B2 の差は、発見でも最小キー列でも分離していない**（予測は同等）。T10 は「v0.3 の注意深い書き方より強い」ことを示さない。示すのは「素直な v0.3 の書き方（B1）より強い」ことと、仕組みが端から端まで通ることだけである。
- 発見の分布は、`choose` の一様性と `steps` の長さの一様性による。I4 の整数の分布の影響は受けない（u8 の値は失敗に関係しない）。

**測定のみ**:
- P5 を無効にした v0.4 の最小一致と評価回数。予測: 最小一致は ≥ 8/10 のまま、評価回数は増える。これは §1.2 の「早く返る書き方では P5 は要らない」の検査である。8/10 を下回れば、その予測が誤りであり、(b) の前提が T10 でも成り立つことの証拠になる。
- B2 の評価回数。

**Limits への影響**:
- ステップは 16 以下で、1ステップの choice は 3 以下。→ draw は 1 + 48 = 49 以下で、`max_draws = 100_000`（source.zig:46）に遠く及ばない。
- `countElement` は 16 回以下で、`max_total_elements = 4096` に遠く及ばない。
- → Limits による discard は 0 と予測する（測定して報告する）。

### T11 対話的な draw の shrink（型と数が前の draw に依存する）

**property**: T = `void`。次のように引く。
- `const w = try case.generate(Width)`。`Width = enum { wide, narrow }` で、`index(2)` の draw が1回。
- `w == .wide` なら `xs = try case.generate([]const u16)`、`.narrow` なら `xs = try case.generate([]const u4)`。どちらも既定の `max_len = 32`。
- 長さ draw と要素ごとの組が、型にも数にも依存する。

**判定（mutant に当たる故障を固定）**: `sum(xs) >= 1000`（u32 で加算）で失敗する。narrow は最大でも 32·15 = 480 なので、**決して失敗しない**。

**期待する最小反例**: `w = .wide`、`xs = [1000]`、**キー列 `[0, 1, 1000]`**。
- 一意性: 失敗には長さ ≥ 1 が要る。キー数は 2 + 長さなので、最小は 3（長さ 1）。そのとき単独の値が ≥ 1000 でなければならず、それができるのは wide（キー 0）だけ。値の最小は 1000。

**予測**:
- **発見**: u16 の1要素が ≥ 1000 になる確率は次の和である。
  - class 0: 0（< 256）。
  - class 1: {0, 1, 65534, 65535} のうち 2/4。
  - class 2: 幅は 0〜16 の 17 通りで一様。幅 11〜16 と、幅 10 の [1000, 1024) の部分（24/512）で、(6 + 0.047)/17 ≈ 0.356。
  - class 3: 64536/65536 ≈ 0.985。
  - → 1/4·(0 + 0.5 + 0.356 + 0.985) ≈ 0.46。
  - P(wide かつ失敗) ≈ 1/2 · 1/33 Σ_{L=1}^{32} (1 − 0.54^L) ≈ 0.47 / ケース。→ **発見 10/10**。
- **最小一致**: 最初の1巡では P5 が P1 と P2 より先に走る（shrink.zig:719-724）。要素を後ろから消していく。
  - 最初に現れる大きな要素（≥ 1000）を B とする。B より後ろの要素は、B が残っている限り消しても失敗し続けるので、全て消える。
  - B を消す候補は、B より前の要素（全て < 1000）の和が 1000 未満なら拒否される。
  - B より前の要素も全て消える。→ `[B]` になり、P4 と P3 が B を 1000 まで下げる（T1 の 2^28 と同じ経路、verification.md:56）。
  - 最小にならないのは、「B より前の小さな要素の和が ≥ 1000」の場合だけである。前置きの長さ K は幾何分布（P(K ≥ k) = 0.54^k）で、小さな要素の平均は 80 程度なので、ほぼ K ≥ 8（0.54^8 ≈ 0.7%）が要る。小さな要素で 500 を超えるものは稀（約 2.6%）である。
  - → **最小一致 ≥ 9/10**。
- 評価回数: P5 は要素数の約2倍、P3 による u16 の降下は数百回以下。→ 予算 2000 の中に収まる（測定のみ）。

**ゲート**:
- (1) 発見 ≥ 8/10、かつキー列 `[0, 1, 1000]` の一致 ≥ 8/10。
- (2) **分離用の対照と、seed ごとに shrunk choices と評価回数が完全に一致すること（10/10）**。
- (3) 表示: 各 seed で、`shrunk_draws` のテキストが次と一致する。これは D46 の再生成の正しさの検査である。
  - 縮めた列を、ターゲットの側で分離用の対照の生成器に通して replay し、`w` と `xs` をそれぞれ `std.fmt` でフォーマットしたもの。
  - 最小に達した seed では、これは `.wide` と `{ 1000 }` に当たる。std の `{any}` の正確な文字列は固定しない。
- (4) 縮めた列から作った regression エントリを replay すると、同じ `Failure`（`returned_false`）で失敗する（10/10）。
- (5) `reproduced == true` が 10/10。

**対照**: 判定を `sum(xs) >= 2^20`（決して届かない）にして 10/10 pass。

**分離用の対照**: **同じ draw をカスタム生成器に移した形**。`GeneratorWith` が `g.generate(Width)` に続けて `g.generate([]const u16)` または `g.generate([]const u4)` を呼び、struct `{ w, xs }` を返す。property はそれを受け取って同じ判定をする。v0.3 でそのまま書ける。
- **予測: v0.4 の対話的な形と、seed ごとに choice、キー、skip、span、shrunk choices、評価回数が完全に一致する。** 同じ primitive が同じ Source に同じ順で呼ばれる。T = `void` は draw も span も作らない（D49）。カスタム生成器の経路は、外側の struct に出現 span を付けない。生成のエラーの分類（discard、インフラ）も D41 と D42 により同じになる。
- **M0 で v0.3.1 のまま測り**、各 seed の shrunk choices と評価回数を参照値として記録する。

**なぜ判別できるか: 対話的な draw の記録が生成器の経路と一つでも違えば、shrink の軌跡が分かれ、ゲート (2) の完全一致が落ちる。違う点の例は、組の注釈の欠落、span の欠落、draw の順、property の後の検査の違いである。draw ログの再生成が誤っていれば、ゲート (3) が落ちる。**

**分離していないこと**:
- 状態に依存する draw は含まない（それは T10）。
- `steps` も含まない（slice の要素 span は `gen.generate` が作る）。

### T12 stateful な失敗の regression の永続性と stale の分類

**エントリの作り方**: T10 の mutant で seed 0〜9 の失敗から `regressionEntry` が印字したエントリを使い、印字されたテキストからパースし直す（T8 と同じ手順、validation/main.zig:663-670）。T11 のエントリも行 (f) で使う。

最小のエントリの choice の値は、全ての seed で同じ `[3, 0, 3, 0, 1, 0, 0, 3, 0]` になると予測する。
- P4 が値 0 の組を class 3 に書き換え（shrink.zig:575-589）、P2 はキーが変わらないのでそれを戻さない。
- 最小でない seed は、行ごとの結果を別に報告する。下のゲートの分母は、最小のエントリの seed とする。

| 行 | 変更 | 期待（最小のエントリについての trace） | ゲート |
|---|---|---|---|
| (a) | 同じ mutant で replay | 失敗として報告される。origin は regression、stale ではない、`HandleReused` | 10/10 |
| (b) | 正しい実装で replay | 3ステップを実行して pass、9 個全てを消費。passed、stale 0 | 10/10 |
| (c) | property を変える: insert が u8 の後に bool を1つ多く引く | 位置 2〜4 が step 0 の値と bool になり、step 1 と step 2 は insert になる。step 2 の u8 は位置 9 で列を越えて**枯渇する**。remove がないので判定は pass だが、D41 の 4 により **stale `discarded`** | 10/10 |
| (d) | property を変える: insert が値を引かない | 3ステップとも insert で pass、4 個しか消費しない。→ **stale `unconsumed_suffix`** | 10/10 |
| (e) | **既知の見逃し**: `Op` の宣言の順を `{ insert, get, remove }` に変える（draw の形は同じ） | step 1 の choose の値 1 が get を選び、remove が起きない。pass し、9 個全てを消費する。→ **passed（黙った見逃し）** | 10/10 で見逃す（限界の証拠として固定する。T8 (j) と同じ扱い） |
| (f) | T11 のエントリで `max_len` を 32 → 16 | stale `fingerprint_mismatch`（`max_len`）。D51 | 10/10 |

**なぜ判別できるか**:
- (c) は D41 の、property の後の枯渇の検査を分離する。その検査がなければ、0 で埋めた run は「pass、全て消費」となり、`passed` に数えられる。
- (f) は D51 を分離する。T = `void` は slice に到達しないので、`fingerprint.of` が `max_len` を 0 に正規化し、変更を検出しない。
- (a) と (b) は D40（平らな列が stateful な失敗を replay する）を検査する。

**分離していないこと**: draw の形を保ったままの意味の変更（(e)）は、原理的に検出できない。

### T13 決定性の違反の探り（測定のみ）

**property**:
- Ctx は `*u64` のカウンタ。評価のたびに +1 し、評価をまたいで状態を持ち越す（D48 の契約違反）。
- `x = try case.generate(u8)` を引き、`x >= 100` かつカウンタが偶数のとき失敗する。

**予測**:
- 発見 10/10。
- 最小は不安定である（同じ候補が評価の偶奇で受理されたりされなかったりする）。
- `reproduced == false` になる seed は、確認の評価の時点でカウンタが奇数になる seed で、おおよそ半分（5 ± 3/10）。正確な seed の集合は測るまで分からない。

**対照**:
- (i) カウンタを判定に使わない（持ち越しはするが結果に影響しない）property → `reproduced == true` が 10/10。**これは検出しない例として記録する。**
- (ii) 持ち越しのない property → 10/10 で true。

**扱い**: ゲートにはしない（測定のみ）。D48 が「何を検出し、何を検出しないか」の証拠として、verification.md に記録する。

### T14 末尾に依存する判定での要素削除（P5 の判別。v0.3.1 で測れる）

**型**: `[]const E`、`E = struct { a: u8, flag: bool }`。choice は要素あたり 3 個（a の組 2 個と flag 1 個）。既定の Limits。

**故障（意味を固定）**: SUT は、`a == 7` の要素の合計を誤る。ただし最後の要素の a が 0 なら誤らない。末尾のゼロが故障を隠す、という設計上の仕掛けで、P5 の分離のために意図して作った。
- → `xs` が a = 7 の要素を含み、かつ `xs[len−1].a != 0` のときに失敗する。

**期待する最小反例**: `[{7, false}]`、キー列 `[1, 7, 0]`。
- 一意性: 長さ ≥ 1。キー数は 1 + 2·長さなので、最小は長さ 1。その要素は a = 7（含むこと）を満たし、最後の要素の a も 7 で 0 でない。flag の最小は false。

**予測**:
- **発見**: 1要素が a = 7 になる確率 p は次の和で ≈ 0.0089 である。
  - class 0: 1/256。
  - class 2: 幅 3 の確率 1/9 と、その中の 1/4 で 1/36。
  - class 3: 1/256。
  - class 1: 0。
  - 各 class の確率 1/4 を掛ける。
  - 最後の a ≠ 0 の確率は ≈ 0.908。
  - 1 ケースの失敗率 ≈ 0.9·(1/33)Σ_{L=1}^{32}(1 − (1−p)^L) ≈ 0.116。→ **発見 10/10**。
- **P5 有効（v0.3.1 の既定）**: P5 は要素を後ろから、長さを下げながら消す。
  - 7 と最後の要素以外は、どれを消しても失敗し続ける。
  - 2要素 `[7, x]` や `[y, 7]` では、7 でない方を消すと `[7]` になる。
  - 1要素になると P2 が flag を 0 にする。
  - → **最小一致 ≥ 9/10**。
- **P5 無効（`ShrinkPassMask{ .p5 = false }`、shrink.zig:48-56）**: 最初の 7 の位置を f とすると、**f 個の `{0, false}` の後に `{7, false}` が続く形で必ず止まる**（キー列 `[f+1, 0,0, …, 7, 0]`）。根拠は場合を尽くしたもので、次のとおりである。
  - 長さを変えずに、P1/P1b が位置 0 を含まない chunk を消すと、次のどちらかになる。
    - (α) 大きさが 3 の倍数（要素の境界にそろう）なら、末尾の要素が全て 0 で埋まる。最後の a = 0 になり pass する。→ 拒否される。
    - (β) 3 の倍数でないなら、消した位置より後ろの要素は全てずれて読まれる。ずれた読み方では、a の値の draw に flag（0/1）か class（0〜3）が入り、a ∈ {0, 1, 2, 3, 254, 255} になる。7 は作られない。7 より前を消せば 7 が壊れて pass する。→ 拒否される。7 より後ろを消す場合は受理されることがあるが、前置きには触れない。
  - 位置 0（長さ draw）を含む chunk `[0, s)` の場合。
    - 3 の倍数にそろうのは s ∈ {3, 6} だけで、どちらも P1b のサイズであり、不動点でしか走らない（shrink.zig:510-518, 725-727）。新しい長さは前の要素の flag（0/1）になる。不動点ではどの flag も P2 で 0 になっている（property は flag を見ないので、0 にすると必ず受理される）。だから長さ 0 で pass する。
    - そろわない s では、(β) と同じく 7 が作られない。
  - P3/P2 で長さを下げると、末尾が落ちるだけで、前置きは残る。
  - P6 は同じ型の入れ子の出現がないので、候補を作らない。
  - P2/P3 は前置きの a と flag を 0 にする。
  - → P5 無効で `[7]` に達するのは、f = 0 のときだけである。
- **f = 0 の確率**: P(f = 0 | 失敗) ≈ Σ_L p / Σ_L (1 − (1−p)^L) ≈ 32p / 4.25 ≈ 0.067。10 seed 中で `[7]` に達する数の期待値は 0.67 で、二項分布で 3 以上になる確率は ≈ 2.5%。→ **P5 無効の最小一致 ≤ 2/10** と予測し、M0 で測る。

**ゲート（M0 で凍結する）**:
- P5 有効で発見 ≥ 8/10 かつ最小一致 ≥ 8/10、正しい実装の対照 10/10。
- 加えて、M0 で P5 無効の最小一致が ≤ 4/10 であること。
- M0 で P5 無効が 4/10 を超えたら、T14 は判別できないものとして、ゲートを凍結する前に取り下げる。その場合、(b) は「一部満たす」のままにし、目玉の判定を見直す（§1.4）。

**seed ごとの検査（測定のみ。予測の検査）**: P5 無効の各 seed で、発見したケースから f を読み、縮めた値が「f 個の `{0, false}` の後に `{7, false}`」と一致するかを数える。予測は 10/10 一致。一致しない seed があれば、上の場合分けに漏れがある。

**なぜ判別できるか: P5（長さを下げる要素削除）がなければ、7 より前の要素を消す経路は上の場合分けで全て塞がれる。P5 が壊れていれば、最小一致は f = 0 の確率（≈ 6.7% / seed）まで落ちる。**

**分離していないこと**: この判定は分離のために作った人工的なものである。実際の利用者の判定が末尾に依存する頻度は分からない。T14 が示すのは「P5 が必要な状況が存在し、そこで P5 が効く」ことだけである。

### 4.1 ゲートと測定のみの区別、T1〜T9e、掃引

- **ゲート**:
  - T10 の各項目。
  - T11 の (1)〜(5)。
  - T12 の (a)〜(d) と (f)。(e) は見逃すことのゲート。
  - T14（M0 の条件付き）。
  - T1〜T9e（v0.3 のゲートは不変）。
- **測定のみ**:
  - T10 の B2、P5 無効、評価回数、Limits による discard の数。
  - T11 の評価回数。
  - T13 の全て。
  - T14 の seed ごとの f の検査と、P5 無効の値そのもの（ゲートの条件として使うのは M0 の1回の値だけ）。
- **T1〜T9e（D59）**:
  - 各マイルストーンの終わりに、`zig build validation` の T1〜T9e の部分の出力が、M0 で記録したものと**バイト単位で一致**すること（`cmp`）。v0.3 の M4a/M4b と同じ方法（verification.md:70）。
  - 期待する効果はゼロである。どの変更も、property の中で draw しない property の経路を変えない（D41、D48 の範囲の限定）。
  - 一致しなければ、そのマイルストーンを差し戻す。数値の変化を説明できたとしても、v0.4 には意図した変化がないので、受け入れない。
- **A4（D60。掃引を実装または実行する前に登録する Amendment）**:
  - A3 の nightly の掃引（seeds 10〜109、design-v0.3.md:1173-1187、nightly.yml:28-52）に、T10、T11、T12、T14 を加える。
  - 主な成功の数: T10 は最小一致、T11 は最小一致と (2) の一致、T12 は各行、T14 は P5 有効の最小一致。80% を下回れば issue を開く。
  - T10 の B1/B2/P5 無効、T14 の P5 無効、T13 は、比率を印字するが issue は開かない。
  - 閾値、seed の範囲、ゲートは、結果を見た後に動かさない。

---

## 5. マイルストーン

**原則**:
- v0.3.1 のツリーで測れるものは、v0.4 のコードを書く前に全て測る（M0）。
- 生成を変えないものだけを順に積む。v0.4 には replay の意味を変える作業がない（D50）。

**全てのマイルストーンに共通する終了基準**（build.zig を確認した）:
- `zig build verify` が通る（fmt-check、lint、test、validation、bench smoke。build.zig:187-194）。AGENTS.md のとおり、`zig fmt --check` は非推奨の builtin の書き換えも見るので、これを省かない。
- `zig build pin-guard -Dpin-base=<前のマイルストーンのコミット>`（build.zig:129-148）が、(R) と (S) の pin に**変更なし**と分類する（M1 の追加は除く）。
- T1〜T9e の出力が `cmp` で一致する（D59）。
- `fix:` のコミットには `Defect-Class` と `Detected-By` の trailer を付ける（AGENTS.md）。

| M | 範囲 | 触るファイル | 追加するテスト | 終了基準（共通以外） | 含まないもの |
|---|---|---|---|---|---|
| **M0** 基準値（`~/workspace/scratch/` で。`/tmp` は使わない） | (z) v0.3.1 で `zig build verify` を記録し、validation の出力を `cmp` の参照として保存する。(a) T14 を P5 有効と P5 無効で測り、seed ごとの f を記録する。(b) T10-B1 と T10-B2。(c) T11 の生成器の形（seed ごとの shrunk choices と評価回数を参照値にする）。(d) Zig 0.17.1 で次のことを確かめる: `std.EnumSet` の API、型を消した関数ポインタを comptime で作れること、`{any}` で `void` を印字した形 | なし | — | 結果を研究ノートに記録する。予測との違いは Amendment として記録し、§1.4 の判定と T14 の取り下げ条件を適用してからレビューに戻す | src の変更 |
| **M1** `void` の生成（D49） | `generateNormal` に `.void => return {}`（gen.zig:156-223 の switch）。fingerprint はすでに `void` を扱う（fingerprint.zig:186） | src/gen.zig、tests/meta10.zig | (R) pin "void replays with zero draws"、`struct { x: void }` の pin（F6、design-v0.3.md:999） | pin-guard は追加だけと分類 | Case |
| **M2** Case の draw | `CaseState`、`Case.impl`、`generate`/`index`/`choose`、property の後の検査（D41）、discard のフラグ（D42）、error-contract.zon の ref の更新 | src/shrink.zig、tools/lint/error-contract.zon | tests/meta13.zig（新）: 記録、検査の順、discard とエラーの区別、choose の draw の数 | T11 のゲート (1)、(2)、(4) | 表示、steps |
| **M3** draw ログ（D46、internal だけ） | Source の `recorded_draws`、`AttemptResult.fail.draws`、shrinker の best、`ShrinkResult.draws`、フォーマットの関数を shrink.zig に下ろす | src/source.zig、shrink.zig、runner.zig | meta13 の draw ログのテスト、oom.zig に property の中で draw する場合を追加 | formal-drift が `shrinkWith` の hash の変化を報告するので、manifest の hash を更新し、TLA+ が draw ログを反映していないことを known gaps に1行足す（plan §2-5 ① の (b)） | Report のフィールド |
| **M4** steps（D45） | `Case.steps`、`Steps.next`、開いている span を閉じる処理 | src/shrink.zig、validation/main.zig | meta13 の steps のテスト | T10 のゲート（表示を除く）、T10 の P5 無効を記録 | Report |
| **M5** 報告と互換性 | `Report.Failed` のフィールド（D47）、`reproduced`（D48）、`Fingerprint.property_draws`（D51）、`*OrError` の印字、api_surface.zig の拡張（D61） | src/runner.zig、fingerprint.zig、tests/api_surface.zig、meta11、meta12 | meta12 の追加、meta11 "fingerprint: property_draws keeps limits"、`tests/meta12_entry.zon` が無変更で通ること | T10 の表示、T11 (3)(5)、T12、T13 を記録。`zig build compile-budget`（build.zig:160） | — |
| **M6** 記録と文書 | README のレシピ（§3.2）、verification.md の行 34 以降、A4 の登録（掃引の実装より前のコミット）、nightly への追加 | docs/、README.md、.github/workflows/nightly.yml、validation/main.zig | — | §4 の全ゲートを記録する | コードの変更 |

**依存関係**: M0 → M1 → M2 → M3 → M4 → M5 → M6。M1 は M2 以降から独立しているが、T = `void` を使うターゲットの前提になる。

**見送り方**:
- M4（steps）を見送ると、T10 は書けない。v0.4 は T11、T12 (f)、T14 だけを出す。
- M5 の `reproduced` だけを見送ることはできる（T13 を取り下げる）。

---

## 6. Nat↔u64 の橋渡し（形式）

### 6.1 今証明されていないもの（ファイルで確認した）

- `formal/lean/ZigpropFormal/` には `Normalize.lean`、`Zigzag.lean`、`Shortlex.lean`、`Measure.lean` の4つしかない。計画が提案した `Bridge.lean`（plan §2-5 の表、`verification-pipeline-zigprop-plan-by-opus-2026-11-19.md:53`）は**存在しない**。
- `normalize` は `Nat` の上で定義されている: `if bound = 0 then value else value % bound`（Normalize.lean:18-19）。実装は u64 で `if (bound == 0) raw else raw % bound` である（source.zig:333）。
- zigzag は `Int`/`Nat` の上の全単射、絶対値の式、単調性である（Zigzag.lean:14-98）。実装は i128 を経由して `@intCast` する（gen.zig:390-410）。
- `shortlex` は `List Nat` の上で長さを先に比べ、`List.Lex` で比べる（Shortlex.lean:24-25）。**skip の除外はモデルにない**。実装は skip を除いた u64 のキー列を二つのポインタで比べる（shrink.zig:246-260）。
- `measureLt` は `List Nat × Nat` の上で整礎である（Measure.lean:33-37）。
- manifest の `checked_against`（formal/manifest.zon:14, 23, 33, 42）は次のように書いている。v2.1 と v0.3 に対して再検査していないことも書かれている。ブリーフの要約は**ファイルと一致する**。
  - 「The u64 bridge is not proved」（Normalize）。
  - 「The fit to finite integer types is not proved」（Zigzag）。
  - 「that comparison and the u64/Nat bridge are not proved」（Shortlex）。
- verification.md の known gaps（:94-98、:145-160）も同じである。
- `check-axioms.sh` は 13 個の定理を監査している。どれも Nat/Int の上の定理である。
- 私は `lake` を実行していない。

### 6.2 橋渡しが述べること

| # | 主張 | core Lean で届くか | 見積もり |
|---|---|---|---|
| B1 | `UInt64` 版の `normalizeU b v := if b = 0 then v else v % b` について `(normalizeU b v).toNat = normalize b.toNat v.toNat` | 届く見込み。`UInt64` の `%` と `toNat` の補題（core にあると予想するが、確認していない） | 0.5 日 |
| B2 | 幅 W（1 ≤ W ≤ 64）の符号付き整数の範囲 −2^(W−1) ≤ x < 2^(W−1) で `zigzagEncode x < 2^W`。`Int` 版のランクとの一致 | 届く（範囲の仮定のもとで `omega`） | 1 日 |
| B3 | skip を除いたキー列の比較のモデル `keyLess : List (UInt64 × Bool) → … → Bool` が、`shortlex ((filter …).map toNat)` と同値 | 届く見込み。二つのポインタのループを構造的再帰で書き直し、帰納法で示す。リスクはループのモデルの忠実さ | 1.5〜2 日 |

**どれも、Lean のモデルと Zig のコードの間の隙間は閉じない**。Lean の関数は Zig の関数を手で書き写したものであり、対応は論証と manifest のハッシュによるずれの検出（formal-drift）にとどまる。

**対話的な draw で新しく証明されていないものになるか**:
- 算術の面では、**ならない**。property の中の draw も同じ `Source.draw` を通る。`index` と `choose` の動的な bound も `% bound` の正規化に従い、B1 の範囲に入る。キーの比較も同じ `keyShortlexLess` である。
- プロトコルの面では、TLA+ のモデルは `Failing` を固定の集合として扱う（verification.md:23）。property が draw すると、消費される列そのものが property の振る舞いで決まる。したがって「P(C) は C の関数である」という仮定が、これまでの「判定は決定的」に加えて「draw の構造も決定的」（D48 の契約）に依存するようになる。これは証明の義務ではなく、モデルの仮定として TLA+ の冒頭のコメントに一行書くものである（M3 の known gaps の行と合わせる）。

### 6.3 選択肢と推奨

- 選択肢:
  - (A) 全て（B1〜B3）。3〜3.5 日。
  - (B) 一部（B1 と B2）。1.5 日。
  - (C) 先送りを続ける。
- **推奨: (C)、v0.4 の計画には入れない → D62 は OUT**。理由は次のとおり。
  - 計画が先送りした理由は、golden pin（meta10 の (R) pin 147 個、verification.md:39）が、整数の全ての幅と class について、B1 と B2 の範囲のかなりを既に見張っている、ということだった（plan:432）。**v0.4 は正規化も zigzag も変えないので、この理由は変わらない。**
  - B1 と B2 が加える証拠の形は「全ての入力について（Lean のモデルの上で）」である。pin が見ている端点（u64、i64、W = 16/17 など）での桁あふれは、すでに pin が見ている。
  - **ただし、計画の理由は B3 には当てはまらない**。B3（skip を除いたキーの比較）を見ている pin はない。pin は生成の pin である。比較は meta9 のフック（verification.md:41）で、実際に起きた受理を観測しているだけである。
  - v0.4 は、対話的な draw により skip の並びを多様にする（組と index の draw が交互に並ぶ）。それでも関数は同じであり、観測している範囲が広がるだけで、誤りの種類は増えない。
  - **v0.4 の危険は、記録と property の後の検査（D40〜D46）にあり、算術にはない。** v0.4 の工数はそこに使う。
- 取り組む場合の順序とコスト:
  - **B3 を先に**（1.5〜2 日、リスク中。ループのモデルの忠実さ）、次に B1 と B2（1.5 日、リスク低）。
  - CI に要るもの:
    - `check-axioms.sh` の監査の一覧に新しい定理名を足す（今は 13 個）。
    - `formal/manifest.zon` に `Bridge.lean` のエントリを足す（`src/source.zig` の `draw`、`src/gen.zig` の `rankToValue`/`valueToRank`、`src/shrink.zig` の `keyShortlexLess`）。
    - formal.yml は lake で `ZigpropFormal` 全体を build する（formal.yml:41-44）ので、`ZigpropFormal.lean` に import を足すだけで済む。
    - TLA+ の構成は変えない。

---

## 7. 互換性

### 7.1 D50: `generator_version` は 2 のまま

- `generator_version` は、正規化された列の replay の意味だけを追う（D16、gen.zig:11-17）。
- 既存のエントリは、property の中で draw しない property から記録されたものである。v0.4 は値の生成のコード（gen.zig の全ての既存の分岐）も、`Source.draw` も変えない。だから既存のエントリの replay は変わらない（論証）。
  - 機械的な検査: 各マイルストーンで pin-guard が (R) pin に変更なしと分類すること。
- `void` の生成（D49）は、これまでコンパイルエラーだった型にだけ意味を与える。記録済みの列は存在しないので、どの列の意味も変えない。
- **stateful なエントリの意味は、型 T ではなく property の draw の構造に依存する**。これは T8 (j) のカスタム生成器と同じ形である（design-v0.3.md:942）。`generator_version` はライブラリの生成の意味を追うものであり、利用者の property の変更は追わない。

### 7.2 D51: `Fingerprint.property_draws`（limits を正規化しないモード）

**問題（発見したもの）**:
- `fingerprint.of(T, limits, custom)` は、T が slice に到達しなければ `max_len` を、再帰型でなければ `max_depth` を 0 に正規化する（design-v0.3.md:376-381、runner.zig:474）。
- T = `void` の property が `case.generate([]const u16)` を引くと、長さの bound は `max_len + 1` になる。`max_len` を変えると同じ列が別の長さに replay されるのに、fingerprint は変わらない。
- カスタム生成器については、v0.3 は同じ理由で limits を正規化しない（design-v0.3.md:381）。

**決定**:
- `Fingerprint` に `property_draws: bool = false` を足す。
- 失敗した評価の draw ログが空でなければ、報告の fingerprint を「limits を正規化しないモード」で計算し、`property_draws = true` にする。
- regression の段階では、エントリの `property_draws` を見て、比較のための現在の fingerprint を同じモードで計算する（runner.zig:493-499 の比較の前）。
- 印字は `property_draws = true` のときだけ `.property_draws = true` を出す。既存のエントリの印字は変わらず、`tests/meta12_entry.zon` の往復の固定は無変更で通る。
- **互換性**: `Fingerprint` と `Regression` は ZON の中のデータ型であり、既定値付きのフィールドの追加は v0.3 §7.5 で互換である。欠けたフィールドに既定値が入ることは、M0-c でも meta11 でも確認済みである（verification.md:44）。
- 証拠: (予定) T12 (f) のゲート、meta11 のテスト。

### 7.3 D52: property の draw の構造を fingerprint に入れる仕組み: OUT

- 選択肢:
  - (A) 何もせず、既知の見逃しとして固定する（T12 (e)）。
  - (B) 利用者が上げる `Config.property_version: u32 = 0` を fingerprint に入れる。
  - (C) 実行時に draw の型の並びをハッシュする。
- **推奨: (A)**。
  - (B) は、利用者が変更を自覚しているときにしか効かない。そのうえ `Config`、`Fingerprint`、`FingerprintMismatch` の3つの公開型にフィールドを足すことになる。
  - (C) は replay した後でしか計算できない。型の並びが変われば、多くの場合は discard や suffix として既に検出される（T12 (c)(d)）。
  - (B) は、利用者から要求が出れば1マイルストーンで足せる（Q5）。
- **無料で得られる stale の検出**（`StaleReason`、runner.zig:79-89）:
  - draw が増えれば枯渇（`discarded`、D41）。
  - 減れば `unconsumed_suffix`（runner.zig:510-514）。
  - 生成でも property の中でも、要素予算や `max_draws` を超えれば `discarded`。
  - **形を保ったままの意味の変更は検出できない**（T12 (e)）。

### 7.4 regression ファイルの意味

- エントリは1本の平らなタプルのままである（D40、`regressionEntry` は不変）。
- replay するものは次の3つである。
  - (1) T の値の生成。
  - (2) property が SUT とモデルを最初から作る（D55）。
  - (3) 同じ draw を同じ順に行う。
- 貼ったエントリが有効であり続けるには、生成器、property の draw の構造、SUT の意味が変わっていないことが要る。
- `RegressionFile` の ZON のスキーマで変わるのは、`Fingerprint` に既定値付きの任意フィールドが1つ増えることだけである（D51）。ファイルの `version` は 1 のまま（runner.zig:52-55）。
- `tests/regressions.zon` は変更しない。

### 7.5 公開 API の追加の一覧（v0.3.1 の公開物は一つも変えない）

| 追加 | 種類 | v0.3 §7.5 / api_surface.zig との関係 |
|---|---|---|
| `Case.impl: ?*internal.CaseState = null` | 公開 struct への既定値付きフィールド | 互換（既定値付き）。api_surface は Case のフィールドを固定していない |
| `Case.generate`、`Case.index`、`Case.choose`、`Case.steps` | メソッド | 互換（宣言の追加）。root の pub 宣言は増えない |
| `Case.Steps` と `Steps.next` | 入れ子の型 | 同上 |
| `Report.Failed.original_draws`、`shrunk_draws`、`reproduced` | ペイロードへの既定値付きフィールド | 互換（design-v0.3.md:851。variant の集合は不変） |
| `Report.Failed.Drawn` | 入れ子の型 | 互換 |
| `Fingerprint.property_draws: bool = false` | ZON のデータ型への既定値付きフィールド | 互換（ZON で欠けても既定値が入る） |
| `void` を T として生成できる | 振る舞いの追加 | これまでコンパイルエラーだった |
| internal: `CaseState`、`DrawEntry`、`Source.recorded_draws`、`AttemptResult.fail.draws`、`ShrinkResult.draws` | internal | 安定性の保証なし（D28） |

- **root の pub 宣言の一覧（api_surface.zig:66-77）は変わらない**。`Report` と `Failure` の tag も、`Config` と `Limits` のフィールドも変わらない。→ 今の api_surface.zig は無変更で通る。
- **D61**: Case の pub 宣言とフィールド、`Report.Failed` のフィールド、`Fingerprint` のフィールドを api_surface.zig の固定に加える。v0.4 から、これらは約束する面になるからである。§1.1(a) で見つけた「Case と checkWith が固定されていない」隙間も、これで塞ぐ。`checkWith` のシグネチャは `@TypeOf` の比較で固定する（Zig 0.17.1 で書けるかは M0 で確かめる）。
- `forAll` は予約のままにする（root.zig:4-5、v0.3 Q5）。

### 7.6 seed の互換

- v0.4 は `Source` の sampler も、`deriveSeed` も、gen の既存の分岐も変えない。
- 既存の property について、seed から列への対応は変わらない。
- 機械的な検査: `tests/meta10.zig` と `tests/meta10_rec.zig` の (S) pin が、各マイルストーンで pin-guard により変更なしと分類されること。

---

## 8. 決定の一覧（D38〜）

| id | 論点 | 決定 | 根拠（一行） | 依存 |
|---|---|---|---|---|
| D38 | v0.4 の目玉 | **PARTIAL**: 対話的な draw を目玉にし、モデルベーステストはレシピとして示す。stateful フレームワークを目玉にすることは得られていない。M0 の T14 と T10-B1 を条件にする | (d) が満たされず、(a) は形式上だけで、T10 で B2 が同等と予測される | D53, D58 |
| D39 | Case から生成状態への経路 | **IN**: `Case.impl: ?*internal.CaseState = null` とメソッド | D27 の拡張の余地に乗り、`GenContext.impl` の前例の中で D28 を守る | — |
| D40 | 記録の形 | **IN**: 同じ Source に、値の draw の後に、平らな1本の列として記録する。`choices` とエントリの意味は「消費された列の全体」 | 受理規則、パス、ZON が全て1本の列を前提にしている | D39 |
| D41 | property の後の検査 | **IN**: sticky → limit / discard → 枯渇（runner のみ）の順。判定より優先する | 枯渇した replay の判定はエントリについての判定ではない。既存の property では挙動不変 | D40 |
| D42 | property の途中の discard | **PARTIAL**: ライブラリが起こすもの（要素予算、空の選択肢）はフラグで discard にする。利用者が求める discard は OUT | エラー名で制御を流さず、D27 を変えない。利用者の需要は未確認 | D41 |
| D43 | キー注釈と span | **IN**: `gen.generate(T, gctx)` の同じ経路を通る。並行する経路は作らない | 構成によって同じになり、span の誤りの代償は効率だけ（D18） | D39 |
| D44 | 動的な bound の draw | **IN**: `index(n)` と `choose(E, enabled)`。常に1回 draw し、空なら discard | 前のステップを消しても、各ステップの最初の choice が種類を表し続ける | D42 |
| D45 | 繰り返しの構造 | **IN**: `steps(max)` は長さ draw と既存の `.element` span。新しい variant もパスも作らない。早く返ったときは開いている span を閉じる | P5 が無変更で働き、健全性は `tryAccept` だけで保たれる | D43 |
| D46 | 中で引いた値の表示 | **IN**: draw ログ（再生成、property を呼ばない）。所有は span と同じ経路 | D30 の上に乗る。property を再実行すると、非決定的なときに表示が誤る | D40, D30 |
| D47 | `Report.Failed` の追加 | **IN**: `original_draws`、`shrunk_draws`、`reproduced`、`Drawn`。どれも既定値付き。印字は `*OrError` だけ | v0.3 §7.5 でペイロードへの追加は互換 | D46, D48 |
| D48 | 決定性の契約と再現の確認 | **IN**: 契約を明文化する。draw した場合だけ、縮めた列を regression と同じ条件で1回 replay する | 貼ったエントリの再現をその場で確かめ、既存の固定（meta3）を動かさない | D41 |
| D49 | `void` の生成 | **IN**: 値の draw なしで `{}` を返す | stateful な property の T。これまでコンパイルエラーだったので、既存の列は変わらない | — |
| D50 | `generator_version` | **IN**: 2 のまま | 既存の型の replay の意味は変わらない | D49 |
| D51 | `Fingerprint.property_draws` | **IN**: draw した失敗では limits を正規化しない | T = `void` での `max_len` の変更を検出する（T12 (f)） | D46 |
| D52 | property の draw の構造の fingerprint | **OUT**: 既知の見逃しとして固定する（T12 (e)） | 利用者が上げる版数は、変更を自覚しているときにしか効かない | D51 |
| D53 | stateful フレームワーク（comptime interface） | **OUT**（利用者のシナリオと繰り返しのコピーが出るまで） | shrink に要るのは D44 と D45 だけ。interface の形を決める材料がない | D38 |
| D54 | コマンドの表現 | **IN**（レシピ）: 種類の `enum` を `choose` で選び、payload は種類ごとに draw する | 状態に依存する payload と前提条件を、payload より前に表せる | D44 |
| D55 | モデルと SUT の寿命 | **IN**（契約とレシピ）: 評価ごとに property の中で `case.allocator` から作る。Ctx は設定だけ。後片付けは `defer` | arena によりリセットとリークの無さが構成で決まる | D48 |
| D56 | 不変条件と事後条件 | **IN**（レシピ）: 利用者のコードで、検査ごとに別のエラー名を返す | `Failure.eql` が違反の種類を保つ。新しい機構は要らない | D27 |
| D57 | 失敗の報告 | **PARTIAL**: step と引いた値は IN。モデルと SUT の状態の表示は OUT | property を呼ばずに状態を得る方法がない | D46 |
| D58 | 検証ターゲット T10〜T14 | **IN**: 予測を今登録し、M0 で v0.3.1 の基準値を測ってからゲートを凍結する | A2 の教訓: 判別できることを、測ってから約束する | — |
| D59 | T1〜T9e | **IN**: 各マイルストーンで出力がバイト単位で一致する | 対話的な draw の追加が既存の数値を黙って動かさないことを、マイルストーンごとに確かめる | D41, D48 |
| D60 | A4（掃引への追加） | **IN**: T10、T11、T12、T14 を A3 の掃引に加える（実行する前に登録する） | 10 seed で判別できないものの判別力を測る | D58 |
| D61 | api_surface の拡張 | **IN**: Case の宣言とフィールド、`Failed` と `Fingerprint` のフィールド、`checkWith` のシグネチャを固定する | 「変わっていない」をテストで示せるようにする（§1.1(a) の隙間） | D39, D47, D51 |
| D62 | Nat↔u64 の橋渡し | **OUT**（v0.4 の外の形式の作業。取り組むなら B3 を先に） | v0.4 は算術を変えず、pin による先送りの理由は B1 と B2 について変わらない | — |

集計: IN 19（D39〜D41, D43〜D51, D54〜D56, D58〜D61）/ PARTIAL 3（D38, D42, D57）/ OUT 3（D52, D53, D62）。

---

## 9. ユーザーに決めてほしいこと

1. **Q1: v0.4 の目玉を「対話的な draw（モデルベーステストはレシピ）」にしてよいか？**
   - 推奨: する（D38）。
   - (d) が満たされていないこと、v0.3 の B2 の書き方で同等のテストが書けると予測されること（T10）は、README と CHANGELOG に明記する。
   - 反対の場合（stateful フレームワークを目玉にする）: D53 を IN にし、comptime の interface を設計して凍結することになる。利用者のシナリオがないまま形を決めるので、v0.5 で壊す危険を負う。
   - 反対の場合（v0.4 では何も出さない）: T14 と、B2 の書き方の README のレシピだけを v0.3.2 として出し、対話的な draw は利用者が現れるまで待つ。
2. **Q2: in-repo のシナリオ（SlotMap）で進めるか、実際の利用者を待つか？**
   - 推奨: in-repo で進め、(d) は満たされていないと明記する（§1.3）。
   - 反対の場合: M2 以降を、利用者のシナリオが1件出るまで止める。M0（基準値）と T14 は今やってよい。
3. **Q3: 利用者が求める property の途中の discard（`case.reject()`）を入れるか？**
   - 推奨: 入れない（D42）。
   - 反対の場合: `Case` にメソッドを1つ足す（フラグを立てて運び手のエラーを返す）。`max_discards` に数えるかどうかを決める必要がある（推奨するなら、数える）。
4. **Q4: 報告の前に property を1回余分に動かすこと（D48 の再現の確認）は受け入れられるか？**
   - 推奨: 受け入れる。draw する property に限り、1失敗につき1回である。
   - 反対の場合: `reproduced` を作らず、T13 は「今は何も検出しない」の測定になる。貼ったエントリが replay で失敗しないことを知るのは、利用者が貼った後になる。
5. **Q5: 利用者が上げる `property_version` を v0.4 に入れるか？**
   - 推奨: 入れない（D52）。
   - 反対の場合: `Config`、`Fingerprint`、`FingerprintMismatch` に既定値付きのフィールドを1つずつ足し、T12 (e) は「版を上げれば検出する」行に変わる。
6. **Q6: Nat↔u64 の橋渡しを v0.4 に入れるか？**
   - 推奨: 入れない（D62）。別の作業として取り組むなら、B3（キーの比較）を先にする。
   - 反対の場合: M6 の後に B3 → B1/B2 の順で3〜3.5日を足す。v0.4 のリリースは遅れるが、マイルストーンの依存関係には影響しない。

---

## 10. レビューで最初に突いてほしい点

- **H1（D41）**: 「draw しない property では、property の後の検査はどれも発火しない」という主張。Source のフラグを property の実行中に変えうる経路を、私が見落としていないか。生成器が `GenContext` を隠し持つ病的な例は §2.4 で除外したが、他にあるか。
- **H2（D46）**: 部分列だけを新しい `GenState` で再生成すると、property が見た値と同じになる、という論証（深さ、要素予算、正規化、0 埋め）。カスタムの `format` や、`max_depth` に依存する再帰型を中で引いた場合に崩れないか。
- **H3（T14）**: P5 なしでは前置きを消す経路が全て塞がれる、という場合分け。特に (β) の「ずれて読むと a ∈ {0, 1, 2, 3, 254, 255}」と、P1b の s ∈ {3, 6} が不動点でしか走らないこと（shrink.zig:725-727）。ここが誤っていると、T14 は A2 の失敗を繰り返す。
- **H4（T10、§0）**: B2 が v0.4 と同等になるという予測が正しいなら、v0.4 の価値は使い勝手と表示である。それが minor のリリースの目玉に値するか（Q1）。予測が誤りで、B2 が v0.4 より弱いなら、その理由は何か。
- **H5（D44）**: 「常に1回 draw する」choose が、切断の m = 1 の規則（gen.zig:371）と違う扱いをすることの正当化。空の集合を discard にすることが、shrink で失敗を隠す（候補を拒否し続けて最小に届かない）ことにならないか。
- **H6（D51）**: limits を正規化しないモードの判定を、失敗した評価の draw ログで行うこと。draw しない経路で記録されたエントリを、後で draw するように変えた property で replay した場合に、穴が残らないか（予想: suffix か枯渇として検出される）。
- **H7（D42）**: ライブラリが discard のフラグを立てた後に、利用者が `false` を返した本物の失敗を discard として隠すことは受け入れられるか。
- **H8（§1.2）**: 「早く返る書き方では P5 は要らない」という予測。T10 の P5 無効の測定がこれを反証しうる。反証されたら、(b) の前提は T10 でも成り立つことになる。

---

## Amendment A-M0（2026-11-22、M0 の測定に基づきディレクターが採用）

測定: `research_notes/zigprop-v0.4-m0-measurements-by-opus-2026-11-22.md`（HEAD `1cab5f7`、seed 0..9、`max_cases = 200`、`shrink_budget = 2000`）。

- T14: 発見 10/10、P5 有効の最小一致 10/10、**P5 無効の最小一致 0/10**（ゲート条件 ≤ 4/10 を満たす）。**T14 は判別できる** — §6.2 条件 (b) の P5 前提は、T7（A2）と違い、今回は実測で支持された。
- T14 の seed ごとの f の形の予測は 6/10（予測 10/10）で**不一致**。前置きの形は 10/10 一致したが、seed 1, 4, 6, 7 では 7 の後ろが消えず末尾が残った。場合分けの漏れは P5 無効の縮小を `[7]` から遠ざける向きにしか働かないので、判別条件への影響はない（詳細は測定ノート §5）。
- T10-B1: 発見 0/10（予測どおり。B1-sanity 変種が 10/10 発見し、ハーネスの欠陥でないことを確認済み）。T10-B2: 発見 10/10、最小一致 10/10（キー列 `[3, 0, 0, 1, 0, 0, 0]`）。
- §1.4 の「目玉を見直す」条件（T14 > 4/10 または B1 ≥ 1/10）には当たらない。**目玉の判定（D38 PARTIAL）は不変**。
- ゲートの凍結値: 測定ノート §6 の提案をそのまま採用する（T14 / T10 / T11）。
- 実装上の確定事実: `std.EnumSet` は 0.17.1 では `.empty` から始める（§3.2 のコード片の `initEmpty()` は誤り）。D44 の「宣言順」は `EnumSet.iterator()` の値順では守れないので、宣言順に数える実装が要る。D61 の `checkWith` 固定は測定ノート §4.4-4 の代替による。
