# dbtool — Aurora MySQL (8.4 互換) バックアップ / テストデータ投入ユーティリティ

JMeter による性能テストの前後で使う、Aurora Serverless v2 (MySQL 8.4 互換) 向けのユーティリティです。

| 機能 | コマンド |
|---|---|
| データベースのダンプ取得・復元 (mysqldump) | `dump` / `restore` |
| テーブルの全データを CSV にバックアップ・完全復元 | `export` / `import` |
| テーブルデータの削除 (TRUNCATE / 分割コミットの DELETE) | `truncate` / `delete` |
| CSV ファイルの大量ロード (LOAD DATA LOCAL INFILE) | `load` |
| テーブル定義から設定用 Excel を作成 → テストデータ生成・ロード・後片付け | `schema` / `validate` / `generate` / `prepare` / `cleanup` / `runs` |

- サーバー側: **RHEL 9 (bash シェルスクリプト)**。RHEL 9.8 + MySQL 8.4.7 で検証済みです。
- 設定用 Excel: **Windows 11 + Excel** (マクロ有効ブック `DataGenConfig.xlsm`)。

```
 [RHEL]  dbtool.sh schema  ──→  <DB>_datagen_<日時>.xlsm (テーブル定義と生成方式の初期値入り)
                                        │  Windows にコピー
 [Windows/Excel]  テーブル設定・列設定を編集 → [設定ファイル出力] ボタン → <DB>_datagen.conf
                                        │  サーバーにコピー
 [RHEL]  dbtool.sh validate -c x.conf    設定の検証 (DB の定義・データと照合)
         dbtool.sh prepare  -c x.conf    バックアップ → 事前処理 → 生成 → ロード → JMeter 用 CSV
         (JMeter で性能テスト)
         dbtool.sh cleanup               後片付け (バックアップからの復元 / 生成データの削除 など)
```

---

## 1. 動作環境

### サーバー (RHEL 9.x)
| 必要なもの | 備考 |
|---|---|
| bash 5.1 / gawk 5.1 / coreutils / gzip / util-linux (flock) | RHEL 9 標準 |
| MySQL クライアント 8.0 以上 (`mysql`, `mysqldump`) | `sudo dnf install mysql` (RHEL 9.8 では 8.0.46)。MariaDB のクライアントは不可 |
| python3 (標準ライブラリのみ) | `schema` コマンドで Excel を作るときだけ使用 (RHEL 9 に標準で入っています) |

### Aurora (DB クラスターパラメータグループ)
| パラメータ | 用途 |
|---|---|
| `local_infile = 1` | `load` / `import` / `prepare` / `cleanup(RESTORE)` で LOAD DATA LOCAL INFILE を使うため **必須** |
| `log_bin_trust_function_creators = 1` | バイナリログ有効時に、ダンプからトリガー/関数/プロシージャを `restore` する場合に必要 |

DB ユーザーには対象 DB の SELECT / INSERT / UPDATE / DELETE / CREATE / DROP (TRUNCATE に必要) / ALTER (AUTO_INCREMENT 復元) / INDEX / TRIGGER / SHOW VIEW / EVENT / LOCK TABLES 等が必要です (Aurora のマスターユーザーで動作します)。

### Windows
- Excel (Microsoft 365 / 2016 以降) — `DataGenConfig.xlsm` の編集とボタン操作に使用します。

---

## 2. セットアップ

1. `dbtool/` ディレクトリを RHEL サーバー (Aurora に接続できる EC2 など) にコピーします。
   ```bash
   cd dbtool
   chmod +x dbtool.sh
   ```
2. 接続設定を作成します (パスワードを含むので必ず `chmod 600`)。
   ```bash
   cp conf/client.cnf.sample conf/client.cnf
   vi conf/client.cnf        # host / user / password / ssl-mode を設定
   chmod 600 conf/client.cnf
   ```
   > **注意**: パスワードに `#` や `;` を含む場合は `password="Pa#ss"` のように **必ず引用符で囲んでください** (囲まないと `#` 以降がコメント扱いになり認証に失敗します)。
   > 他ユーザーが書込み可能な設定ファイルは mysql が**黙って無視**するため、dbtool は権限を検査してエラーにします。
3. 必要に応じて `conf/dbtool.conf` を編集します (既定 DB 名、出力先、更新を許可する DB 名の正規表現 など)。
4. 接続確認
   ```bash
   ./dbtool.sh ping
   ```

mysql_config_editor のログインパスを使う場合は `conf/dbtool.conf` の `MYSQL_LOGIN_PATH` に指定します (または `--login-path`)。

---

## 3. コマンド

`./dbtool.sh help` で一覧、`./dbtool.sh <コマンド> --help` で詳細を表示します。

共通オプション: `--defaults-file FILE` / `--login-path NAME` / `--conf FILE` / `--dry-run` (更新 SQL を表示するだけ) / `-y` (確認省略) / `-v` / `-q`

更新系のコマンドは実行前に接続先 (サーバー・ユーザー・DB) と対象を表示し、`yes` の入力を求めます。
`conf/dbtool.conf` の `ALLOWED_DATABASE_REGEX` を設定すると、それ以外の DB の更新を拒否できます (本番の誤操作防止)。

### 3.1 dump / restore (論理バックアップ)
```bash
./dbtool.sh dump -d appdb                       # backup/appdb_YYYYMMDD_HHMMSS.sql.gz (+ .sha256 / .meta)
./dbtool.sh dump -d appdb -t 'orders,order_*'   # 一部のテーブルだけ
./dbtool.sh dump --all-databases                # システム DB 以外すべて
./dbtool.sh restore -f backup/appdb_20261004_101010.sql.gz -d appdb_copy --create-db
./dbtool.sh restore -f ... --strip-definer      # DEFINER のユーザーが存在しない環境に復元する場合
```
- `--single-transaction --quick --hex-blob --routines --events --triggers --set-gtid-purged=OFF --no-tablespaces` で取得します (ロック不要・一貫性あり)。
- 取得後に **完了マーカー (`-- Dump completed`) とチェックサム** を確認し、途中で切れたダンプは採用しません。`restore` も実行前にチェックサムと完了マーカーを検証します。
- **注意**: mysqldump は FLOAT 型を有効6桁に丸めて出力します (MySQL の仕様)。FLOAT 列がある場合は警告を表示します。厳密に戻す必要があるテーブルは `export` (CSV) でもバックアップしてください (`export` は FLOAT も完全に復元できます)。
- ユーザー/権限 (mysql スキーマ) はダンプに含みません。

### 3.2 export / import (テーブルの CSV バックアップと完全復元)
```bash
./dbtool.sh export -d appdb -t 'customers,orders'          # backup/export_appdb_<日時>/
./dbtool.sh export -d appdb -t 'cust*' --gzip -o /data/bk
./dbtool.sh import -i backup/export_appdb_20261004_101010  # TRUNCATE → ロード → 件数確認 → AUTO_INCREMENT 復元
./dbtool.sh import -i ... -t customers --append            # 追加ロード
```
- 出力は `<テーブル>.csv` と `manifest.tsv` (件数・AUTO_INCREMENT・SHA-256)。`import` はチェックサムを検証します。
- **全データ型を完全に往復** できる形式です (NULL と文字列 `'NULL'` の区別、改行・タブ・引用符・バックスラッシュ・NUL・絵文字、BLOB/BINARY、BIT(64)、DECIMAL、FLOAT/DOUBLE の極値・非正規化数、JSON、空間データ、TIMESTAMP、latin1/cp932 列 など)。`CHECKSUM TABLE` が一致することを検証済みです。

### 3.3 truncate / delete / count
```bash
./dbtool.sh truncate -d appdb -t 'orders,order_items'
./dbtool.sh delete -d appdb -t orders --where "ordered_at < '2026-01-01'" --batch-rows 5000
./dbtool.sh count -d appdb -t '*'            # 正確な件数 (--estimate で統計情報の概算)
```
- `truncate` は外部キー検査を無効にして実行し、対象外のテーブルから参照されている場合は警告します。
- `delete` は `--batch-rows` 件ずつコミットするため、大量削除でも巨大トランザクションになりません。

### 3.4 load (CSV の大量ロード)
```bash
# dbtool 形式 (export / generate の出力)
./dbtool.sh load -d appdb -t customers -f customers.csv
# Excel 等で作った CSV (Shift_JIS, "" エスケープ, 空欄=NULL)
./dbtool.sh load -d appdb -t customers -f data.csv --format rfc4180 --encoding cp932
# 大きなファイルを 50万件ずつ 4 並列でコミット
./dbtool.sh load -d appdb -t events -f events.csv.gz --chunk-rows 500000 -P 4 --truncate
```
- 1行目のヘッダーの列名でテーブルの列に対応付けます (順不同、CSV にない列はデフォルト値)。`--no-header` の場合はテーブル定義順。
- ロード前に CSV を MySQL と同じ規則で解析し、**列数の不一致・閉じていない引用符を行番号付きで報告** して中止します。
- ファイル (または分割単位) ごとに 1 トランザクションでロードし、**警告が1件でもある、または件数が一致しない場合はロールバック** します (`--on-warning continue` でコミットも可)。
- CRLF・UTF-8 の BOM は自動判定します。`.gz` はそのまま読めます。

### 3.5 テストデータ: schema / validate / generate / prepare / cleanup / runs
```bash
./dbtool.sh schema -d appdb -t 'customers,orders,order_items,products' --with-parents
#   → output/appdb_datagen_<日時>.xlsm (+ .tsv)
./dbtool.sh validate -c appdb_datagen.conf
./dbtool.sh generate -c appdb_datagen.conf -o /data/gen     # CSV を生成するだけ (DB は変更しない)
./dbtool.sh prepare  -c appdb_datagen.conf                  # 本番実行 (実行ID が表示されます)
./dbtool.sh runs                                            # 実行履歴
./dbtool.sh cleanup                                         # 最新の実行を後片付け (--run <実行ID> で指定)
./dbtool.sh runs --delete <実行ID>                          # 実行記録 (バックアップ含む) の削除
```

`prepare` の処理:
1. 設定ファイルを検証 (エラーがあれば DB を一切変更せずに終了)
2. 事前バックアップ (`事前バックアップ=Y` のテーブルを CSV に出力)
3. 事前処理 (`TRUNCATE` / `DELETE`) を処理順の逆順に実行
4. 処理順にテーブルごとに 生成 → ロード → 件数確認
5. JMeter 用 CSV を `work/runs/<実行ID>/jmeter/<テーブル>.csv` に出力

実行の記録 (状態・バックアップ) は `work/runs/<実行ID>/` に残り、`cleanup` はそれを使って後片付けします。
`prepare` が途中で失敗しても、`cleanup` で変更したテーブルを元に戻せます。

| 後片付け | 内容 |
|---|---|
| `RESTORE` | TRUNCATE してから事前バックアップを復元し、AUTO_INCREMENT も元に戻す (JMeter が更新・追加したデータも含めて完全に元通り) |
| `DELETE_GENERATED` | 生成した行だけを、連番 (SEQ) の範囲で分割削除 (既存データと JMeter が追加したデータは残る) |
| `DELETE_WHERE` | 後片付け条件 (WHERE) に一致する行を分割削除 (例: 固定値の目印 `note = 'JMTEST'`) |
| `TRUNCATE` | 全件削除 |
| `NONE` | 何もしない |

---

## 4. 設定用 Excel (DataGenConfig.xlsm)

`schema` コマンドが作った `.xlsm` を Windows で開き、**[コンテンツの有効化]** でマクロを有効にすると、
「テーブル設定」「列設定」シートが自動作成されます (自動作成されない場合は「共通設定」シートの **[シートを再作成]**)。

| シート | 内容 |
|---|---|
| 使い方 | 操作手順 |
| 共通設定 | DB 名、ファイル分割件数、並列数、外部キー検査、タイムゾーン、基準日時、警告時の動作。**[設定ファイル出力] [入力チェック] [スキーマ取込 (TSV)] [シートを再作成]** ボタン |
| テーブル設定 | 対象 / 処理順 / 生成件数 / 事前処理 / 事前バックアップ / 後片付け / 後片付け条件 / 乱数シード / JMeter出力件数 (+ 参照用: 件数・主キー・外部キー・CHECK・トリガー 等) |
| 列設定 | 列ごとの 生成方式 / パラメータ1～3 / NULL率 / JMeter出力 (+ 参照用: データ型・NULL・キー・インデックス・デフォルト・外部キー・コメント・自動判定メモ)。「パラメータの意味」列に選んだ生成方式の説明を表示 |
| 生成方式一覧 | 生成方式・相対日時・文字種・テンプレートの説明 |

- **黄色が入力欄、灰色は参照のみ** です。生成方式・Y/N などはプルダウンで選択できます。
- [設定ファイル出力] は入力を検査し、誤りがあれば該当セルを赤くして出力を中止します。値の範囲やデータ型との整合性などの詳細な検査はサーバーの `validate` で行います。
- テーブル定義が変わったときは、`dbtool.sh schema ... --tsv-only` で TSV を作り **[スキーマ取込 (TSV)]** で読み込みます。テーブル名・列名・データ型が同じ列の設定は引き継がれます。
- メール等で受け取った .xlsm はマクロがブロックされることがあります。その場合はファイルのプロパティで [許可する] にチェックしてから開いてください。

### 4.1 自動判定される初期値
`schema` はテーブル定義から次のように初期値を決めます (Excel で変更できます)。

| 列の種類 | 初期値 |
|---|---|
| AUTO_INCREMENT / 数値の主キー・一意キー | `SEQ` 開始値 `AUTO` (既存の最大値+1 から連番) |
| 文字列の一意キー | `TEMPLATE ${seq:N}` (列名に mail を含めば `user${seq}@example.com`、uuid を含めば `UUID`) |
| BINARY(16) の一意キー | `UUID` (16バイト) |
| 外部キー | `REF 親テーブル.列 RANDOM` (複合外部キーは同じグループ名) |
| 複合主キー (第1列, 第2列) | 第1列 `SEQ 繰返し5` または `REF ... SEQ:5`、第2列 `CYCLE 1..5` (組合せが一意になる) |
| 自己参照の外部キー | NULL 可なら `NULL`、NOT NULL なら `COPY` (自分自身を参照) |
| 生成列 | `DEFAULT` (変更不可) |
| tinyint(1) | `RANDOM_INT 0 1` |
| 数値 / DECIMAL / FLOAT | 範囲内の `RANDOM_INT` / `RANDOM_DECIMAL` |
| 日付 / 日時 / 時刻 | `RANDOM_DATE TODAY-365～TODAY` / `RANDOM_DATETIME NOW-365d～NOW` / `RANDOM_TIME` |
| 文字列 | `RANDOM_STRING` (列名が tel/phone・zip・url なら電話番号・郵便番号・URL 形式の `TEMPLATE`) |
| ENUM / SET | `LIST` (定義されている値) |
| JSON | `FIXED {}` |
| BINARY / BLOB | `RANDOM_BYTES` |
| 空間データ型 | NULL 可なら `NULL`、NOT NULL なら `FIXED` + WKT |

処理順は外部キーの親が先になるように自動で並べます。

### 4.2 生成方式とパラメータ

| 生成方式 | 内容 | パラメータ1 | パラメータ2 | パラメータ3 |
|---|---|---|---|---|
| `SEQ` | 連番 (繰返し=1 なら一意) | 開始値 / `AUTO` | 増分 (1) | 繰返し回数 (1) |
| `TEMPLATE` | 書式文字列 | テンプレート | `${seq}` の開始値 (1) | `${seq}` の増分 (1) |
| `RANDOM_INT` | 範囲内のランダムな整数 | 最小値 | 最大値 | |
| `RANDOM_DECIMAL` | 範囲内のランダムな小数 | 最小値 | 最大値 | 小数桁数 (列の桁数) |
| `UNIQUE_INT` | 範囲内で **重複しない** ランダムな整数 | 最小値 | 最大値 | |
| `RANDOM_STRING` | ランダムな文字列 | 最小長 | 最大長 | 文字種 (alnum) |
| `UNIQUE_STRING` | **重複しない** ランダムな文字列 | 長さ | 文字種 (alnum) | 接頭辞 |
| `UUID` | UUID v4 形式 (実行内で一意) | `STD` / `UPPER` / `NOHYPHEN` | | |
| `LIST` | 値リストからランダム (重み付き可) | `A\|B\|C` / `1..100` | 重み `80\|15\|5` | |
| `CYCLE` | 値リストを順番に繰返し | `A\|B\|C` / `1..100` | 各値の繰返し回数 (1) | |
| `RANDOM_DATE` | ランダムな日付 | 開始 (TODAY-365) | 終了 (TODAY) | |
| `RANDOM_DATETIME` | ランダムな日時 | 開始 (NOW-365d) | 終了 (NOW) | 小数秒桁数 |
| `RANDOM_TIME` | ランダムな時刻 | 開始 (00:00:00) | 終了 (23:59:59) | 小数秒桁数 |
| `SEQ_DATETIME` | 日付・日時の連番 | 開始 | 増分 `1d` `12h` `30m` `10s` | 繰返し回数 (1) |
| `REF` | 親テーブルの値 | `テーブル.列` | `RANDOM` / `SEQ` / `SEQ:n` | グループ名 |
| `RANDOM_BYTES` | ランダムなバイナリ | 最小バイト数 | 最大バイト数 | |
| `FIXED` | 固定値 | 値 (`0x..` / `b'0101'` / WKT 可) | 空間型の SRID | |
| `COPY` | 同じ行の他の列の値 | 列名 | | |
| `NULL` | 常に NULL | | | |
| `DEFAULT` | 値を設定しない (DB の既定値・AUTO_INCREMENT) | | | |

- **NULL率(%)**: NULL 可の列で、指定した割合を NULL にします。
- **JMeter出力**: `Y` の列を JMeter 用 CSV (`jmeter/<テーブル>.csv`, UTF-8, ヘッダー付き) に出力します。テーブル設定の「JMeter出力件数」を指定すると全体から均等に抽出します。
- **相対日時**: `TODAY` `TODAY-30` `TODAY+7` (日数) / `NOW` `NOW-30d` `NOW-12h` `NOW-15m` `NOW-60s`。基準は共通設定の「基準日時」(空欄なら実行時の DB の現在日時)。基準日時を固定すると毎回同じデータになります。
- **文字種**: `digit` `upper` `lower` `alpha` `alnum` `hex` `hexupper` `ascii` `hira` `kata` `hankana` `kanji` `zenkaku`
- **テンプレート**: `${seq}` `${seq:8}` (ゼロ埋め) / `${int:1,100}` `${int:1,100,3}` / `${alnum:8}` `${hira:2,5}` (文字種:長さ) / `${list:東京|大阪}` / `${uuid}` / `$${` (文字 `${`)
- **REF の選択方法**: `RANDOM` (ランダム) / `SEQ` (親の値を順番に) / `SEQ:5` (親1件につき5行ずつ)。複合外部キーは同じ「グループ名」を指定すると同じ親行の値の組合せになります。
  親テーブルが同じ設定で生成される場合はその生成値、そうでなければ DB の既存値から選びます。

---

## 5. 正確性・安全性のための仕組み

- **事前検証 (`validate` / `prepare` の最初)**: すべての列について、データ型・長さ (文字数/バイト数, 文字コード別)・数値範囲 (UNSIGNED, DECIMAL の桁数, BIT 幅)・日付の妥当性と範囲 (TIMESTAMP の 2038 年問題を含む)・ENUM/SET の値・文字コードで表現できない文字・NOT NULL・JSON / WKT の妥当性 (DB で検証)・外部キーの処理順 を検査します。
- **一意性**: SEQ / UNIQUE_INT / UNIQUE_STRING / UUID / TEMPLATE(${seq}) は数学的に重複しない方法 (連番・全単射の置換) で生成します。それ以外の方式を一意キーに使う場合は重複確率を計算し、ほぼ確実に重複する場合はエラー、可能性がある場合は警告します。大文字小文字を区別しない照合順序も考慮します。追加モードでは既存データとの重複も DB で確認します。
- **ロード**: ファイルごとに 1 トランザクションで LOAD DATA を実行し、取込件数と警告件数をサーバー側で判定して、**1件でも警告・件数不一致があればロールバック** します (LOAD DATA LOCAL は既定で重複や型変換エラーを警告にして続行してしまうため)。ロード後にテーブル件数も確認します。
- **再現性**: 乱数シードと基準日時が同じなら、同じ件数・同じ分割で同じデータを生成します。一意値は分割数や並列数に関係なく同じです。
- **バックアップの正確性**: CSV は全データ型を往復可能な形式で出力し、出力時の警告 (値が max_allowed_packet を超えた等) と途中切断を検出します。復元後は件数と AUTO_INCREMENT を確認します。
- **後片付け**: 実行ごとに状態を記録し、途中で失敗しても変更したテーブルだけを元に戻せます。同じ実行の二重の後片付けは拒否します。
- **安全策**: 更新前の確認 (`-y` で省略)、`--dry-run`、`ALLOWED_DATABASE_REGEX`、多重実行防止ロック、出力ファイルは所有者のみ読める権限 (umask 077)、ログ (`log/dbtool_YYYYMMDD.log`)。

---

## 6. 注意事項・制約

- 生成する整数値 (連番など) は ±2^53 (約 9×10^15) の範囲です (固定値・リストは BIGINT の全範囲を指定可)。
- `REF` の参照先が別の生成方式 (UUID など) や DB の既存値で、件数が非常に多い場合 (数百万件以上) は生成処理のメモリ使用量が大きくなります。参照先の主キーを `SEQ` にすると計算で求めるためメモリを使いません。
- CHECK 制約の内容は事前検証できません (制約違反はロード時に検出してロールバックします)。
- トリガーはロード時に実行されます。トリガーが他のテーブルを変更する場合、そのテーブルは後片付けの対象外です。
- 外部キー検査を OFF にしてロード/削除すると、対象外のテーブルに参照先のない行が残ることがあります (該当する場合は警告を表示します)。
- MySQL の Note レベルのメッセージ (生成列の DECIMAL 丸めなど) はエラーとして扱いません。
- Aurora Serverless v2 は大量ロード中に ACU がスケールします。最小 ACU が小さいと序盤が遅くなることがあります。並列数 (`parallel`) は ACU に合わせて調整してください。
- 設定ファイルや conf ファイルを Windows で編集した場合も読めますが、`client.cnf` は改行 LF を推奨します。

### 性能の目安
- 生成: 15 列 (日本語の文字列・テンプレート・UUID・日時を含む) のテーブルで、並列数 2 のとき約 6,000 行/秒 (検証環境: Windows 上の Docker、メモリ制限 512MB のコンテナ)。並列数 (`parallel`) に比例して速くなります。
- ロード: ファイル (= `rows_per_file` 件) ごとに 1 トランザクションで、`parallel` 本の接続で同時にロードします。大量データでは `rows_per_file` を 10万～50万、`parallel` を Aurora の vCPU/ACU に合わせて増やしてください。外部キー検査を OFF にすると速くなります (整合性は REF で担保)。
- 生成した CSV は `prepare` の完了後に削除されます (`--keep-data` で残せます)。ディスク容量は「1行の平均バイト数 × 件数」程度必要です。

---

## 7. ファイル構成

```
README.md
dbtool/                         ← RHEL にコピーして使うツール一式
  dbtool.sh                     メインスクリプト
  conf/dbtool.conf              ツール設定
  conf/client.cnf.sample        接続設定のサンプル
  templates/DataGenConfig.xlsm  設定用 Excel のテンプレート (schema が使用)
  lib/                          bash / awk / python のライブラリ
    common.sh db.sh dataio.sh cmd_backup.sh cmd_table.sh cmd_datagen.sh
    util.awk schema_lib.awk schema.awk plan.awk gen.awk csv.awk colspec.awk export_filter.awk
    xlsm_embed.py
excel/
  DataGenConfig.xlsm            設定用 Excel (空のテンプレート。[スキーマ取込] で TSV を読み込んで使うことも可)
  vba/modDataGen.bas            VBA ソース
  vba/ThisWorkbook.cls
  build_xlsm.ps1                VBA ソースから DataGenConfig.xlsm を作り直すスクリプト
tests/                          検証に使ったテスト (Docker: RHEL 9.8 UBI + MySQL 8.4.7)
```

`dbtool/` 配下に実行時に作られるディレクトリ: `backup/` (dump/export)、`work/` (prepare の実行記録・一時ファイル)、`log/`、`output/` (schema の Excel)。

### Excel テンプレートの作り直し
VBA を変更した場合は Windows で次を実行します。
```powershell
powershell -ExecutionPolicy Bypass -File .\excel\build_xlsm.ps1
```
VBA を組み込むために Excel の「VBA プロジェクト オブジェクト モデルへのアクセスを信頼する」設定を一時的に有効にし、終了時に元に戻します。

---

## 8. 設定ファイル (.conf) の形式

Excel の [設定ファイル出力] で作成します (手で編集することもできます)。UTF-8 (BOM なし) / 改行 LF / TAB 区切りで、値の `\` TAB 改行 は `\\` `\t` `\n` でエスケープします。

```
#DBTOOL-DATAGEN-CONFIG	1
GLOBAL	database	appdb
GLOBAL	rows_per_file	100000
GLOBAL	parallel	2
GLOBAL	fk_checks	ON
GLOBAL	time_zone	+09:00
GLOBAL	base_datetime	2026-10-01 12:00:00
GLOBAL	on_warning	ROLLBACK
TABLE	customers	Y	1000000	20	TRUNCATE	Y	RESTORE		12345	10000
COLUMN	customers	id	bigint unsigned	SEQ	AUTO	1	1	0	Y
COLUMN	customers	email	varchar(255)	TEMPLATE	user${seq:8}@example.com	1	1	0	Y
```
- `TABLE`: テーブル / 対象(Y/N) / 生成件数 / 処理順 / 事前処理 / 事前バックアップ / 後片付け / 後片付け条件 / 乱数シード / JMeter出力件数
- `COLUMN`: テーブル / 列 / データ型 / 生成方式 / パラメータ1 / パラメータ2 / パラメータ3 / NULL率 / JMeter出力
- データ型は Excel 作成時の型で、実行時の DB の型と異なる場合は警告します (検証は常に実行時の DB の定義で行います)。

### CSV 形式 (export / generate / load の既定)
UTF-8・1行目は列名・区切り `,`・文字列は `"…"` (中の `"` は `""`)・`\` 改行 タブ は `\\` `\n` `\t`・**NULL は引用符なしの `NULL`**・バイナリ/空間型は16進・BIT は10進・TIMESTAMP は UTC。
MySQL の `LOAD DATA … FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"' ESCAPED BY '\\'` と同じ規則です。

---

## 9. 検証について

次の環境で動作を検証しました。
- クライアント: Red Hat UBI 9.8 (RHEL 9.8) + RHEL 標準の mysql 8.0.46 クライアント / bash 5.1.8 / gawk 5.1.0 / Python 3.9
- サーバー: MySQL 8.4.7 (TLS 必須・GTID 有効・binlog 有効、SUPER / SET_ANY_DEFINER のない Aurora マスターユーザー相当の権限)
- Excel: Microsoft 365 (Windows 11)

主な確認内容:
- export → TRUNCATE → import で、全データ型のテーブルと AUTO_INCREMENT が `CHECKSUM TABLE` で完全一致 (FLOAT/DOUBLE の極値・非正規化数を含む 1,000 行のストレステストも一致)
- dump → restore (別 DB) でビュー・プロシージャ・トリガーを含め復元 (FLOAT の丸めは mysqldump の仕様として警告)、途中で切れたダンプの拒否、`--strip-definer`
- schema → Excel (自動展開・入力チェック・設定ファイル出力・再取込での設定引継ぎ) → validate → prepare → cleanup で、11 テーブル (外部キー・複合主キー/外部キー・自己参照・リンクテーブル・生成列・不可視列・CHECK 制約・トリガー・空間型・latin1/cp932 列) の生成とロード、件数・外部キー整合性・値の範囲・NULL率・重み付き選択を確認し、後片付けで全テーブルが `CHECKSUM TABLE` で元通り
- 追加モード (`SEQ AUTO`) + `DELETE_GENERATED` / `DELETE_WHERE`、`before=DELETE` + `RESTORE`、二重後片付けの拒否
- 設定ミス 20 種類以上の検出、CHECK 制約違反でのロード失敗 → ロールバック → 失敗した実行の後片付け
- load: RFC 4180 (BOM・CRLF・引用符内の改行・空欄→NULL)、Shift_JIS (日本語のヘッダー名を含む)、ヘッダーなし、2万件 gzip の分割並列ロード、主キー重複時のロールバック、列数不正・存在しない列の検出、条件付き分割 DELETE、TRUNCATE
- 静的解析: shellcheck (警告なし)

回帰テスト `tests/regression.sh` (34 項目) は、テスト用の MySQL に `tests/sql/01_schema.sql` と `02_seed.sql` を投入したうえで、
RHEL 上で `bash tests/regression.sh` (dbtool ディレクトリで実行) のように使えます。**本番やテスト以外の DB では実行しないでください** (perf / perf_restore データベースを作り直します)。
Excel 側の自動テストは `tests/excel/test_excel.ps1` です。
