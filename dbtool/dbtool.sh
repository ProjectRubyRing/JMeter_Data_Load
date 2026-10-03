#!/usr/bin/env bash
# =============================================================================
# dbtool.sh - Aurora MySQL (8.4 互換) バックアップ / テストデータ投入ユーティリティ
#   対象: RHEL 9.x (bash 5.1, gawk 5.1) + MySQL クライアント 8.0 以上
#   使い方: dbtool.sh <コマンド> [オプション]   (dbtool.sh help で一覧)
# =============================================================================
set -Eeuo pipefail
umask 077

readonly DBTOOL_VERSION="1.0.0"
DBTOOL_HOME=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
readonly DBTOOL_HOME
LIB="$DBTOOL_HOME/lib"

# shellcheck source=lib/common.sh
source "$LIB/common.sh"
# shellcheck source=lib/db.sh
source "$LIB/db.sh"
# shellcheck source=lib/dataio.sh
source "$LIB/dataio.sh"
# shellcheck source=lib/cmd_backup.sh
source "$LIB/cmd_backup.sh"
# shellcheck source=lib/cmd_table.sh
source "$LIB/cmd_table.sh"
# shellcheck source=lib/cmd_datagen.sh
source "$LIB/cmd_datagen.sh"

usage() {
  cat <<EOF
dbtool.sh ${DBTOOL_VERSION} - Aurora MySQL バックアップ / テストデータ投入ユーティリティ

使い方: dbtool.sh [共通オプション] <コマンド> [オプション]

バックアップ
  dump        mysqldump でデータベースをダンプ (.sql.gz)
  restore     ダンプファイルから復元
テーブルデータ
  export      テーブルの全データを CSV にバックアップ
  import      export した CSV からテーブルを復元
  load        CSV ファイルをテーブルに一括ロード
  truncate    テーブルの全データを削除 (TRUNCATE)
  delete      条件を指定して削除 (分割コミット)
  count       件数を表示
テストデータ (JMeter 性能テスト用)
  schema      テーブル定義を取得し、設定用 Excel (.xlsm) を出力
  validate    Excel から出力した設定ファイルを検証
  generate    設定ファイルに従いテストデータ CSV を生成 (DB は変更しない)
  prepare     バックアップ → 事前処理 → 生成 → ロード を一括実行
  cleanup     prepare の後片付け (復元/生成データ削除 など)
  runs        prepare の実行履歴を表示/削除
その他
  ping        接続確認
  help        このヘルプ

共通オプション
  --defaults-file FILE   MySQL 接続設定ファイル (既定: conf/dbtool.conf の MYSQL_DEFAULTS_FILE)
  --login-path NAME      mysql_config_editor のログインパス
  --conf FILE            ツール設定ファイル (既定: conf/dbtool.conf)
  --dry-run              DB を変更する SQL を表示するだけで実行しない
  -y, --yes              確認を省略 (非対話実行)
  -v, --verbose          詳細ログ
  -q, --quiet            情報ログを抑制

各コマンドの詳細: dbtool.sh <コマンド> --help
EOF
}

# 値を取るオプション (共通オプションの抜き出し時に値を読み飛ばすため)
VALUE_OPTS=" -d --database -t --tables --table -c --config -f --file -o --output -i --input --where --batch-rows --run --run-id --format --encoding --chunk-rows -P --parallel --on-warning --fk-checks --time-zone --compress --rows --delete "

main() {
  local -a rest=()
  local cmd="" a
  OPT_DEFAULTS_FILE=""; OPT_LOGIN_PATH=""; OPT_CONF=""
  while (($#)); do
    a=$1
    case $a in
      --defaults-file) OPT_DEFAULTS_FILE=${2-}; shift ;;
      --defaults-file=*) OPT_DEFAULTS_FILE=${a#*=} ;;
      --login-path) OPT_LOGIN_PATH=${2-}; shift ;;
      --login-path=*) OPT_LOGIN_PATH=${a#*=} ;;
      --conf) OPT_CONF=${2-}; shift ;;
      --dry-run) DRY_RUN=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -v|--verbose) VERBOSE=$((VERBOSE + 1)) ;;
      -vv) VERBOSE=2 ;;
      -q|--quiet) QUIET=1 ;;
      *)
        if [[ -z $cmd && $a != -* ]]; then cmd=$a
        else
          rest+=("$a")
          if [[ $VALUE_OPTS == *" $a "* && $# -ge 2 ]]; then rest+=("$2"); shift; fi
        fi
        ;;
    esac
    shift
  done
  cmd=${cmd:-help}
  case $cmd in
    help|-h|--help) usage; return 0 ;;
    version|--version) printf 'dbtool.sh %s\n' "$DBTOOL_VERSION"; return 0 ;;
  esac
  [[ ${BASH_VERSINFO[0]} -ge 5 || (${BASH_VERSINFO[0]} -eq 4 && ${BASH_VERSINFO[1]} -ge 4) ]] || die "bash 4.4 以上が必要です"
  require_cmd gawk sha256sum flock mktemp stat
  load_tool_conf "${OPT_CONF:-$DBTOOL_HOME/conf/dbtool.conf}"
  WORK_DIR=$(resolve_path "$(conf WORK_DIR work)")
  local logdir
  logdir=$(resolve_path "$(conf LOG_DIR log)")
  mk_private_dir "$WORK_DIR"
  mk_private_dir "$logdir"
  LOG_FILE="$logdir/dbtool_$(printf '%(%Y%m%d)T' -1).log"
  setup_traps
  init_tmp
  _log CMD "dbtool.sh $cmd $(sanitize_args "${rest[@]}")$( ((DRY_RUN)) && echo ' [dry-run]')" 2>/dev/null
  case $cmd in
    dump)     cmd_dump "${rest[@]}" ;;
    restore)  cmd_restore "${rest[@]}" ;;
    export)   cmd_export "${rest[@]}" ;;
    import)   cmd_import "${rest[@]}" ;;
    load)     cmd_load "${rest[@]}" ;;
    truncate) cmd_truncate "${rest[@]}" ;;
    delete)   cmd_delete "${rest[@]}" ;;
    count)    cmd_count "${rest[@]}" ;;
    schema)   cmd_schema "${rest[@]}" ;;
    validate) cmd_validate "${rest[@]}" ;;
    generate) cmd_generate "${rest[@]}" ;;
    prepare)  cmd_prepare "${rest[@]}" ;;
    cleanup)  cmd_cleanup "${rest[@]}" ;;
    runs)     cmd_runs "${rest[@]}" ;;
    ping)     cmd_ping "${rest[@]}" ;;
    *) usage >&2; die "不明なコマンドです: $cmd" ;;
  esac
}

# ログに残すコマンドライン (空白を含む引数は引用符で囲む)
sanitize_args() {
  local a out=""
  for a in "$@"; do
    if [[ $a =~ [[:space:]] || -z $a ]]; then out+=" '${a//\'/\'\\\'\'}'"; else out+=" $a"; fi
  done
  printf '%s' "${out# }"
}

main "$@"
