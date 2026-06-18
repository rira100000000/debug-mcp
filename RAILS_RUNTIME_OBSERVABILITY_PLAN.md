# Rails Runtime Observability Plan

> この計画書は、初版に対する実コードベースのレビュー（Opus 4.8 + GPT-5.5 のパネル評価）を反映した第2版である。
> レビューで実コードと食い違うことが判明した記述は訂正し、`rails_recent_events` の実現に必要な前提作業を明示した。
> 主な変更点は末尾の「改訂履歴」を参照。

## 背景

`debug-mcp` は、AIエージェントにRuby/Railsプロセスの中を見せるためのMCPサーバーである。
既存のRuby/Rails向けMCPは、routesやschemaなどの静的情報を渡すものが多い。一方で `debug-mcp` は `debug` gem を通じて実行中のプロセスに接続し、ブレークポイント、ローカル変数、実行中のオブジェクト、Railsリクエストの内部挙動をAIに渡せる。

Railsについては、すでに次の機能が入っている。

- `rails_info`
- `rails_routes`
- `rails_model`
- `trigger_request`
- `ActiveSupport::Notifications` を使った構造化Railsイベント取得（`NotificationsSubscriber`）
- SQL、render、cache、ActiveJob enqueue、request lifecycle の整形表示（`EventFormatter`）
- `evaluate_code` 由来のSQLを `debug_eval` として分離し、アプリ本体のSQLと混ぜない仕組み（`SourceTagging`）

つまり「Rails logをAIに読ませる」のではなく、「Rails内部で起きたことをAIが理解しやすい形に整形する」方向は、すでに実装済みである。

この計画書では、その既存方向を前提に、次に追加する価値のあるRails実行時観測を整理する。

## 解決したい課題

AIエージェントはRailsのコードを読んで修正できるが、実装中に次のような副作用を確信を持って確認しにくい。

- リクエスト中にどのSQLが実行されたか
- キャッシュが効いたか
- partialやtemplateがどのようにrenderされたか
- jobがenqueueされたか
- メールが送られたか
- queue adapterやdelivery methodの設定上、その副作用を観測できる状態なのか
- ブレークポイントで止まっている時に、今見えているSQLやDBアクセスがアプリ本体のものか、debugger側の調査によるものか

既存実装はSQL/render/cache/job enqueue/request lifecycleをかなり解決している。
次に足りないのは、主に次の3つである。

1. `trigger_request` 以外のタイミングで、直近のRailsイベントを読むこと
2. メール送信結果を構造化して見ること
3. job queue / performed job の状態を、adapter前提つきで見ること

ただし、`rails_recent_events` は「既存 `fetch_since` のtool化だけ」では済まない。
レビューの結果、現状の `NotificationsSubscriber` には **toolとして公開する前に直すべき設計上の問題が複数ある**ことが分かった（後述「subscriber改修（recent_eventsの前提作業）」）。
subscriberのinstallタイミング、再install挙動、trap context耐性、取得APIの時計非依存化、paused制約、観測可能範囲のメタデータ提示を、仕様として先に決める必要がある。

## 方針

新しいRails用MCPを別gemとして作るのではなく、まず `debug-mcp` のRails観測機能として拡張する。

理由は以下。

- `debug-mcp` の価値は「実行中のRuby/Railsプロセスの中をAIに見せる」ことにある
- メール、job、SQL、cache、renderは、すべて実行中プロセスの観測対象である
- `debug-mcp` にはすでにRails検出、Rails toolsの登録、Notifications subscriber、EventFormatterがある
- 別gemにすると、接続・セッション・イベント取得・安全警告を重複実装することになる

ただし、FactoryBotやCapybaraのような「状態を作る」「画面を操作する」機能は、観測とは性質が違う。これは最初から本体に常設しない。

### 観測の境界（再定義）

初版は「観るだけ＝本体／状態を変える＝opt-in」と置いたが、これは厳密には破綻している。
`NotificationsSubscriber` の注入、`trigger_request` のSIGINT送出やCSRF一時無効化は、すでに対象プロセスの状態（instrumentation state）を変えている。
そこで境界を次のように再定義する。

- **観測のためのinstrumentation副作用（subscriber注入など）**: 本体に入れてよい。ただし「これはread-onlyではない」と明示する。
- **アプリのドメインデータや外部副作用を意図的に作る操作（DB書き込み、メール実送信、画面操作）**: opt-in拡張にする。
- **runtime dependencyが増える機能**: 将来 `debug-mcp-rails` 分離を検討する。

この定義なら、subscriber注入は「観測のためのinstrumentation副作用」として本体に収まり、かつ「完全なread-onlyではない」という事実とも矛盾しない。

## 優先順位

実装前レビューを踏まえ、優先順位は次の順にする。

1. `rails_info` のObservability拡張（新tool `rails_runtime_info` は原則作らない）
2. **subscriber改修（recent_eventsの前提作業）**
3. `rails_recent_events`
4. `rails_mail_deliveries`
5. `rails_jobs` はMVPから降格し、最後または別計画に回す

理由:

- Observability情報は最も低リスクで、delivery method / queue adapter / cache store / DB設定など、他ツールの前提を共有する土台になる。
  初版は「新tool `rails_runtime_info`」と「`rails_info` 拡張」を両論併記していたが、`rails_info` はすでにtrap fallback・DB設定取得・`[FILTERED]` 処理まで作り込まれている。
  ここに「Observability」セクションを足す方が圧倒的に低コストで、tool数を増やしてAIの選択コストを上げずに済む。**原則 `rails_info` 拡張に倒す。**
- `rails_recent_events` は価値が高いが、subscriber自体を先に直さないと、forward-only/paused-onlyの明記だけでは安全に公開できない。
- `rails_mail_deliveries` は新規価値が明確だが、`delivery_method = :test` など観測可能な設定に依存する。
- `rails_jobs` は `enqueue.active_job` が既存Rails Eventsで取得済みであり（`SUBSCRIBED_EVENTS` に含まれ、`EventFormatter#format_jobs` が整形済み）、新規価値は主にTestAdapterのqueue snapshotに限られる。dev serverでは未対応adapterになる可能性が高い。

## subscriber改修（recent_eventsの前提作業）

レビューで、現状の `NotificationsSubscriber`（`lib/debug_mcp/notifications_subscriber.rb`）に、`rails_recent_events` を公開する前に直すべき問題が複数あることが確認された。
**これらは `rails_recent_events` 実装の前段として行う。**

### 1. 再installが効かない（要修正・確認済み）

現状の `INJECTION_CODE` は `unless defined?(::DebugMcpNotificationsBuffer)` の内側でしか `::DebugMcpNotificationsBuffer.install`（注入コード末尾、`notifications_subscriber.rb:168`）を呼ばない。
一度moduleが定義されると、以降の `NotificationsSubscriber.install(client)` はコードを再送しても `unless defined?` が偽になり、ブロックごとスキップされて `:168` の install 呼び出しに到達しない。
返り値は `:debug_mcp_subscriber_ok` のままなので、Ruby側の `NotificationsSubscriber.install` は**成功と判定する**。

ここで注意すべきは、**真のスキップ箇所は注入コード末尾の `:168` の install 呼び出し**であって、`install` メソッド内の冪等ガード `return if @subscriptions.any?`（`:59`）ではない点である。
`uninstall` は `@subscriptions.clear`（`:85`）するので `@subscriptions` は空になり、`install` を呼びさえすれば再subscribeできる。
問題は「`uninstall` 後に再subscribeする経路（`:168`）に到達できない」ことである。
したがって `uninstall` 後やライフサイクル管理を入れた瞬間に、購読が復活せず静かに壊れる。

対策:

- 「module定義済みでも `:168` 相当の `install` を必ず呼ぶ」構造に直す（定義と有効化を分離する）。
- `install` メソッド側は現状どおり `return if @subscriptions.any?`（`:59`）で冪等のまま維持してよい（ここは原因ではない）。
- これにより `rails_recent_events` の「tool先頭でinstallを呼ぶ」前提が初めて成立する。
- なお現状でも `trigger_request` が install を1回呼んでいる（`trigger_request.rb:144`）ため、`trigger_request` を経たセッションでは購読済みになる。`rails_recent_events` は**同一プロセスの同一bufferに後から触る**ので、この共存（trigger_request × recent_events、同一buffer共有）を仕様として明記する。

### 2. install経路のtrap context脆弱性（要対応）

**この節は実機検証（Ruby 3.4.8 / debug 1.11.1 / activesupport 8.1.3）で挙動を確定した。結果は当初の想定より厳しい。**

`debug_client.rb:268-269` のコメントどおり `Mutex.new` 単体（オブジェクト確保）は trap context でも成功する。`ThreadError`（"can't be called from trap context"）になるのは `Mutex#lock`（＝`synchronize`）である。
ここまでは想定どおりだが、実機で確認した決定的な事実は次のとおり。

- **install（`ActiveSupport::Notifications.subscribe`）自体が trap context で `ThreadError` になる。** `subscribe` は `Mutex.new` のような無害な操作ではなく、ActiveSupport の `Fanout#subscribe`（`activesupport-8.1.3/.../fanout.rb:30-32`）が内部で `@mutex.synchronize` するためである。`uninstall`（`Fanout#unsubscribe` `:48`）も同様。
- したがって trap context では **install / uninstall / push / fetch のすべてが落ちる**。「installは通る、危険はpush/fetchだけ」という見立ては実機で否定された。

さらに重大な**複合バグを実機で確認した**（実 `INJECTION_CODE` で再現）。

1. trap context で install を試みると、注入コードは先に `module ::DebugMcpNotificationsBuffer` 本体を定義し、その直後の `::DebugMcpNotificationsBuffer.install`（`:168`）で `subscribe` が `ThreadError` を投げる。
2. 結果として「**moduleは定義済みだが subscriptions は空**」というポイズン状態になる。
3. その後 normal context で同じ `INJECTION_CODE` を再送しても、`unless defined?`（`:27`）が真になりブロックごとスキップされ、`:168` に到達しない。**subscriptions は空のまま、以降イベントを一切取得できない（恒久的破壊）。**

`connect` 直後（Pumaにattachしてbreakpoint未到達）の trap context で AI が一度でも `rails_recent_events` を呼ぶと、そのプロセスのbufferが永久に壊れる。
初版の「trap context」節は `run_base64_script` の話に終始し、この経路にまったく触れていなかった。

対策（実機結果を反映）:

- **install は「ガードして rescue する」だけでは不十分**。`ThreadError` を rescue してもmoduleは既に定義済みになりポイズンする。
  よって **install前に `RailsHelper.trap_context?(client)` を確認し、trapなら `INJECTION_CODE` を送らずに `RailsHelper::TRAP_CONTEXT_HINT` を返す**（moduleを定義させない）。
- 再installバグ修正（前節）とあわせ、**moduleが空subscriptionsで定義済みでも `install` を必ず呼んで再subscribeできる**構造にする。これでポイズン状態からの自己回復も可能になる。
- fetch / uninstall も `Mutex#lock` を踏むため、**fetch経路にも同じtrapガードを入れる**。
- callback内の `push` は現状 `rescue StandardError`（`:73`）で握りつぶしている。trap中に発火したイベントは取りこぼす前提で、`dropped_count` 等のメタデータに反映する。

### 3. 時計に依存しない取得API（要追加）

現状の `fetch_since(timestamp)` は、呼び出し側が渡したfloatを、buffer内の各eventの `:timestamp` キー（push時に `timestamp: started.to_f` で格納、`notifications_subscriber.rb:66`）と `e[:timestamp] >= timestamp`（`:51`）で比較する。
MCP側の `Time.now` を渡すと、Docker/remote接続で時計ずれが起きる。

対策:

- 各eventに対象プロセス内で**単調増加の `seq`** を振る。
- 取得APIの主軸を `fetch_last(limit)` と `fetch_after_seq(cursor)` にする。
- `fetch_since(timestamp)` は補助扱いにし、timestampは表示用に残す。
- これでクライアント／コンテナ／VMの時計差に一切依存しなくなる。

### 4. fetchのデッドロック回避（実機確認済み・要対応）

subscriber callbackは `@mutex.synchronize` でpushし、fetchも同じmutexを取る。
対象プロセスが停止した瞬間に別threadがmutexを保持していると、debugger経由のfetchが詰まる。

**実機検証で再現した**: あるthreadが `@mutex` を保持したまま停止している状態で、別コンテキストから `mutex.synchronize` を呼ぶと**1.5秒待っても返らずデッドロックした**。一方 `mutex.try_lock` は即座に `false` を返した。
ruby/debug のthread停止挙動に依存する部分はあるが、「ロック保持threadが止まっている間のblocking lockは返らない」というMutexの基本挙動そのものなので、現実的なリスクである。

対策:

- fetchは `try_lock` で取れなければ「busy」status を返すか、短時間で諦める（blocking `synchronize` をfetch経路で使わない）。

### 5. 保存時点でのtruncate/redact（要強化）

現状の保存時点（push時の `sanitize_payload`）のガードは不揃いである。実コードで確認した状況:

- binds・job引数: `safe_binds`/`safe_inspect` で100文字truncate済み（`notifications_subscriber.rb:113,133,155`）。
- cache key: `payload[:key].to_s[0, 200]` で200文字truncate済み（`:123`）。
- **SQL本文（`:110` `sql: payload[:sql].to_s`）: 無truncate・無redact。**
- **request path（`:140` `path: payload[:path]`）: 無truncate・無redact。**

つまりSQL本文とrequest pathはノーガードのままで、`EventFormatter` 側の表示時truncateに頼っている。
保存時点でないと、PII対策・転送サイズ・行指向JSON保護のいずれも後手になる。

対策:

- SQL本文、request path/query を**push時点で**truncate/redactする（現状ノーガードの2つを最優先）。
- binds・job引数・cache key は既存truncateを踏まえ、redact（`ActiveSupport::ParameterFilter`）を上乗せする。
- Hash/params形のものには `ActiveSupport::ParameterFilter`（= `Rails.application.config.filter_parameters`）を適用する。
  初版は「filter_parametersは自動適用されない」で止まっていたが、**能動的に適用する設計**に進める。
  SQL bindsやjob argsの完全redactionは難しいが、Hash形には効く。

### 6. ライフサイクルとメタデータ（要追加）

`uninstall(client)` は存在するが、本番経路では誰も呼んでおらず（`grep` 確認済み）、subscriberはdisconnect後も対象プロセスに残る。
同じプロセスに別clientがattachすると同じbufferを見る。
gem側の注入コードを更新しても、対象プロセス内の古いmoduleは入れ替わらない。

対策:

- `disconnect` 時にbest-effortで `uninstall` を呼ぶか、明示的な clear/uninstall 経路を用意する（最低でも `BUFFER_MAX=1000` 件payload常駐の回収手段を持つ）。
- subscriberにメタデータを持たせる: `version` / `installed_at` / `buffer_started_at` / `buffer_size` / `buffer_max` / `dropped_count` / `next_seq` / `subscriptions_count`。
- 注入コードに `version` を持たせ、**version mismatch時の扱い**（古いmoduleをどう入れ替えるか）を決める。
- 複数client attach時にbufferを共有する意味論を仕様として明記する。

## MVPで追加する候補

### 1. `rails_info` のObservability拡張

Rails実行時の観測可能性をまとめて返す。
原則として新tool `rails_runtime_info` は作らず、既存 `rails_info` に「Observability」セクションを足す。

目的:

- AIが、メールやjobを観測できる設定かどうかを先に判断できるようにする
- 誤診断を減らす
- 各Rails観測toolが同じ前提情報を重複実装しないようにする

返す情報:

- Rails.env
- database adapter / database name / host
- ActionMailer delivery_method
- ActiveJob queue_adapter
- cache store
- Rails root
- current process pid
- Rails観測toolが利用可能か（後述「tool登録に関する訂正」を踏まえた正確な表現にする）

実装方針:

- delivery_method / queue_adapter / cache_store / DB adapter の取得は `RailsHelper` に一元実装する。
- DB設定の取得では、`ActiveRecord::Base.connection` に触ると接続確立や通知発火が起き得るため、
  可能なら `connection_db_config` / `db_config` 系のメタ情報を優先する。
  実接続が必要なprobeはやむを得ず行う場合 `debug_eval` としてtagし、`recent_events` に混ざらないようにする。
- 既存 `eval_expr` は「単純probeは通知を出さない」前提で `SourceTagging` を使っていないが、
  Observability probeはこの前提から外れうるので、副作用イベントを出すprobeは個別にtagする。

### 2. `rails_recent_events`

Notifications subscriberのバッファから、request単位ではなく直近イベントを取得する。
**前提として「subscriber改修」を完了していること。**

目的:

- `trigger_request` の戻り値以外でも、AIが最近のRails内部イベントを見られるようにする
- ブレークポイントで止まった後、install以降に発火したSQLやjob enqueueを確認できるようにする

重要な制約:

- forward-only: `NotificationsSubscriber.install` 以降に発火したイベントしか取れない。install前は遡れない。
- paused-only: 読み出しにはdebuggerプロンプトで対象プロセスが停止している必要がある（`send_command` は `@paused` でないと拒否する）。
- install自体がプロセスglobalな副作用である（`::DebugMcpNotificationsBuffer` をトップレベル定義し最大12イベントにsubscribe）。これはread-onlyではない。
- background jobやconsole操作のイベントは別threadで発火し、`request_id` も `source` タグも付かないことが多い。
  したがって「どのリクエストか」の文脈が欠落する。**この用途は価値が限定的なので、成功条件には含めず補助扱いにする。**

入力パラメータ:

- event kind filter: sql / render / cache / job / request
- limit
- cursor（`fetch_after_seq` 用、任意）
- include_debug_eval（default false）

出力に**毎回必須**で含める観測メタデータ:

- `installed`: true/false
- `installed_at`: 対象プロセス側の基準時刻
- `forward_only`: true
- `paused_only`: true
- `events_before_install_are_unavailable`: true
- `buffer_dropped_count`
- `oldest_seq` / `newest_seq`
- `filtered_kinds`
- `include_debug_eval`

これにより、install直後の初回呼び出しでほぼ空が返っても、AIが「SQLが走っていない」と誤診断しない。
（初版は「空≠未送信」の警告を `rails_mail_deliveries` でしか書いていなかったが、同じ罠が `recent_events` にもある。）

実装方針:

- tool先頭で `NotificationsSubscriber.install(client)`（改修後の再install可能版）を呼ぶ。
- trap context時はinstallせずhintを返す。
- 「forward-only」「paused-only」「installは副作用」をtool descriptionと出力に明記する。
- 取得は `fetch_last(n)` / `fetch_after_seq(cursor)` を主軸にする。
- 既存 `EventFormatter.format` を使って整形する。
- 結果転送は単一行JSON前提（後述「行指向JSONとtruncate」）を厳守する。

### 3. `rails_mail_deliveries`

`ActionMailer::Base.deliveries` を構造化して返す。

目的:

- AIが「メールが送られたか」をRails内部から確認できるようにする
- 宛先、件名、本文の一部、添付ファイル名などを確認できるようにする

返す情報の例:

- delivery_method
- observable: `ActionMailer::Base.delivery_method == :test` のときだけ `true` と言い切る
- total count / index
- from / to / cc / bcc
- subject
- body preview（default truncate）
- multipartかどうか
- attachments（**添付本文は絶対に返さない。ファイル名と種別のみ**）

注意点:

- `delivery_method = :test` でなければ `deliveries` が空のことがある。
- `letter_opener` や `smtp` では別の観測方法が必要になる。observableでない場合は
  「`not observable via ActionMailer::Base.deliveries`」と明示し、「空＝未送信」とは言わない。
- 本文には個人情報やsecretが含まれる可能性があるため、デフォルトでtruncate＋`ActiveSupport::ParameterFilter` 相当の処理を行う。
- full body取得・redaction無効化は単一booleanにせず、最大件数・最大文字数・preview文字数・address redaction・binds redactionを分けたオプションにする。
  デフォルトは「短いpreview + filter適用 + 添付本文は返さない」。
- Railsの `filter_parameters` はこの直読み経路には自動適用されないので、明示的に適用する。

実装方針:

- `RailsHelper.run_base64_script` を使う場合は、`rails_model` と同じtrap context fallbackを踏襲する。
- 転送はdebug socket上の行指向JSONであるため、本文や添付名は対象プロセス内でtruncateしてからJSON化する。
- JSONの単一行制約を壊さないよう、本文の改行や巨大データをプロセス内で整形する。

### 4. `rails_jobs`（MVP外または最後）

ActiveJobのqueue状態を構造化して返す。

目的:

- AIが「jobが積まれたか」を確認できるようにする
- queue adapterごとに、何が観測可能かを明示する

最初に対応する範囲:

- `ActiveJob::QueueAdapters::TestAdapter`
  - `enqueued_jobs`
  - `performed_jobs`
- それ以外のadapterでは、adapter名と「このadapterでは詳細未対応」を返す

将来候補:

- Sidekiq adapterのqueue/dead/retry情報（別プロセス・Redis前提のため別plugin的に扱う）
- Solid Queueのpending/failed job情報（DB queue前提）

注意点:

- `enqueue.active_job` は既存Rails Eventsですでに取得・整形されている。
- queue snapshotの新規価値は主にtest環境に限られる。
- `:async`, `:inline`, `solid_queue`, `sidekiq` では `enqueued_jobs` / `performed_jobs` が取れないことが多い。
- job argumentsは `safe_inspect` で部分的にtruncate済みだが、保存時点redactを徹底し、full表示は明示オプションにする。

## MVPに入れないもの

### FactoryBot tools

`FactoryBot.create` は、attach先プロセスにFactoryBotがロードされていれば `evaluate_code` でも実行できる。
専用toolにする価値はあるが、最初のMVPではない。

理由:

- DBを書き換える（ドメインデータを意図的に作る ＝ opt-in境界の向こう側）
- test/dev限定の安全ガードが必要
- Rails serverプロセスにはFactoryBotがロードされていないことが多い
- `debug-mcp` の「観る」責務から一段外れる

将来やるなら、default offのopt-in toolにする。

### Capybara tools

新しいrack_testセッションを `debug-mcp` 側で立てる案は、`debug-mcp` の「今動いているプロセスを見る」という思想から少しずれる。

Capybaraをやるなら、次の方針がよい。

- すでに停止中のsystem spec / feature spec内の `page` を操作する
- attach先プロセスにCapybaraがロードされている時だけtoolを出す
- runtime dependencyは増やさない

最初から入れると、依存・状態管理・JS対応・DBトランザクション問題が大きくなるため、MVPには含めない。

## 共通実装メモ

### trap context

`RailsHelper.run_base64_script` は便利だが、Puma/Railsのsignal trap contextでは失敗しうる。
新しいRails toolは、`rails_model` と同じように、失敗時に `RailsHelper::TRAP_CONTEXT_HINT` を返す設計を踏襲する。
**subscriberの `push`/fetch は `Mutex#synchronize`（`Mutex#lock`）を使うためtrap脆弱**であり（`Mutex.new` 単体は trap でも成功する点に注意）、install経路・fetch経路の両方で同じガードを入れる（「subscriber改修」2を参照）。

### 行指向JSONとtruncate

debug socket経由の結果パースは、単一行JSONに依存する。
`NotificationsSubscriber.parse_json_array` は `each_line` で回し、行頭が `[` の行だけをJSONパースする。
つまり**配列が複数行に分割された瞬間に全件ロストする**。
debug socketは1行ずつ読む（`gets` + `chomp`）ため、これは現実的なリスクである。

対策:

- メール本文、job arguments、添付名、SQL bindsなどは、MCP側ではなく対象プロセス内でtruncateしてからJSON化する。
- 単に改行を除くだけでなく、**長さ上限つきで確実に1行で出る固定フォーマット**を仕様化する。
- これはPII対策・転送経路保護の両方に必要である。

### 観測可能性probeの共有

次の取得は `RailsHelper` に一元化する。

- delivery_method
- queue_adapter
- cache_store
- database adapter / database name / host（可能なら `connection_db_config` 系メタ優先）

各toolは、この共通probeの結果を出力に含める。
副作用イベントを出すprobeは `debug_eval` としてtagする。

### tool登録に関する訂正

初版は「Rails toolはRails検出時のみ登録する」と書いていたが、**これは現状の実コードと一致しない**。
`Server.start` は `MCP::Server.new(tools: TOOLS)` を呼び、`TOOLS = (BASE_TOOLS + RAILS_TOOLS)` なので、
**Rails toolは起動時に無条件で登録されている**。
`register_rails_tools` は定義されているがspecからしか呼ばれておらず、本番経路では使われていない。
さらに**古い記述が2箇所ある**:

- `server.rb:56` のコメント「dynamically added when a Rails process is detected」
- `server.rb:119-121` の `INSTRUCTIONS` 本文「When you connect to a Rails process, additional Rails-specific tools become available automatically ... These tools are NOT shown when debugging plain Ruby scripts」

後者はAIに渡る本文で、しかも「plain Rubyでは表示されない」と明言しており、実態（起動時に無条件登録）と食い違う。**コメントとINSTRUCTIONS本文の両方を修正する。**

したがって:

- 各Rails toolの実際のガードは、tool内の `RailsHelper.require_rails!`（非Railsなら `SessionError`）である。
- 新tool追加時に「非Railsでは表示されない」前提を置かない。各tool側で必ず `require_rails!` する。
- 将来「Rails検出時のみ表示」を本当に実装するなら、`register_rails_tools` をconnect経路から呼ぶ別タスクとして扱う（この計画の範囲外）。
- 古いコメントの修正も併せて行う。

## セキュリティと安全性

- 追加するMVP toolは、アプリのドメインデータを書き換えない。
- ただしsubscriber注入はプロセスglobalな副作用であり、**完全なread-onlyではない**。
  MCPの `read_only_hint: true` は誤解を招くため、tool descriptionに「アプリデータは書かないがプロセス内instrumentation stateは変更する」と明記する。
- productionは対象にしない。READMEの警告だけでなく、tool側で `Rails.env.production?` を検出してデフォルト拒否にし、
  `DEBUG_MCP_ALLOW_PRODUCTION_OBSERVABILITY=1` のような明示opt-inを要求する。
- `connect` は対象プロセスをpauseするため、productionで使う時点で危険である。
- subscriberはプロセス内に最大 `BUFFER_MAX` 件のイベントペイロードを保持する。回収経路（uninstall/clear）を用意する。
- メール本文、job arguments、SQL bindsはPIIやsecretを含み得る。**保存時点で**truncate/redactし、`ActiveSupport::ParameterFilter` を適用する。
- full表示やredaction無効化は単一booleanにせず細分化し、デフォルトは安全側に倒す。添付本文は返さない。
- Railsの `filter_parameters` はsubscriberや直読み経路には自動適用されないので、能動的に適用する。
- **prompt injection**: メール本文・SQL文字列・job引数はアプリのユーザ入力由来であり、それが構造化テキストとしてAIのコンテキストに入る。
  既存の「dev-only security model and prompt-injection caveat」ドキュメントと整合を取り、recent_events/mail由来テキストのinjection面をtool descriptionと出力注記に1行入れる。
- Rails toolは `require_rails!` で非Railsを拒否する（「tool登録に関する訂正」参照）。
- write系toolは将来追加するとしてもdefault offにする。

## テストハーネス整備

現状の `examples/rails_test_app/testapp` は、ActiveJobとActionMailerを十分に有効化していない（`active_job/railtie`・`action_mailer/railtie` がコメントアウト、`app/mailers`・`app/jobs` 不在を確認済み）。
mail/jobs/recent_eventsを実装する場合、次が必要。

- `active_job/railtie` を有効化する
- `action_mailer/railtie` を有効化する
- ダミーMailerを追加する
- ダミーJobを追加する
- test環境で `delivery_method = :test` を設定する
- test環境で `queue_adapter = :test` を設定する

既存Rails tool specの多くはstub clientベースであり、ライブRails統合テストではない。
ユニットテストだけでなく、最小Rails appを使ったsmoke testを用意する。

smoke testで最低限担保したい挙動:

- subscriber installが `trigger_request` なしでもpaused normal contextで成功する
- **trap context では `INJECTION_CODE` を送らず（moduleを定義させず）hintを返す**（trap install→module定義済み・subscriptions空のポイズン状態を作らない）
- **trap context でポイズンしたmoduleが、normal contextでの再installで購読復活する**（複合バグの回帰防止）
- `uninstall` 後に再 `install` して購読が復活する（再installバグの回帰防止）
- fetch時にロック保持threadがあっても `try_lock` で「busy」を返し、blockしない（デッドロック回帰防止）
- `fetch_last` / `fetch_after_seq` がクライアント時計に依存しない
- buffer overflow時に `dropped_count` が増える
- SQL本文・binds・job args・mail bodyが保存時点でtruncate/redactされる
- `evaluate_code` / runtime_info / mail_deliveries 由来のイベントが `debug_eval` として除外される
- `delivery_method = :test` ではdeliveriesが構造化され、それ以外では「not observable」と返る
- 非Railsプロセスでは各Rails toolが安全に拒否する
- production env ではdefault denyになる

## 成功条件

### 短期

- `rails_info` のObservability拡張で、AIがdelivery method / queue adapter / cache store / DB設定を確認できる
- subscriber改修（再install/trap/seq/メタデータ）が完了している
- `rails_recent_events` で、subscriber install以降の直近Railsイベントを、観測メタデータ付きでAIが確認できる
- `rails_mail_deliveries` で、観測可能なdelivery methodの時に送信メールを構造化して確認できる
- tool出力に観測可能性の前提（installed_at / forward_only / observable など）が含まれ、AIが「空だから送られていない」と誤診断しにくくなる

### 中期

- AIがRailsの副作用を「ログを読む」のではなく「構造化された事実」として扱える
- Rails debugging workflowで、人間がログ・メール・jobを手で確認する場面が減る
- `debug-mcp` のREADME上で、Rails runtime observabilityが明確な価値として説明できる

## 実装順

1. 既存 `NotificationsSubscriber` / `EventFormatter` / `trigger_request` / `server.rb` を読み、重複と前提を確認する（tool登録の実態・既存truncateの棚卸しを含む）
2. `RailsHelper` に観測可能性probeを追加する（`connection_db_config` 系メタ優先、副作用probeはdebug_eval tag）
3. `rails_info` にObservabilityセクションを足す（新tool化しない）
4. **subscriber改修を行う**
   - 再install可能化（定義と有効化を分離）
   - install前のtrap context ガード
   - 各eventに `seq` 付与、`fetch_last` / `fetch_after_seq` 追加
   - 保存時点truncate/redact（`ActiveSupport::ParameterFilter`）
   - メタデータ（installed_at / dropped_count / next_seq / version など）
   - `disconnect` 時のbest-effort uninstall または clear経路
5. `rails_recent_events` を実装する（観測メタデータ必須出力、forward-only/paused-only明記）
6. `rails_mail_deliveries` を実装する
7. test appにActionMailer / ActiveJobのハーネスを整備し、smoke testを追加する
8. `rails_jobs` は最後に、TestAdapter限定で実装するか再判断する
9. `server.rb:56` の古いコメントと `server.rb:119-121` の `INSTRUCTIONS` 本文を修正し、README / README.ja.md に「Rails runtime observability」の節を更新する
10. FactoryBot / Capybara はこのMVPの反応を見てから別計画にする

## 非目標

この計画では、次のことはやらない。

- Railsテスト自動化フレームワークを作る
- Playwright MCPの代替を作る
- FactoryBotやCapybaraを常時tool化する
- production運用監視ツールにする
- DatadogやAPMの代替を作る
- log tailをそのままAIに読ませるだけの機能に戻す
- 「Rails検出時のみtool表示」をこの計画で実装する（別タスク）

## 一言で言うと

`debug-mcp` は、AIにRailsのコードを読ませるだけでなく、実行中のRailsプロセスで何が起きたかを構造化して見せる道具である。

次の拡張では、既存のRails Eventsを土台に、観測可能性情報・request外イベント・メールまで観測範囲を広げる。
ただし `rails_recent_events` は既存subscriberをそのままtool化するのではなく、再install・trap耐性・時計非依存・メタデータ提示を先に整える。
job queue snapshotは既存enqueueイベントとの差分が小さいため、MVPでは後回しにする。

これにより、AIエージェントは「たぶん動く」ではなく、「この環境ではメールを観測できる」「このリクエストでSQLが走った」「このメールが生成された」と確認しながら実装できるようになる。

## 改訂履歴

### 第2版（レビュー反映）での主な変更

- `rails_recent_events` の前提として「subscriber改修」章を新設（再installバグ修正、install経路のtrap ガード、`seq`/`fetch_last`/`fetch_after_seq`、fetchデッドロック回避、保存時redact、ライフサイクル/メタデータ）。
- 取得APIを `fetch_since` 中心から `fetch_last`/`fetch_after_seq` 中心へ変更（時計非依存）。
- `rails_recent_events` / `rails_mail_deliveries` に観測メタデータの必須出力を追加（「空≠未発生」の誤診断防止）。
- `rails_runtime_info` 新tool案を取り下げ、原則 `rails_info` 拡張に一本化。
- 「観測の境界」を再定義（instrumentation副作用は許容するが明示／ドメインデータ操作はopt-in）。
- **訂正**: 「Rails toolはRails検出時のみ登録」は実コードと不一致。起動時に無条件登録されており、実ガードは各toolの `require_rails!`。古いコメント修正も実装順に追加。
- PII対策を「表示時truncate」から「保存時点truncate/redact ＋ `ActiveSupport::ParameterFilter` 適用」へ強化。full表示オプションを細分化、添付本文は返さない。
- production default-deny ＋ 明示opt-in env を追加。
- 行指向JSONの「複数行分割で全件ロスト」リスクを明記し、固定1行フォーマット仕様化を要求。
- prompt injection 注記を追加。
- background job/console イベントの文脈欠落を理由に、当該用途を成功条件から補助扱いへ格下げ。
- test app harness整備にsmoke testの担保項目を具体化。

### 第2版・再レビューでの論拠精度の修正

書き直し後の再レビュー（実コード再検証）で、結論は維持しつつ次の論拠を精緻化した。

- 再installバグの真因を「`install` の冪等ガード（`:59`）」ではなく「注入コード末尾 `:168` の install 呼び出しが `unless defined?` でスキップされる点」と明確化。`trigger_request.rb:144` が既にinstall済みである共存シナリオを追記。
- trap脆弱性の所在を `Mutex.new` ではなく `Mutex#synchronize`（push/fetch）と訂正（`debug_client.rb:268-269` のコメントに基づく）。ガードを install前だけでなく fetch経路にも要すると追記。
- `fetch_since` の比較対象を「`started.to_f`」ではなく buffer内の `:timestamp` キー（`:51,66`）と訂正。
- 保存時ガードの現状を精査: SQL本文（`:110`）と request path（`:140`）が無防備、cache key は200字truncate済み（`:123`）と明記。
- tool登録の古い記述が `server.rb:56` コメントに加え `server.rb:119-121` の `INSTRUCTIONS` 本文（AIに渡る）にもある点を追記し、両方を修正対象に。

### 第2版・実機確認で判明した事実（Ruby 3.4.8 / debug 1.11.1 / activesupport 8.1.3）

紙上の推論を実機で検証した結果、想定を2点で上書きした。

- **install自体がtrap contextで落ちる**（覆し）: `ActiveSupport::Notifications.subscribe` は `Fanout#subscribe`（`fanout.rb:30-32`）が内部で `@mutex.synchronize` するため `ThreadError` になる。「installは通る、危険はpush/fetchだけ」は誤り。install/uninstall/push/fetch のすべてが trap で落ちる。
- **trap install による恒久ポイズンを実機で再現**（新発見）: trap中のinstallは module を定義したうえで subscribe に失敗し「定義済み・subscriptions空」を作る。以降 normal context で再installしても `unless defined?` でスキップされ、二度と購読されない。→ 対策を「rescueする」から「trap時は `INJECTION_CODE` を送らない＋空moduleからの再install復活」に変更。
- **fetchデッドロックを実機で再現**（昇格）: ロック保持threadが停止中だと blocking `synchronize` が返らず、`try_lock` は即 `false`。「要検討」から「要対応（try_lock必須）」へ昇格。
