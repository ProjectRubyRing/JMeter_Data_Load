# shellcheck shell=bash
# =============================================================================
# cmd_backup.sh : dump (mysqldump によるバックアップ) / restore (ダンプからの復元)
# =============================================================================

usage_dump() {
  cat <<'EOF'
使い方: dbtool.sh dump [-d DB[,DB...] | --all-databases] [-t テーブル] [オプション]
  mysqldump でデータベースのダンプ (論理バックアップ) を取得します。
    -d, --database DB[,DB]   対象データベース (複数可)
        --all-databases      システムDB (mysql/sys/information_schema/performance_schema) 以外すべて
    -t, --tables LIST        特定テーブルのみ (データベースは1つだけ指定)
    -o, --output DIR         出力先ディレクトリ (既定: conf の BACKUP_DIR)
        --no-data            定義のみ (データを含めない)
        --no-routines        ストアドプロシージャ/関数を含めない
        --no-events          イベントを含めない
        --no-triggers        トリガーを含めない
        --strip-definer      DEFINER 句を除去する (別環境への復元用)
        --compress gzip|none 圧縮 (既定: conf の DUMP_COMPRESS, 未指定時 gzip)
  出力: <DB>_<日時>.sql.gz, 同名の .sha256 (チェックサム), .meta (取得情報)
EOF
}

cmd_dump() {
  local dbs="" all=0 tables="" outdir="" nodata=0 noroutines=0 noevents=0 notriggers=0 strip=0 compress=""
  while (($#)); do
    case $1 in
      -d|--database) dbs=${2-}; shift ;;
      --all-databases) all=1 ;;
      -t|--tables) tables=${2-}; shift ;;
      -o|--output) outdir=${2-}; shift ;;
      --no-data) nodata=1 ;;
      --no-routines) noroutines=1 ;;
      --no-events) noevents=1 ;;
      --no-triggers) notriggers=1 ;;
      --strip-definer) strip=1 ;;
      --compress) compress=${2-}; shift ;;
      -h|--help) usage_dump; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh dump --help を参照)" ;;
    esac
    shift
  done
  [[ -z $dbs ]] && ((!all)) && dbs=$(conf DEFAULT_DATABASE)
  compress=${compress:-$(conf DUMP_COMPRESS gzip)}
  [[ $compress == gzip || $compress == none ]] || die "--compress は gzip または none を指定してください"
  db_init
  require_cmd "$MYSQLDUMP_BIN" gzip sha256sum
  check_client_version "$MYSQLDUMP_BIN"
  db_connect

  local -a dblist=() targs=()
  local d out base ts
  if ((all)); then
    [[ -n $tables ]] && die "--all-databases と -t は同時に指定できません"
    while IFS= read -r d; do [[ -n $d ]] && dblist+=("$d"); done < <(db_query "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME NOT IN ('mysql','sys','information_schema','performance_schema') ORDER BY SCHEMA_NAME" --raw)
    ((${#dblist[@]} > 0)) || die "ダンプ対象のデータベースがありません"
  else
    [[ -n $dbs ]] || die "データベースを -d で指定してください (または --all-databases)"
    split_list "$dbs"
    for d in "${LIST_RESULT[@]}"; do use_database "$d"; dblist+=("$DB_NAME"); done
  fi
  if [[ -n $tables ]]; then
    ((${#dblist[@]} == 1)) || die "-t を指定する場合、データベースは1つだけ指定してください"
    DB_NAME=${dblist[0]}
    expand_tables "$tables"
    targs=("${TABLES[@]}")
  fi

  outdir=$(resolve_path "${outdir:-$(conf BACKUP_DIR backup)}")
  mk_private_dir "$outdir"
  ts=$(now_ts)
  if ((all)); then base="all-databases_$ts"
  elif ((${#dblist[@]} > 1)); then base="multi_$ts"
  elif ((${#targs[@]} > 0)); then base="${dblist[0]}_${ts}_tables"
  else base="${dblist[0]}_$ts"; fi
  base=${base//\//_}
  out="$outdir/$base.sql"; [[ $compress == gzip ]] && out+=".gz"

  local -a args=("${MYSQLDUMP_OPTS[@]}" --single-transaction --quick --hex-blob --set-gtid-purged=OFF --no-tablespaces --column-statistics=0)
  ((noroutines)) || args+=(--routines)
  ((noevents)) || args+=(--events)
  if ((notriggers)); then args+=(--skip-triggers); else args+=(--triggers); fi
  ((nodata)) && args+=(--no-data)
  if ((${#targs[@]} > 0)); then args+=("${dblist[0]}" "${targs[@]}")
  elif ((${#dblist[@]} == 1)); then args+=("${dblist[0]}")
  else args+=(--databases "${dblist[@]}"); fi

  # mysqldump は FLOAT 型を有効6桁の文字列で出力するため値が丸められる (mysqldump の仕様)
  local fl in="" d2
  for d2 in "${dblist[@]}"; do in+="${in:+,}$(sql_str "$d2")"; done
  fl=$(db_query "SELECT CONCAT(TABLE_SCHEMA,'.',TABLE_NAME,'.',COLUMN_NAME) FROM information_schema.COLUMNS c
                  WHERE TABLE_SCHEMA IN ($in) AND DATA_TYPE='float'
                    AND EXISTS (SELECT 1 FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA=c.TABLE_SCHEMA AND t.TABLE_NAME=c.TABLE_NAME AND t.TABLE_TYPE='BASE TABLE')
                  ORDER BY 1" --raw)
  if [[ -n $fl && $nodata -eq 0 ]]; then
    if ((${#targs[@]} > 0)); then
      fl=$(grep -E "^[^.]+\.($(printf '%s|' "${targs[@]}" | sed 's/[.[\*^$()+?{}]/\\&/g; s/|$//'))\." <<<"$fl" || true)
    fi
    if [[ -n $fl ]]; then
      log_warn "FLOAT 型の列があります。mysqldump は FLOAT を有効6桁に丸めて出力するため、復元後の値が元と一致しない場合があります:"
      log_block WARN "    " "$fl"
      log_warn "  厳密に復元する必要がある場合は、これらのテーブルを export (CSV) でもバックアップしてください"
    fi
  fi
  log_info "ダンプ開始: ${dblist[*]}${targs[*]:+ (テーブル: ${targs[*]})} → $out"
  local t0=$SECONDS errf st lastf msgs
  errf=$(mktemp "$TMP_DIR/err.XXXXXX"); lastf=$(mktemp "$TMP_DIR/last.XXXXXX")
  if _dump_pipeline "$errf" "$strip" "$compress" "$out.part" "$lastf" "${args[@]}"; then :; fi
  st=("${PIPE_ST[@]}")
  if ((st[0] != 0)); then rm -f -- "$out.part"; die "mysqldump が失敗しました: $(mysql_errmsg "$errf")"; fi
  if ((st[1] != 0 || st[2] != 0 || st[3] != 0)); then rm -f -- "$out.part"; die "ダンプファイルの書込みに失敗しました (ディスク容量を確認してください)"; fi
  msgs=$(grep -v '^mysqldump: \[Warning\]' "$errf" || true)
  [[ -n $msgs ]] && log_block WARN "mysqldump: " "$msgs"
  # 完了マーカーの確認 (途中で切れていないか)
  grep -q 'Dump completed' "$lastf" || { mv -f -- "$out.part" "$out.incomplete"; die "ダンプが最後まで出力されていません: $out.incomplete"; }
  mv -f -- "$out.part" "$out"
  (cd -- "$outdir" && sha256sum -- "$(basename -- "$out")" >"$(basename -- "$out").sha256")
  {
    printf 'created_at\t%s\n' "$(now_disp)"
    printf 'server\t%s\n' "$SERVER_INFO"
    printf 'databases\t%s\n' "${dblist[*]}"
    printf 'mode\t%s\n' "$( ((${#dblist[@]} > 1 || all)) && echo databases || echo single)"
    printf 'tables\t%s\n' "${targs[*]}"
    printf 'options\tno_data=%d routines=%d events=%d triggers=%d strip_definer=%d\n' "$nodata" $((!noroutines)) $((!noevents)) $((!notriggers)) "$strip"
  } >"$out.meta"
  log_info "ダンプ完了: $out ($(human_size "$(file_size "$out")"), $(fmt_duration $((SECONDS - t0))))"
  log_info "  チェックサム: $out.sha256"
  log_info "  ※ ユーザー/権限 (mysql スキーマ) はダンプに含まれません"
}

_dump_pipeline() {
  local errf=$1 strip=$2 compress=$3 part=$4 lastf=$5; shift 5
  local fifo="$TMP_DIR/dumptail.$$" tpid wfd
  # 最終行 (完了マーカー) を FIFO 経由で取得する
  mkfifo -m 600 "$fifo"
  tail -n 1 <"$fifo" >"$lastf" &
  tpid=$!
  exec {wfd}>"$fifo"
  "$MYSQLDUMP_BIN" "$@" 2>"$errf" |
    if ((strip)); then sed -E '/^INSERT INTO /!s/DEFINER=`([^`]|``)*`@`([^`]|``)*`//g'; else cat; fi |
    tee "$fifo" |
    if [[ $compress == gzip ]]; then gzip -c; else cat; fi >"$part"
  PIPE_ST=("${PIPESTATUS[@]}")
  exec {wfd}>&-
  wait "$tpid" 2>/dev/null || true
  rm -f -- "$fifo"
}

usage_restore() {
  cat <<'EOF'
使い方: dbtool.sh restore -f ダンプファイル [-d DB] [オプション]
  dump で取得したダンプファイル (.sql / .sql.gz) を復元します。
    -f, --file FILE      ダンプファイル
    -d, --database DB    復元先データベース (単一DBのダンプのみ。省略時は取得元と同じ名前)
        --create-db      復元先データベースがなければ作成する
        --strip-definer  DEFINER 句を除去して復元する
        --skip-verify    チェックサム (.sha256) の検証を省略
    -y, --yes            確認を省略
  ※ 複数DB (--all-databases 等) のダンプは取得元と同じ名前のデータベースに復元されます。
EOF
}

cmd_restore() {
  local file="" db="" create=0 strip=0 verify=1
  while (($#)); do
    case $1 in
      -f|--file) file=${2-}; shift ;;
      -d|--database) db=${2-}; shift ;;
      --create-db) create=1 ;;
      --strip-definer) strip=1 ;;
      --skip-verify) verify=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_restore; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh restore --help を参照)" ;;
    esac
    shift
  done
  [[ -n $file ]] || die "ダンプファイルを -f で指定してください"
  [[ -f $file ]] || die "ファイルがありません: $file"
  local mode="single" srcdbs=""
  if [[ -f $file.meta ]]; then
    mode=$(awk -F'\t' '$1 == "mode" { print $2 }' "$file.meta")
    srcdbs=$(awk -F'\t' '$1 == "databases" { print $2 }' "$file.meta")
  else
    if (set +o pipefail; { if [[ $file == *.gz ]]; then gzip -dc -- "$file"; else cat -- "$file"; fi; } 2>/dev/null | head -n 200 | grep -q '^USE `'); then mode=databases; fi
  fi
  if ((verify)) && [[ -f $file.sha256 ]]; then
    log_info "チェックサムを検証しています: $file.sha256"
    (cd -- "$(dirname -- "$file")" && sha256sum -c --quiet -- "$(basename -- "$file").sha256") || die "チェックサムが一致しません (ファイルが破損しています): $file"
  fi
  if ((verify)); then
    if [[ $file == *.gz ]]; then gzip -t -- "$file" || die "gzip ファイルが破損しています: $file"; fi
    # 末尾の完了マーカー (-- Dump completed) で途中切れを検出
    local last
    if [[ $file == *.gz ]]; then last=$(gzip -dc -- "$file" | tail -n 1); else last=$(tail -n 1 -- "$file"); fi
    [[ $last == *"Dump completed"* ]] || die "ダンプファイルが最後まで出力されていません (途中で切れている可能性があります): $file  ※確認を省略する場合は --skip-verify"
  fi
  db_init
  db_connect
  local target=""
  if [[ $mode == databases ]]; then
    [[ -n $db ]] && log_warn "複数データベースのダンプのため -d は無視します (取得元と同じ名前に復元: $srcdbs)"
    target="(ダンプ内のデータベース: ${srcdbs:-ファイル内の USE 文に従う})"
  else
    db=${db:-${srcdbs:-$(conf DEFAULT_DATABASE)}}
    [[ -n $db ]] || die "復元先データベースを -d で指定してください"
    if ((create)); then
      ((DRY_RUN)) || db_query "CREATE DATABASE IF NOT EXISTS $(sql_ident "$db")" >/dev/null
    fi
    use_database "$db"
    check_allowed_db
    target="$DB_NAME"
  fi
  confirm "ダンプファイル $file を $SERVER_INFO のデータベース $target に復元します。既存の同名テーブルは置き換えられます。"
  if ((DRY_RUN)); then log_info "[dry-run] 復元は実行しません"; return 0; fi
  local t0=$SECONDS errf st
  errf=$(mktemp "$TMP_DIR/err.XXXXXX")
  local -a args=("${MYSQL_OPTS[@]}" --batch)
  [[ $mode != databases ]] && args+=("--database=$DB_NAME")
  log_info "復元を開始します: $file"
  if _restore_pipeline "$file" "$strip" "$errf" "${args[@]}"; then :; fi
  st=("${PIPE_ST[@]}")
  if ((st[0] != 0)); then die "ダンプファイルの読込みに失敗しました: $file"; fi
  if ((st[2] != 0)); then
    log_error "復元に失敗しました: $(mysql_errmsg "$errf")"
    if grep -q 'ERROR 1419' "$errf"; then
      log_error "  → トリガー/関数の作成には DB パラメータ log_bin_trust_function_creators=1 が必要です (Aurora: DB クラスターパラメータグループ)"
    fi
    if grep -Eq 'ERROR (1227|1449)' "$errf"; then
      log_error "  → DEFINER のユーザーが存在しない/権限不足の可能性があります。--strip-definer を付けて再実行してください"
    fi
    die "復元を中止しました (途中まで反映されています)"
  fi
  log_info "復元完了: $(fmt_duration $((SECONDS - t0)))"
}

_restore_pipeline() {
  local file=$1 strip=$2 errf=$3; shift 3
  if [[ $file == *.gz ]]; then gzip -dc -- "$file"; else cat -- "$file"; fi |
    if ((strip)); then sed -E '/^INSERT INTO /!s/DEFINER=`([^`]|``)*`@`([^`]|``)*`//g'; else cat; fi |
    "$MYSQL_BIN" "$@" 2>"$errf"
  PIPE_ST=("${PIPESTATUS[@]}")
}
