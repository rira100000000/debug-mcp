# debug-rspec (workflow guide)

テストが失敗した瞬間——assertionが失敗した、または例外がraiseされた時点——でプロセスを止め、AIエージェントを送り込んで内部状態を診断させるワークフローのガイド。

IMPROVEMENT_AND_GROWTH_PLAN.md「機能拡張の候補 1. テスト失敗デバッグ(debug-rspec)」の実機検証にあたる。**debug-mcpが提供するのは観測プリミティブと、この文書による紹介まで**である(後述「責務の境界」)。同梱するコードは `hook.rb`(5行のコピペ用スニペット)と `demo_spec.rb`(試すためのバグ入りspec)のみで、ラッパーコマンドや通知フックのような機構は持たない。

## 何が嬉しいか

RSpecの失敗レポートは「期待値と実際の値」しか教えてくれない。失敗した瞬間のローカル変数、インスタンス変数、メモ化の中身は、レポートが出た時点ではもう消えている。

このワークフローでは失敗の**raiseの瞬間**にプロセスを止める。スタックはまだ巻き戻っておらず、失敗したexampleのフレームも、その中のオブジェクトの内部状態もすべて生きている。そこにdebug-mcp経由でAIエージェントが接続し、事実を見て原因を特定する。**修正仮説を、止まったプロセスの中でevaluate_codeして検証してから**コードを直すこともできる。

再現できないflakyテストに対して特に強い。「もう一度実行して再現を試みる」必要がなく、失敗したその実行を保全して調べられる。

## 使い方

必要なのは「デバッグソケットをノンストップで開き、失敗の例外にcatchを仕込む」5行のフック(`hook.rb`)だけ。`rspec --require` で読み込む。

```bash
RUBY_DEBUG_OPEN=true RUBY_DEBUG_HOST=127.0.0.1 RUBY_DEBUG_PORT=12888 \
RUBY_DEBUG_NONSTOP=true RUBY_DEBUG_NO_RELINE=true \
  rspec --require ./examples/debug_rspec/hook.rb spec/models/cart_spec.rb

# 捕捉する例外を追加(デフォルトは ExpectationNotMetError のみ)
DEBUG_RSPEC_CATCH="RSpec::Expectations::ExpectationNotMetError,NoMethodError" \
RUBY_DEBUG_OPEN=true ... rspec --require ./examples/debug_rspec/hook.rb spec/...
```

毎回打つのは長いので、自分のシェルに関数として置くとよい(これはユーザーランドの道具であり、本gemは提供しない):

```bash
debug_rspec() {
  RUBY_DEBUG_OPEN=true RUBY_DEBUG_HOST=127.0.0.1 RUBY_DEBUG_PORT="${DEBUG_RSPEC_PORT:-12888}" \
  RUBY_DEBUG_NONSTOP=true RUBY_DEBUG_NO_RELINE=true \
    rspec --require /path/to/hook.rb "$@"
}
```

失敗するとプロセスがraiseの瞬間でsuspendし、stderrに `DEBUGGER: wait for debugger connection...` が出て止まる。あとはエージェント(またはあなた)がdebug-mcpで接続して調査する:

> 「テストが失敗してpause中。debug-mcpで 127.0.0.1:12888 に接続して、失敗したexampleのフレームの変数を調べて原因を特定して」

調査が終わったら `continue_execution` で次の失敗へ進むか、テストを完走させる。RSpecは通常どおり失敗レポートを出して終了する。

環境変数(hook.rbが読むもの):

| 変数 | 意味 | デフォルト |
|---|---|---|
| `DEBUG_RSPEC_CATCH` | 捕捉する例外クラス(カンマ区切り) | `RSpec::Expectations::ExpectationNotMetError` |
| `DEBUG_RSPEC_FORCE` | `1` でCI検出時の自動無効化を上書き | なし |

ポート等は debug gem 標準の `RUBY_DEBUG_*` をそのまま使う。

### 組み合わせのパターン(紹介のみ・機構は同梱しない)

- **エージェントの自動召喚**: 「suspendしたら何かを起動する」はシェルで組める。debug gemがstderrに出す `wait for debugger connection` を合図に使う:

  ```bash
  debug_rspec spec/foo_spec.rb 2> >(tee /dev/stderr | \
    grep -m1 --line-buffered "wait for debugger connection" > /dev/null && \
    claude -p "テスト失敗でpause中。debug-mcpで127.0.0.1:12888に接続して診断して" &)
  ```

  何を呼ぶか(claude、codex、Slack通知、ログ)はユーザーの領分。debug-mcpはこの起動機構を提供しない(理由は「責務の境界」)。

- **罠パターン(低確率flakyの捕獲)**: 発火するまで回して放置する。

  ```bash
  while debug_rspec spec/models/order_spec.rb; do :; done
  ```

  失敗した瞬間にsuspendするためループはそこで止まったままになり、現場が保全される。繰り返し実行の機構(最大試行回数、seedローテーション等)はテストツールの領域なので同梱しない。

- **レシピ: 失敗→召喚→診断レポート作成**: 上記2パターンの合成形。ユーザー側スクリプト(例: `bin/debug-rspec-report`)として持つ。

  ```bash
  #!/usr/bin/env bash
  PORT="${DEBUG_RSPEC_PORT:-12888}"
  REPORT="tmp/flaky_report.md"

  RUBY_DEBUG_OPEN=true RUBY_DEBUG_HOST=127.0.0.1 RUBY_DEBUG_PORT=$PORT \
  RUBY_DEBUG_NONSTOP=true RUBY_DEBUG_NO_RELINE=true \
  rspec --require ./spec/support/debug_rspec_hook.rb "$@" 2> >(
    tee /dev/stderr | grep -m1 --line-buffered "wait for debugger connection" >/dev/null && \
    claude -p "RSpecが失敗し、プロセスが失敗のraise時点でpauseして待機中(127.0.0.1:$PORT)。
  debug-mcpで接続し、btで失敗したexampleのフレームへ移動して、ローカル変数と
  インスタンス変数から根本原因を特定して。修正仮説はevaluate_codeでその場で検証。
  別の失敗でまた止まったら同様に調査し、最後はcontinue_executionで完走させること。
  終わったら診断レポート(失敗ごとの根本原因、実行時に確認した事実、修正案)を
  $REPORT に書いて。コードの修正はしないこと。" \
      --allowedTools "mcp__debug-mcp,Write" &
  )
  ```

  事前に `claude mcp add debug-mcp -- debug-mcp` で登録しておく。プロンプトの要点は3つ——**完走までcontinueさせる**(でないとテストが止まりっぱなしになる)、**レポートの書き先を明示する**(ファイルの代わりに `gh pr comment` や Slack への送信でも可)、**修正の可否を明示する**(レポート目的なら「修正はしない」、修正までさせるなら Edit を許可に足す)。pause→後付け接続→診断→continue→完走のコアと、ヘッドレスエージェントによる無人診断は machine-verified(前節)。stderr 合図での自動召喚はコマンド発火まで確認済み。

## デモ

`demo_spec.rb` に「実行時にしか分からない」バグを2つ仕込んである。

1. メモ化ずれ: `Cart#total` が初回呼び出しで `@total` にメモ化され、`#add` で無効化されない → 2回目のassertionが失敗する
2. 未代入ivar: `Cart#summary` が一度も代入されない `@coupon` に `.code` を呼ぶ → NoMethodError

```bash
cd examples/debug_rspec
DEBUG_RSPEC_CATCH="RSpec::Expectations::ExpectationNotMetError,NoMethodError" \
RUBY_DEBUG_OPEN=true RUBY_DEBUG_HOST=127.0.0.1 RUBY_DEBUG_PORT=12888 \
RUBY_DEBUG_NONSTOP=true RUBY_DEBUG_NO_RELINE=true \
  rspec --require ./hook.rb demo_spec.rb
```

## 仕組みと設計判断

- `hook.rb` は `debug/open_nonstop` でデバッグソケットを開き(クライアントを待たない)、`DEBUGGER__::SESSION.add_catch_breakpoint` で catch ブレークポイントをプロセス内から仕込む。
- **クライアントなしで仕込むのが要点。** セットアップ用クライアントが接続して catch を設定してから切断すると、debug gem の仕様でプロセスが自動再開してしまい、pause を保てない(SESSION_STABILITY_INVESTIGATION.md「切断時の自動再開」)。
- **プロセス内フックが必要なのは実測による。** `rdbg --open --nonstop -e 'catch ...'` のようにCLIの初期コマンドだけで済ませる(コード同梱ゼロの)構成を試したが、クライアント不在では catch が効かずテストが素通りした。5行のフックが物理的な下限である。
- catch にヒットするとプロセスは suspend し、クライアント接続を待つ。

## machine-verified facts (2026-07-05, debug 1.11.1 / rspec 3.13 / Ruby 3.4.8)

- catch ブレークポイントは **RSpec が rescue する前、raise の瞬間**に発火する。assertion 失敗(`ExpectationNotMetError`)も実行時エラーも同じ仕組みで止まる。
- assertion 失敗の停止位置は rspec-support 内部(`DEFAULT_FAILURE_NOTIFIER` の re-raise)だが、失敗した example のフレームはスタック上に残っており、`frame N` で移動してローカル変数・インスタンス変数を評価できる。
- catch のパターン照合は raise 時に行われるため、**RSpec ロード前(クラス未定義)に `RSpec::Expectations::ExpectationNotMetError` の catch を仕込んでも効く**。
- suspend 後に接続したクライアントは pause 状態にそのまま乗れる(接続 → bt → frame → evaluate まで確認済み)。
- `continue` 後、RSpec は例外を通常どおり rescue し、失敗レポートを出して完走する。**pause は非破壊**。
- pause 中のプロセス内で `evaluate_code` により修正仮説を検証できる(例: メモ化ずれのデモで、`@total = nil` にしてから `total` を呼び直すと期待値に一致することを、コードを直す前に確認できる)。
- **E2E(実エージェント)**: ヘッドレスの Claude(`claude -p` + debug-mcp を MCP サーバーとして接続)が、人手の介在なしに次を完遂した——pause 中のプロセスへ接続 → `bt`/`frame` で失敗した example のフレームへ移動 → `@total`(古いメモ値 200)と items の実合計 250 のずれを `evaluate_code` で確認して失敗1を診断 → `continue_execution` → 失敗2の現場で `@coupon=nil` を確認して診断 → 完走 → `demo_spec.rb` の Cart を最小修正 → 2 examples, 0 failures。デモ用に本ファイルはバグ入りの状態へ戻してある。
- `rdbg --open --nonstop -e 'catch ...'` はクライアント不在では効かない(テストが pause せず完走することを確認)。フックのプロセス内 require が必要。
- CI=1 のとき hook は自動無効化され、2 failures が pause なしで完走する。

## 設計メモ: 誰のための機能か、CIでどうするか(2026-07-05)

ターゲットの序列を明確にしておく。

1. **seedで再現できる失敗**: `rspec --seed N` で再現→通常のデバッグが可能。本ワークフローは時短(便利)であって必須ではない。
2. **テスト順序依存の失敗**: 失敗レポートに「どの順序で走ったか」が残らないのが問題の本体。スナップショットに seed と実行済み example の順序リストを含めれば事後再現が可能になり(`rspec --bisect` に接続できる)、解けるクラスになる。
3. **タイミング依存(同一seed・同一順序でも出たり出なかったり)**: 失敗したその実行が唯一の証拠。**ライブ捕獲だけが手段**であり、本ワークフローの必須ユースケースはここ。

CIについて:

- **CI上のライブ診断(紹介のみ)**: CIに外から接続するのではなく、suspend検知で同一ジョブ内にエージェントを起動する構成は原理的に組める(上記シェルパターンのCI版)。ただし「pause予算」(規定時間でエージェントが完了しなければ自動continue)の設計が必須で、これはCI設定の領分。
- **スナップショットモード(未実装・将来の検証項目)**: CIのデフォルト回答はこちらであるべき。pauseせず、raise瞬間に例外・全フレームのローカル変数とivar・seed・実行済みexample順序・直近のSQLイベントをJSONでartifactに保存してテストは完走させる。エージェントは事後にartifactを診断する。ライブの仮説検証はできないが、ハングのリスクがゼロ。実装はTracePoint(:raise)のbindingまたはdebug gemのpostmortem機構の延長を想定。これは「観測」の範囲なので、実装するなら本体候補になりうる。

### 責務の境界(2026-07-05の判断)

CIでの失敗は2種類あり、求められる対応が正反対である。

- **チケット(今回の変更)起因の失敗**: 要件を知っているのは開発者と、そのローカルで要件文脈を持つエージェントだけ。CI上のエージェントは要件を知らないまま「テストが通る修正」を作れてしまい、最悪の場合、要件と逆向きの修正をgreenにして混入させる。CI側で自律修正はしない。役立つ形は証拠の保全(スナップショット)までで、修正は要件を知っている側の仕事。
- **無関係なflaky**: 要件知識が不要(「テストは決定的であるべき」がすべて)なので自律診断が成立する。ただし「独断で修正PRを出す」までやるのは、ブランチ運用・レビューポリシー・CI認証情報の領域であり、「実行中プロセスの観測」という本gemの軸から外れる。

さらに「テスト失敗で任意コマンドを起動するフック」も同梱しない。当初ラッパーコマンド(`debug-rspec`実行ファイル+`DEBUG_RSPEC_ON_FAILURE`)として試作したが、呼び出し先を特定できない(claude/codex/通知…)以上ユーザー指定の任意コマンド実行機構になり、これは汎用イベント機構であって実行中プロセスの観測ではない、と判断して削除した。同じことはシェルの数行で組める(上記「組み合わせのパターン」)。

したがってdebug-mcpの責務は、**プリミティブ(catch/pause/接続/観測)の提供と、それを使って自律的なflaky退治ワークフローが組めることの紹介(本文書)まで**とする。エージェントの起動判断・権限設計・PR作成といったオーケストレーションは本体に同梱しない。これは計画文書の判断基準「機能拡張は『実行中プロセスの観測』という軸から外れないものだけ」の適用であり、`evaluate_code`を持つエージェントとrepo write権限をCI上で束ねる仕組みを本体が持たないことは、セキュリティ設計(production default-deny等)の一貫性でもある。

## 既知の制限

- 捕捉対象のデフォルトは assertion 失敗のみ。「あらゆるエラー」を拾うために `StandardError` を catch すると、ライブラリ内部の rescue 前提の raise(制御フロー例外)でも止まってしまいノイズになる。さらに、実行中のマルチスレッドプロセス(Puma 等)に広域 catch を張ると、クライアント接続中の停止イベントと割り込みが混線してプロセスが応答不能になる事例を実機で確認している(2026-07-06、examples/RAILS_SCENARIOS.md シナリオ13の注意を参照)。エラーを追うときは対象クラスを必ず絞ること。
- 本ワークフローがこの混線を回避できているのは設計上の理由による——catch はクライアント不在の状態でプロセス内から仕込まれ、停止後に接続する(suspend-then-attach)ため、停止時に混線する通信相手が存在しない。「接続したまま continue → 次の失敗で停止」の経路も実機検証済み。ただし **system spec のように RSpec プロセス内にサーバースレッドが立つ構成は未検証**であり、マルチスレッド+catch のトポロジーに近づくため、動作確認してから使うこと。
- 並列実行(parallel_tests / flatware)は未対応。ポートが1つのため。
- CI では pause したプロセスを保持する前提がランナーと相性が悪い。誤って CI で動いて job をハングさせないよう、`ENV["CI"]` を検出するとフックは自動で無効化される(テストは通常どおり実行される。`DEBUG_RSPEC_FORCE=1` で明示上書き可)。
- `aggregate_failures` 内の失敗は `ExpectationNotMetError` ではなく集約例外になるため未検証。
