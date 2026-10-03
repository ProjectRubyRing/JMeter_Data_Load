# shellcheck shell=bash
# =============================================================================
# db.sh : MySQL クライアントの呼び出し・メタデータ取得
# =============================================================================

MYSQL_OPTS=()
MYSQL_BIN=mysql
MYSQLDUMP_BIN=mysqldump
DB_NAME=""
SERVER_VERSION=""
SERVER_INFO=""
SQL_MODE_STRICT="STRICT_ALL_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
SQL_MODE_RESTORE="NO_AUTO_VALUE_ON_ZERO"

sql_ident() { local s=${1//\`/\`\`}; printf '`%s`' "$s"; }
sql_str() { local s=${1//\\/\\\\}; s=${s//\'/\'\'}; printf "'%s'" "$s"; }
qtable() { printf '%s.%s' "$(sql_ident "$DB_NAME")" "$(sql_ident "$1")"; }

# 接続オプションの組立てとクライアントの確認
db_init() {
  local defaults login
  defaults=$(resolve_path "${OPT_DEFAULTS_FILE:-$(conf MYSQL_DEFAULTS_FILE)}")
  login=${OPT_LOGIN_PATH:-$(conf MYSQL_LOGIN_PATH)}
  MYSQL_BIN=$(conf MYSQL_BIN mysql)
  MYSQLDUMP_BIN=$(conf MYSQLDUMP_BIN mysqldump)
  require_cmd "$MYSQL_BIN"
  check_client_version "$MYSQL_BIN"
  MYSQL_CONN=()
  if [[ -n $defaults ]]; then
    check_defaults_file "$defaults"
    MYSQL_CONN+=("--defaults-file=$defaults")
  fi
  [[ -n $login ]] && MYSQL_CONN+=("--login-path=$login")
  if [[ -z $defaults && -z $login ]]; then
    log_warn "接続設定 (MYSQL_DEFAULTS_FILE / MYSQL_LOGIN_PATH) が未指定です。mysql の既定の設定ファイルで接続します"
  fi
  # --defaults-file / --login-path は先頭に置く必要がある
  MYSQL_OPTS=("${MYSQL_CONN[@]}" --default-character-set=utf8mb4 "--connect-timeout=$(conf CONNECT_TIMEOUT 30)" --max-allowed-packet=1073741824)
  MYSQLDUMP_OPTS=("${MYSQL_CONN[@]}" --default-character-set=utf8mb4 --max-allowed-packet=1073741824)
  return 0
}

check_client_version() {
  local bin=$1 v major
  v=$("$bin" --version 2>&1 || true)
  log_debug "クライアント: $v"
  if [[ $v == *MariaDB* ]]; then
    die "MariaDB のクライアントは未対応です ($v)。MySQL のクライアントをインストールしてください (例: dnf install mysql)"
  fi
  if [[ $v =~ Ver[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
    major=${BASH_REMATCH[1]}
    ((major >= 8)) || die "MySQL クライアント 8.0 以上が必要です ($v)"
  else
    die "MySQL クライアントのバージョンを判別できません: $v"
  fi
}

# mysql は他ユーザーが書込み可能な設定ファイルを黙って無視するため事前に確認する
check_defaults_file() {
  local f=$1 mode
  [[ -f $f ]] || die "接続設定ファイルがありません: $f (conf/client.cnf.sample を参考に作成してください)"
  [[ -r $f ]] || die "接続設定ファイルを読み込めません: $f"
  mode=$(stat -c %a -- "$f")
  if (( (8#$mode & 8#002) != 0 )); then
    die "接続設定ファイルが他ユーザーから書込み可能なため mysql に無視されます: $f (chmod 600 $f を実行してください)"
  fi
  if (( (8#$mode & 8#044) != 0 )); then
    log_warn "接続設定ファイルが他ユーザーから読める権限です (パスワード保護のため chmod 600 を推奨): $f"
  fi
}

sql_preamble() { # sql_preamble <strict|restore> [time_zone] [foreign_key_checks 0/1]
  local sm=$SQL_MODE_STRICT
  [[ ${1-} == restore ]] && sm=$SQL_MODE_RESTORE
  printf "SET NAMES utf8mb4;\nSET SESSION sql_mode='%s';\nSET SESSION information_schema_stats_expiry=0;\n" "$sm"
  [[ -n ${2-} ]] && printf 'SET SESSION time_zone=%s;\n' "$(sql_str "$2")"
  [[ -n ${3-} ]] && printf 'SET SESSION foreign_key_checks=%s;\n' "$3"
  return 0
}

mysql_errmsg() { # エラーファイルから警告以外のメッセージを取り出す
  local f=$1
  [[ -s $f ]] || { printf '(メッセージなし)'; return 0; }
  grep -v '^mysql: \[Warning\]' -- "$f" | grep -v '^mysqldump: \[Warning\]' | tr '\n' ' ' | sed 's/ *$//'
}

# SQL を実行し結果 (--batch, 列名なし) を標準出力へ。失敗時は終了する。
#   db_query SQL [mysql の追加オプション...]
db_query() {
  local sql=$1; shift
  local out errf
  errf=$(mktemp "$TMP_DIR/err.XXXXXX")
  if out=$({ sql_preamble strict; printf '%s\n' "$sql"; } | "$MYSQL_BIN" "${MYSQL_OPTS[@]}" --batch --skip-column-names "$@" 2>"$errf"); then
    rm -f -- "$errf"
    [[ -n $out ]] && printf '%s\n' "$out"
    return 0
  fi
  log_error "SQL の実行に失敗しました: $(mysql_errmsg "$errf")"
  log_debug "SQL: $sql"
  rm -f -- "$errf"
  exit 1
}

# 失敗しても終了しない版。成功 0 / 失敗 1。エラー文は DB_ERROR、結果は DB_OUT
db_try() {
  local sql=$1; shift
  local errf
  errf=$(mktemp "$TMP_DIR/err.XXXXXX")
  DB_ERROR=""
  if DB_OUT=$({ sql_preamble strict; printf '%s\n' "$sql"; } | "$MYSQL_BIN" "${MYSQL_OPTS[@]}" --batch --skip-column-names "$@" 2>"$errf"); then
    rm -f -- "$errf"; return 0
  fi
  DB_ERROR=$(mysql_errmsg "$errf")
  rm -f -- "$errf"
  return 1
}

# 接続確認 (Aurora Serverless v2 の再開待ちを考慮してリトライ)
db_connect() {
  local tries interval i errf out aurora
  tries=$(conf CONNECT_RETRIES 3); interval=$(conf CONNECT_RETRY_INTERVAL 10)
  errf=$(mktemp "$TMP_DIR/err.XXXXXX")
  for ((i = 1; i <= tries; i++)); do
    if out=$(printf "SELECT VERSION(), CURRENT_USER(), @@hostname, @@local_infile, @@time_zone, @@system_time_zone;\nSHOW GLOBAL VARIABLES LIKE 'aurora_version';\n" |
      "$MYSQL_BIN" "${MYSQL_OPTS[@]}" --batch --skip-column-names 2>"$errf"); then
      IFS=$'\t' read -r SERVER_VERSION DB_USER DB_HOSTNAME DB_LOCAL_INFILE DB_TZ DB_SYSTZ <<<"$(head -n 1 <<<"$out")"
      aurora=$(awk -F'\t' '$1 == "aurora_version" { print $2 }' <<<"$out")

      SERVER_INFO="MySQL $SERVER_VERSION${aurora:+ (Aurora $aurora)} / ユーザー $DB_USER / ホスト $DB_HOSTNAME"
      log_info "接続しました: $SERVER_INFO"
      rm -f -- "$errf"
      return 0
    fi
    log_warn "データベースに接続できません ($i/$tries): $(mysql_errmsg "$errf")"
    ((i < tries)) && sleep "$interval"
  done
  rm -f -- "$errf"
  die "データベースに接続できませんでした。接続設定 (ホスト/ユーザー/パスワード/SSL) とネットワークを確認してください"
}

require_local_infile() {
  if [[ ${DB_LOCAL_INFILE:-0} != 1 ]]; then
    die "サーバーの local_infile が無効です (LOAD DATA LOCAL INFILE を使用できません)。Aurora の場合は DB クラスターパラメータグループで local_infile=1 を設定してください"
  fi
}

# 対象データベースの決定と存在確認
use_database() {
  local db=$1 found
  [[ -n $db ]] || die "データベース名を -d で指定してください (または conf/dbtool.conf の DEFAULT_DATABASE)"
  found=$(db_query "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME=$(sql_str "$db")" --raw)
  [[ -n $found ]] || die "データベースが存在しません: $db"
  DB_NAME=$found
}

# 破壊的な操作の前に、許可されたデータベースか確認
check_allowed_db() {
  local re
  re=$(conf ALLOWED_DATABASE_REGEX)
  [[ -z $re ]] && return 0
  if [[ ! $DB_NAME =~ $re ]]; then
    die "データベース $DB_NAME は更新が許可されていません (ALLOWED_DATABASE_REGEX=$re)"
  fi
}

# テーブル指定 (カンマ区切り, * はワイルドカード) を実在するテーブル名の配列 TABLES に展開
expand_tables() {
  local spec=$1 item pat found name
  local -A seen=()
  TABLES=()
  split_list "$spec"
  ((${#LIST_RESULT[@]} > 0)) || die "テーブルを -t で指定してください"
  for item in "${LIST_RESULT[@]}"; do
    if [[ $item == *'*'* ]]; then
      pat=${item//\\/\\\\}; pat=${pat//%/\\%}; pat=${pat//_/\\_}; pat=${pat//\*/%}
      found=$(db_query "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=$(sql_str "$DB_NAME") AND TABLE_TYPE='BASE TABLE' AND TABLE_NAME LIKE $(sql_str "$pat") ORDER BY TABLE_NAME" --raw)
      [[ -n $found ]] || die "パターンに一致するテーブルがありません: $item"
    else
      found=$(db_query "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA=$(sql_str "$DB_NAME") AND TABLE_TYPE='BASE TABLE' AND TABLE_NAME=$(sql_str "$item")" --raw)
      [[ -n $found ]] || die "テーブルが存在しません: $DB_NAME.$item"
    fi
    while IFS= read -r name; do
      [[ -z $name || -n ${seen[$name]-} ]] && continue
      seen[$name]=1; TABLES+=("$name")
    done <<<"$found"
  done
}

# information_schema からスキーマ情報を取得 (schema_lib.awk の入力形式)
fetch_schema() {
  local t in="" dbq
  dbq=$(sql_str "$DB_NAME")
  for t in "$@"; do in+="${in:+,}$(sql_str "$t")"; done
  [[ -n $in ]] || die "fetch_schema: テーブルが指定されていません"
  db_query "
SELECT 'T', TABLE_NAME, IFNULL(ENGINE,''), IFNULL(TABLE_ROWS,''), IFNULL(AUTO_INCREMENT,''), IFNULL(TABLE_COLLATION,''), TABLE_COMMENT, TABLE_TYPE
  FROM information_schema.TABLES WHERE TABLE_SCHEMA=$dbq AND TABLE_NAME IN ($in) ORDER BY TABLE_NAME;
SELECT 'C', TABLE_NAME, ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, IS_NULLABLE, IF(COLUMN_DEFAULT IS NULL,'1','0'), IFNULL(COLUMN_DEFAULT,''),
       COLUMN_KEY, EXTRA, IFNULL(CHARACTER_MAXIMUM_LENGTH,''), IFNULL(CHARACTER_OCTET_LENGTH,''), IFNULL(NUMERIC_PRECISION,''), IFNULL(NUMERIC_SCALE,''),
       IFNULL(DATETIME_PRECISION,''), IFNULL(CHARACTER_SET_NAME,''), IFNULL(COLLATION_NAME,''), IFNULL(GENERATION_EXPRESSION,''), IFNULL(SRS_ID,''), COLUMN_COMMENT
  FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=$dbq AND TABLE_NAME IN ($in) ORDER BY TABLE_NAME, ORDINAL_POSITION;
SELECT 'I', TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, IFNULL(COLUMN_NAME,''), IFNULL(SUB_PART,''), IFNULL(EXPRESSION,''), INDEX_TYPE
  FROM information_schema.STATISTICS WHERE TABLE_SCHEMA=$dbq AND TABLE_NAME IN ($in)
 ORDER BY TABLE_NAME, INDEX_NAME='PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX;
SELECT 'F', k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION, k.COLUMN_NAME, k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME, k.REFERENCED_COLUMN_NAME, r.UPDATE_RULE, r.DELETE_RULE
  FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r
    ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME AND r.TABLE_NAME = k.TABLE_NAME
 WHERE k.TABLE_SCHEMA=$dbq AND k.TABLE_NAME IN ($in) AND k.REFERENCED_TABLE_NAME IS NOT NULL
 ORDER BY k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION;
SELECT 'R', k.REFERENCED_TABLE_NAME, k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME
  FROM information_schema.KEY_COLUMN_USAGE k
 WHERE k.REFERENCED_TABLE_SCHEMA=$dbq AND k.REFERENCED_TABLE_NAME IN ($in) AND k.ORDINAL_POSITION = 1
 ORDER BY 2, 3, 4, 5;
SELECT 'K', tc.TABLE_NAME, cc.CONSTRAINT_NAME, cc.CHECK_CLAUSE, tc.ENFORCED
  FROM information_schema.TABLE_CONSTRAINTS tc JOIN information_schema.CHECK_CONSTRAINTS cc
    ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
 WHERE tc.TABLE_SCHEMA=$dbq AND tc.CONSTRAINT_TYPE='CHECK' AND tc.TABLE_NAME IN ($in) ORDER BY 2, 3;
SELECT 'G', EVENT_OBJECT_TABLE, TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION
  FROM information_schema.TRIGGERS WHERE EVENT_OBJECT_SCHEMA=$dbq AND EVENT_OBJECT_TABLE IN ($in) ORDER BY 2, 3;"
}

# 他のテーブルからの外部キー参照 (データを削除するテーブルを、対象外のテーブルが参照している場合に警告)
warn_external_refs() { # warn_external_refs schema.tsv 削除対象テーブル...
  local schema=$1; shift
  local out
  (($# > 0)) || return 0
  out=$(DBT_LIST="$(printf '%s\n' "$@")" DBT_DB="$DB_NAME" awkc -F'\t' '
    BEGIN { n = split(ENVIRON["DBT_LIST"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") IN[a[i]] = 1; DB = ENVIRON["DBT_DB"] }
    $1 == "R" && ($2 in IN) && !($3 == DB && ($4 in IN)) { print $2 " ← " $3 "." $4 " (" $5 ")" }' "$schema")
  if [[ -n $out ]]; then
    log_warn "対象外のテーブルから外部キーで参照されています (外部キー検査を無効にして処理するため、参照元に孤立したデータが残る可能性があります):"
    log_block WARN "    " "$out"
  fi
}

# テーブルの正確な件数
count_rows() { db_query "SELECT COUNT(*) FROM $(qtable "$1")" --raw; }

# AUTO_INCREMENT の現在値 (なければ空)
get_auto_increment() {
  db_query "SELECT IFNULL(AUTO_INCREMENT,'') FROM information_schema.TABLES WHERE TABLE_SCHEMA=$(sql_str "$DB_NAME") AND TABLE_NAME=$(sql_str "$1")" --raw
}
