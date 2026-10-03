# shellcheck shell=bash
# =============================================================================
# common.sh : 共通関数 (ログ / エラー処理 / 設定読込 / ユーティリティ)
# =============================================================================

LOG_FILE=""
VERBOSE=0
QUIET=0
ASSUME_YES=0
DRY_RUN=0
TMP_DIR=""
LOCK_FD=""

# ---- ログ ---------------------------------------------------------------------
_log() {
  local level=$1; shift
  local ts line
  printf -v ts '%(%Y-%m-%d %H:%M:%S)T' -1
  line="[$ts] [$level] $*"
  case $level in
    DEBUG) ((VERBOSE)) && printf '%s\n' "$line" >&2 ;;
    INFO)  ((QUIET)) || printf '%s\n' "$line" >&2 ;;
    *)     printf '%s\n' "$line" >&2 ;;
  esac
  if [[ -n $LOG_FILE ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
  return 0
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { _log DEBUG "$@"; }
die() { log_error "$@"; exit 1; }

# 複数行のテキストをログに出力 (各行に接頭辞)
log_block() {
  local level=$1 prefix=$2 text=$3 line
  [[ -z $text ]] && return 0
  while IFS= read -r line; do _log "$level" "$prefix$line"; done <<<"$text"
}

# ---- 終了処理 -------------------------------------------------------------------
_on_exit() {
  local rc=$?
  local pids
  if [[ -n ${RUN_STATE:-} && ${RUN_FINISHED:-0} != 1 && $BASH_SUBSHELL -eq 0 ]]; then
    printf '%s\tRUN\tFAILED\texit=%s\n' "$(now_disp)" "$rc" >>"$RUN_STATE" 2>/dev/null || true
  fi
  pids=$(jobs -pr 2>/dev/null || true)
  if [[ -n $pids ]]; then
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    wait 2>/dev/null || true
  fi
  if [[ -n $TMP_DIR && -d $TMP_DIR && $VERBOSE -lt 2 ]]; then rm -rf -- "$TMP_DIR"; fi
  return $rc
}
_on_err() {
  local rc=$1 line=$2 cmd=$3
  # errexit が無効な文脈 (コマンド置換内など) の失敗は呼び出し元で判定するため報告しない
  [[ $- == *e* ]] || return 0
  log_debug "処理を中断しました (終了コード $rc, ${BASH_SOURCE[1]##*/}:$line: $cmd)"
}
_on_signal() {
  log_error "中断されました (シグナル受信)。処理中のトランザクションはロールバックされます"
  exit 130
}
setup_traps() {
  trap '_on_err $? $LINENO "$BASH_COMMAND"' ERR
  trap _on_exit EXIT
  trap _on_signal INT TERM HUP
}

# ---- ツール設定ファイル (KEY=VALUE) -----------------------------------------------
# 値はそのまま扱い、シェルとしては評価しない (source しない)
CONF_KEYS=" MYSQL_DEFAULTS_FILE MYSQL_LOGIN_PATH DEFAULT_DATABASE BACKUP_DIR WORK_DIR LOG_DIR MYSQL_BIN MYSQLDUMP_BIN CONNECT_TIMEOUT CONNECT_RETRIES CONNECT_RETRY_INTERVAL DELETE_BATCH_ROWS DUMP_COMPRESS ALLOWED_DATABASE_REGEX KEEP_RUNS "
load_tool_conf() {
  local f=$1 line key val n=0
  [[ -f $f ]] || die "設定ファイルがありません: $f"
  [[ -r $f ]] || die "設定ファイルを読み込めません: $f"
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      key=${BASH_REMATCH[1]}
      val=$(trim "${BASH_REMATCH[2]}")
      if [[ $val =~ ^\"(.*)\"$ || $val =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
      if [[ $CONF_KEYS == *" $key "* ]]; then
        printf -v "CONF_$key" '%s' "$val"
      else
        log_warn "設定ファイルの未知の項目を無視します: $f:$n: $key"
      fi
    else
      die "設定ファイルの書式が不正です ($f:$n): $line"
    fi
  done <"$f"
}

conf() { # conf KEY DEFAULT
  local v="CONF_$1"
  if [[ -n ${!v-} ]]; then printf '%s' "${!v}"; else printf '%s' "${2-}"; fi
}

# ---- 文字列 -------------------------------------------------------------------
trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# 相対パスは dbtool のディレクトリ基準で絶対パス化
resolve_path() {
  local p=$1
  [[ -z $p ]] && return 0
  if [[ $p == /* ]]; then printf '%s' "$p"; else printf '%s/%s' "$DBTOOL_HOME" "$p"; fi
}

# "a, b ,c" → 配列 (空要素は除外)。結果は LIST_RESULT  ※ * などはパス名展開しない
split_list() {
  local s=$1 item
  local -a parts=()
  LIST_RESULT=()
  IFS=',' read -r -a parts <<<"$s" || true
  for item in "${parts[@]}"; do
    item=$(trim "$item")
    [[ -n $item ]] && LIST_RESULT+=("$item")
  done
  return 0
}

human_size() {
  local b=${1:-0}
  awk -v b="$b" 'BEGIN { split("B KB MB GB TB", u, " "); i = 1; while (b >= 1024 && i < 5) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'
}

fmt_duration() {
  local s=${1:-0}
  if ((s >= 3600)); then printf '%d時間%02d分%02d秒' $((s / 3600)) $((s % 3600 / 60)) $((s % 60))
  elif ((s >= 60)); then printf '%d分%02d秒' $((s / 60)) $((s % 60))
  else printf '%d秒' "$s"; fi
}

fmt_num() { awk -v n="$1" 'BEGIN { s = sprintf("%d", n); r = ""; while (length(s) > 3) { r = "," substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) } print s r }'; }

now_ts() { printf '%(%Y%m%d_%H%M%S)T' -1; }
now_disp() { printf '%(%Y-%m-%d %H:%M:%S)T' -1; }

# ---- 確認 ---------------------------------------------------------------------
confirm() { # confirm メッセージ [中止時に削除するディレクトリ]
  local msg=$1 rmdir_on_abort=${2-} ans
  if ((ASSUME_YES)); then log_info "確認を省略しました (-y): $msg"; return 0; fi
  if [[ ! -t 0 ]]; then
    [[ -n $rmdir_on_abort ]] && rm -rf -- "$rmdir_on_abort"
    die "確認が必要な操作です。非対話で実行する場合は -y を指定してください"
  fi
  printf '\n%s\n続行するには yes と入力してください: ' "$msg" >&2
  IFS= read -r ans || ans=""
  if [[ $ans != yes && $ans != YES ]]; then
    [[ -n $rmdir_on_abort ]] && rm -rf -- "$rmdir_on_abort"
    log_info "中止しました"; exit 1
  fi
  log_info "ユーザーが続行を承認しました"
}

# ---- 外部コマンド ---------------------------------------------------------------
require_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "コマンドが見つかりません: $c"; done
}

awkc() { LC_ALL=C TZ=UTC gawk "$@"; }

# ---- 作業ディレクトリ・ロック ------------------------------------------------------
mk_private_dir() {
  local d=$1
  mkdir -p -- "$d" || die "ディレクトリを作成できません: $d"
  chmod 700 -- "$d" 2>/dev/null || true
}

init_tmp() {
  mk_private_dir "$WORK_DIR/tmp"
  TMP_DIR=$(mktemp -d "$WORK_DIR/tmp/dbtool.XXXXXX") || die "一時ディレクトリを作成できません"
}

acquire_lock() {
  local lockfile="$WORK_DIR/.dbtool.lock"
  exec {LOCK_FD}>>"$lockfile" || die "ロックファイルを開けません: $lockfile"
  if ! flock -n "$LOCK_FD"; then
    die "別の dbtool が実行中です (ロック: $lockfile)。終了を待ってから再実行してください"
  fi
}

# ---- 並列実行 -------------------------------------------------------------------
JOBS_RUNNING=0
JOBS_FAILED=0
job_start() { "$@" & JOBS_RUNNING=$((JOBS_RUNNING + 1)); }
job_wait_slot() {
  local max=$1
  while ((JOBS_RUNNING >= max)); do
    if ! wait -n; then JOBS_FAILED=$((JOBS_FAILED + 1)); fi
    JOBS_RUNNING=$((JOBS_RUNNING - 1))
  done
}
job_wait_all() {
  while ((JOBS_RUNNING > 0)); do
    if ! wait -n; then JOBS_FAILED=$((JOBS_FAILED + 1)); fi
    JOBS_RUNNING=$((JOBS_RUNNING - 1))
  done
}

# ---- ファイル -------------------------------------------------------------------
file_size() { stat -c %s -- "$1" 2>/dev/null || echo 0; }

sha256_of() { sha256sum -- "$1" | awk '{print $1}'; }

# 先頭行が CRLF で終わるか
first_line_crlf() {
  local f=$1 line
  if [[ $f == *.gz ]]; then
    line=$(set +o pipefail; gzip -dc -- "$f" 2>/dev/null | head -n 1)
  else
    line=$(head -n 1 -- "$f")
  fi
  [[ $line == *$'\r' ]]
}
