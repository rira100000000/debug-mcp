# debug-mcp

LLMエージェントをRubyの[debug gem](https://github.com/ruby/debug)に接続し、停止中のRubyプロセスの実行時コンテキストへのアクセスを提供するMCP (Model Context Protocol) サーバーです。

LLMエージェントが、停止中のRubyプロセスに接続し、変数の調査・コード評価・ブレークポイント設定・実行制御をMCPツール呼び出しだけで完結できます。MCP対応クライアントであれば何でも利用可能です。

## できること

既存のRuby/Rails向けMCPサーバーは静的解析やアプリケーションレベルのAPIにとどまっています。debug-mcpはdebug gem経由で**実行中のRubyプロセス**に接続し、その実行時状態をLLMエージェントに公開します。

```
Agent → connect(host: "localhost", port: 12345)
Agent → get_context()
  → ローカル変数、インスタンス変数、コールスタック
Agent → evaluate_code(code: "user.valid?")
  → false
Agent → evaluate_code(code: "user.errors.full_messages")
  → ["Email can't be blank"]
Agent → continue_execution()
```

## インストール

```ruby
gem "debug-mcp"
```

または直接インストール：

```
gem install debug-mcp
```

Ruby >= 3.2.0が必要です。

> **`girb-mcp` から移行する場合:** このgemは以前 `girb-mcp` という名前で
> RubyGemsに公開されていました（最終バージョン: 0.1.1）。0.1.2以降、用途を
> より明確にするため `debug-mcp` にリネームされました。Gemfileの
> `gem "girb-mcp"` を `gem "debug-mcp"` に置き換え、MCPクライアント設定の
> `girb-mcp` → `debug-mcp`、`girb-rails` → `debug-rails` に更新してください。
> 詳細は [CHANGELOG.md](CHANGELOG.md) を参照。

## クイックスタート

### 1. デバッガ付きでRubyプロセスを起動

```bash
# スクリプト
rdbg --open --port=12345 my_script.rb

# 環境変数で指定
RUBY_DEBUG_OPEN=true RUBY_DEBUG_PORT=12345 ruby my_script.rb

# コード中に `debugger` / `binding.break` を記述して実行
rdbg --open my_script.rb
```

### 2. MCPクライアントの設定

debug-mcpはMCP対応クライアントであれば何でも動作します。お使いのクライアントのMCPサーバー設定に追加してください：

#### Claude Code

`~/.claude/settings.json`（またはプロジェクトの`.claude/settings.json`）に追加：

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "debug-mcp",
      "args": []
    }
  }
}
```

Bundler経由の場合：

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "bundle",
      "args": ["exec", "debug-mcp"]
    }
  }
}
```

#### Gemini CLI

`~/.gemini/settings.json` に追加：

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "debug-mcp",
      "args": []
    }
  }
}
```

Bundler経由の場合：

```json
{
  "mcpServers": {
    "debug-mcp": {
      "command": "bundle",
      "args": ["exec", "debug-mcp"]
    }
  }
}
```

### 3. デバッグ開始

エージェントに接続とデバッグを依頼：

> 「ポート12345のデバッグセッションに接続して現在の状態を見せて」

> 「app/models/user.rbの42行目にブレークポイントを設定して、/users/1にGETリクエストを送って」

## 使い方

```
Usage: debug-mcp [options]
    -t, --transport TRANSPORT        トランスポート: stdio（デフォルト）または http
    -p, --port PORT                  HTTPポート（デフォルト: 6029、httpトランスポート時のみ）
        --host HOST                  HTTPホスト（デフォルト: 127.0.0.1、httpトランスポート時のみ）
        --session-timeout SECONDS    セッションタイムアウト秒数（デフォルト: 1800）
    -v, --version                    バージョン表示
    -h, --help                       ヘルプ表示
```

### STDIOトランスポート（デフォルト）

標準的なMCPクライアント向け。追加設定は不要です。

```bash
debug-mcp
```

### HTTPトランスポート（Streamable HTTP）

ブラウザベースのクライアントやHTTP対応MCPクライアント向け。

```bash
debug-mcp --transport http --port 8080
```

MCPエンドポイントは `http://127.0.0.1:8080/mcp` で利用可能になります。

### セッションタイムアウト

デバッグセッションは30分間操作がないと自動的にクリーンアップされます。変更するには：

```bash
debug-mcp --session-timeout 3600  # 1時間
```

セッションマネージャーは、対象プロセスが終了したセッションも検出して自動的にクリーンアップします。

## ツール一覧

### 接続・検出

| ツール | 説明 |
|------|------|
| `list_debug_sessions` | 利用可能なデバッグセッション一覧（Unixソケット） |
| `connect` | ソケットパスまたはTCPでデバッグセッションに接続 |
| `list_paused_sessions` | 接続中のセッション一覧 |

### 調査

| ツール | 説明 |
|------|------|
| `evaluate_code` | 停止中のbindingでRubyコードを実行 |
| `inspect_object` | オブジェクトのクラス・値・インスタンス変数を取得 |
| `get_context` | ローカル変数・インスタンス変数・コールスタック・ブレークポイントを一括取得 |
| `get_source` | メソッドまたはクラスのソースコードを取得 |
| `read_file` | ソースファイルの読み取り（行範囲指定可） |
| `list_files` | ディレクトリ内のファイル一覧（globパターンでフィルタ可） |

### 実行制御

| ツール | 説明 |
|------|------|
| `set_breakpoint` | ブレークポイント設定：行（file + line）、メソッド（`User#save`）、例外クラス |
| `remove_breakpoint` | file + line、メソッド名、例外クラス、または番号でブレークポイントを削除 |
| `continue_execution` | 次のブレークポイントまたは終了まで実行を再開 |
| `step` | ステップイン（メソッド呼び出しに入る） |
| `next` | ステップオーバー（次の行へ進む） |
| `finish` | 現在のメソッド/ブロックがreturnするまで実行 |
| `run_debug_command` | 任意のデバッガコマンドを直接実行 |
| `disconnect` | セッション切断とプロセス終了 |

### 入口ツール

| ツール | 説明 |
|------|------|
| `run_script` | rdbg経由でRubyスクリプトを起動して接続 |
| `trigger_request` | デバッグ中のRailsアプリにHTTPリクエストを送信 |

### Railsツール（自動検出）

Railsプロセスを検出すると自動的に登録されます。

| ツール | 説明 |
|------|------|
| `rails_info` | アプリ名・Rails/Rubyバージョン・環境・ルートパスを表示 |
| `rails_routes` | ルーティング一覧（verb, path, controller#action）、コントローラ・パスでフィルタ可能 |
| `rails_model` | モデル構造：カラム・アソシエーション・バリデーション・enum・スコープを表示 |

## Rails イベントキャプチャ

Rails アプリへ `trigger_request` を実行すると、レスポンスにリクエスト中の挙動を構造化した `Rails Events` セクションが付加されます。

- SQL クエリ (実行時間、bind 値、query name、cached フラグ)
- レンダリング (template / partial / collection)
- キャッシュ操作 (read/write/fetch_hit、hit/miss)
- enqueue された ActiveJob
- リクエストのライフサイクル (controller#action、status、view/db runtime)

debug-mcp が初回の `trigger_request` 時に `ActiveSupport::Notifications` の subscriber を Rails プロセスに動的注入することで実現しています。Rails アプリ側に gem 追加は不要です。

### 出力例

```
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")

  HTTP 200 OK
  {...response body...}

  --- Rails Events ---
  ## Request
  GET /users/1 → UsersController#show
  Status: 200 — total 35.4ms (view 12.5ms, db 4.2ms)

  ## SQL (1 query)
  1. (0.66ms) User Load SELECT "users".* FROM "users" WHERE "users"."id" = 1 LIMIT 1
```

### フィルタリング: アプリ実行と debugger 操作の分離

breakpoint 停止中に `evaluate_code` や `inspect_object` を実行すると、それらが発行した AR クエリもリクエストスレッド上で動くためバッファに入ります。debug-mcp はそれらに `source: :debug_eval` タグを付けるので、デフォルト表示からは除外され、アプリ自身の挙動だけが見える状態になります。

- **デフォルト**: `:debug_eval` のイベントを非表示。アプリ自身の動作だけを表示。
- **`include_debug_eval: true`** を `trigger_request` に渡す: デバッガが触ったクエリも含めて全件表示。

### 出力量の調整

`trigger_request` の `event_limits` オプションでカテゴリ別の上限を上書きできます。

```
trigger_request(
  method: "GET", url: "...",
  event_limits: { sql: 100, render: null }  # null は上限なし
)
```

デフォルト: `sql=30`, `render=20`, `cache=20`, `job=無制限`, `logger=50`。

## ワークフロー例

### Rubyスクリプトのデバッグ

```
Agent: run_script(file: "my_script.rb")
Agent: get_context()
Agent: evaluate_code(code: "result")
Agent: next()
Agent: evaluate_code(code: "result")
Agent: continue_execution()
```

### メソッドブレークポイント

```
Agent: run_script(file: "my_script.rb", breakpoints: ["DataPipeline#validate"])
  → スクリプトが起動し、DataPipeline#validate で停止
Agent: evaluate_code(code: "records")
Agent: continue_execution()
```

### 例外のキャッチとデバッグ

```
Agent: run_script(file: "my_script.rb")
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → 例外が伝播する前に実行が停止
Agent: get_context()
Agent: evaluate_code(code: "$!.message")
```

### クラッシュ後の再起動

```
  → NoMethodError でプログラムがクラッシュ
Agent: run_script(file: "my_script.rb", restore_breakpoints: true)
  → 前回のブレークポイントが自動復元
Agent: set_breakpoint(exception_class: "NoMethodError")
Agent: continue_execution()
  → クラッシュ前に例外をキャッチ
```

### Railsリクエストのデバッグ

`debug-rails` でデバッグ有効状態のRailsサーバーを起動：

```bash
debug-rails                # RUBY_DEBUG_OPEN=true bin/rails server と同等
debug-rails s -p 4000      # ポート指定
debug-rails --debug-port 3333  # TCPデバッグポートを指定（Docker内で便利）
```

エージェントにデバッグを依頼：

```
Agent: connect()
Agent: set_breakpoint(file: "app/controllers/users_controller.rb", line: 15)
Agent: trigger_request(method: "GET", url: "http://localhost:3000/users/1")
Agent: get_context()
Agent: evaluate_code(code: "@user.attributes")
Agent: continue_execution()
```

### Docker内のRailsアプリをデバッグ

> **セキュリティ注意:** debug gemには認証機能がありません。デバッグポートにアクセスできれば、誰でもコンテナ内で任意のコードを実行できます。以下のようにアクセスを制限してください。

#### Option A: localhost限定TCP（シンプル）

デバッグポートを `127.0.0.1` にバインドし、ローカルプロセスのみ接続可能にします：

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
      - "127.0.0.1:12345:12345"  # localhostのみ
    environment:
      - RUBY_DEBUG_OPEN=true
      - RUBY_DEBUG_HOST=0.0.0.0
      - RUBY_DEBUG_PORT=12345
```

```
Agent: connect(port: 12345)
```

ローカルにソースコードがなくても、エージェントがコンテナ内のファイルを閲覧・読み取りできます。

#### Option B: Unixソケットボリュームマウント（推奨）

デバッグソケット用の共有ディレクトリをマウントします。ポート公開は不要です：

```yaml
services:
  web:
    build: .
    ports:
      - "3000:3000"
    environment:
      - RUBY_DEBUG_OPEN=true
      - RUBY_DEBUG_SOCK_PATH=/debug/rdbg.sock
    volumes:
      - debug_sock:/debug

volumes:
  debug_sock:
```

```
Agent: connect(path: "/path/to/debug_sock/rdbg.sock")
```

### 既存のブレークポイントに接続

```bash
# ターミナル: アプリが `debugger` 文に到達
rdbg --open my_app.rb
```

```
Agent: list_debug_sessions()
Agent: connect(path: "/tmp/rdbg-1000/rdbg-12345")
Agent: get_context()
```

## 仕組み

```
┌──────────────┐ STDIO or Streamable HTTP ┌───────────┐    TCP/Unixソケット   ┌──────────────┐
│ MCPクライアント │ ◄──────────────────────► │ debug-mcp  │ ◄──────────────────► │ Rubyプロセス  │
│              │       (JSON-RPC)         │(MCPサーバー) │  debug gemプロトコル  │  (rdbg)      │
└──────────────┘                           └───────────┘                      └──────────────┘
```

1. debug-mcpはSTDIO（デフォルト）またはStreamable HTTPで通信するMCPサーバーとして動作
2. debug gem（`rdbg --open`）が対象Rubyプロセスにソケットを公開
3. debug-mcpがdebug gemのワイヤープロトコルでそのソケットに接続
4. MCPツール呼び出しがデバッガコマンドに変換され、結果が返される
5. アイドル状態のセッションは設定可能なタイムアウト後に自動クリーンアップされる

## セキュリティ

debug-mcpはデバッグツールであり、実行中のRubyプロセスへの深いランタイムアクセスを提供します。

**専用ツールにより任意コード実行を最小化。** 変数の確認・ソースコードの閲覧・モデル構造の調査など、ほとんどのデバッグ操作は任意コードを実行しない専用ツールで行われます。ランタイム検査用に`evaluate_code`も利用可能で、危険な操作に対しては組み込みの安全性チェッカーが警告します。

**debug gemには認証機能がありません。** デバッグソケットにアクセスできれば、対象プロセスで任意のコードを実行できます。必ずlocalhost（`127.0.0.1`）にバインドするか、Unixソケットを使用してください。具体的な設定例は[Docker節](#docker内のrailsアプリをデバッグ)を参照してください。

## 関連プロジェクト

- [girb](https://github.com/rira100000000/girb) — 同じ思想を共有する、人間向けのAI搭載IRBアシスタント

## 開発

```bash
git clone https://github.com/rira100000000/debug-mcp.git
cd debug-mcp
bundle install
```

## ライセンス

MIT
