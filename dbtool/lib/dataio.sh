# shellcheck shell=bash
# =============================================================================
# dataio.sh : テーブルデータの CSV 出力 / CSV ロード / 削除
#   CSV (正規形式) : UTF-8, 1行目はヘッダー, 区切り "," , 文字列は "..." ("" で " ),
#                    \ \n \r \t はバックスラッシュでエスケープ, NULL は引用符なしの NULL,
#                    バイナリ/空間型は16進, BIT は10進, TIMESTAMP は UTC (+00:00)
# =============================================================================

tsv_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//$'\t'/\\t}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}
  printf '%s' "$s"
}

tsv_unescape() {
  local s=$1
  [[ $s == *\\* ]] || { printf '%s' "$s"; return 0; }
  s=${s//\\\\/$'\x01'}; s=${s//\\t/$'\t'}; s=${s//\\n/$'\n'}; s=${s//\\r/$'\r'}; s=${s//$'\x01'/\\}
  printf '%s' "$s"
}

# "KEY<TAB>値" 形式の出力から値を取り出す
spec_get() {
  local line
  while IFS= read -r line; do
    if [[ $line == "$2"$'\t'* ]]; then tsv_unescape "${line#*$'\t'}"; return 0; fi
  done <<<"$1"
  return 0
}

schema_tmp() { # schema_tmp table... → 一時ファイルのパス
  local f
  f=$(mktemp "$TMP_DIR/schema.XXXXXX")
  fetch_schema "$@" >"$f"
  printf '%s' "$f"
}

# ---- エクスポート ---------------------------------------------------------------
# export_table TABLE OUTFILE [gzip 0/1]  → EXPORT_ROWS / EXPORT_AUTOINC / EXPORT_COLUMNS
export_table() {
  local t=$1 out=$2 gz=${3:-0}
  local sf spec hdr sel ord statf errf part st rows warns t0
  t0=$SECONDS
  sf=$(schema_tmp "$t")
  spec=$(DBT_TABLE="$t" awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/colspec.awk" -v MODE=export "$sf") ||
    { log_block ERROR "  " "$(grep '^ERROR' <<<"$spec" | cut -f2-)"; die "エクスポートの準備に失敗しました: $t"; }
  hdr=$(spec_get "$spec" HEADER); sel=$(spec_get "$spec" SELECT); ord=$(spec_get "$spec" ORDER)
  EXPORT_AUTOINC=$(spec_get "$spec" AUTOINC); EXPORT_COLUMNS=$(spec_get "$spec" NCOLS)
  statf=$(mktemp "$TMP_DIR/status.XXXXXX"); errf=$(mktemp "$TMP_DIR/err.XXXXXX")
  part="$out.part"
  log_info "エクスポート開始: $t → $out"
  if _export_pipeline "$t" "$sel" "$ord" "$hdr" "$statf" "$errf" "$gz" "$part"; then :; fi
  st=("${PIPE_ST[@]}")
  if ((st[1] != 0)); then
    rm -f -- "$part"
    die "エクスポートに失敗しました ($t): $(mysql_errmsg "$errf")"
  fi
  if ((st[2] == 3)); then rm -f -- "$part"; die "エクスポートの出力が途中で終了しました ($t)。接続が切れた可能性があります"; fi
  rows=$(awk -F'\t' '$1 == "ROWS" { print $2 }' "$statf")
  warns=$(awk -F'\t' '$1 == "WARNINGS" { print $2 }' "$statf")
  if ((st[2] == 4)) || [[ ${warns:-0} != 0 ]]; then
    log_block ERROR "  " "$(awk -F'\t' '$1 == "MSG" { sub(/^MSG\t/, ""); print }' "$statf")"
    mv -f -- "$part" "$out.failed"
    die "エクスポート中に警告が $warns 件発生したため中止しました ($t)。値が max_allowed_packet を超えている可能性があります (出力: $out.failed)"
  fi
  if ((st[2] != 0 || st[3] != 0)); then rm -f -- "$part"; die "エクスポートの書込みに失敗しました ($t)。ディスク容量を確認してください"; fi
  mv -f -- "$part" "$out"
  EXPORT_ROWS=$rows
  log_info "エクスポート完了: $t $(fmt_num "$rows") 件 ($(human_size "$(file_size "$out")"), $(fmt_duration $((SECONDS - t0))))"
}

_export_pipeline() {
  local t=$1 sel=$2 ord=$3 hdr=$4 statf=$5 errf=$6 gz=$7 part=$8
  {
    sql_preamble restore '+00:00'
    printf 'SET SESSION net_write_timeout=3600;\n'
    printf "SELECT CONCAT_WS(',',\n  %s)\nFROM %s%s;\n" "$sel" "$(qtable "$t")" "${ord:+ ORDER BY $ord}"
    printf 'SHOW COUNT(*) WARNINGS;\nSHOW WARNINGS LIMIT 10;\n'
  } | "$MYSQL_BIN" "${MYSQL_OPTS[@]}" --batch --skip-column-names --quick 2>"$errf" |
    DBT_HEADER="$hdr" DBT_STATUS="$statf" awkc -f "$LIB/export_filter.awk" |
    if ((gz)); then gzip -c; else cat; fi >"$part"
  PIPE_ST=("${PIPESTATUS[@]}")
}

# ---- ロード -------------------------------------------------------------------
# load_csv_file オプションは環境変数風のローカル変数で渡す:
#   L_TABLE L_FILE L_COLLIST L_SETLIST L_EXPECTED(-1=不明) L_HEADER(0/1) L_DIALECT(mysql/rfc4180)
#   L_CRLF(0/1) L_CHARSET L_MODE(strict/restore) L_TZ L_FK(0/1) L_ONWARN(ROLLBACK/CONTINUE) L_LABEL
# 結果: LOADED_ROWS / LOAD_WARNINGS。失敗時は 1 を返す (ロールバック済み)
load_csv_file() {
  local attempt sql out errf src fifo gzpid cond esc eol ign rc res rows nwarn msgs
  local maxtry=3
  esc="X'5C'"; [[ $L_DIALECT == rfc4180 ]] && esc="''"
  eol="X'0A'"; ((L_CRLF)) && eol="X'0D0A'"
  ign=$(( L_HEADER ? 1 : 0 ))
  if [[ $L_ONWARN == CONTINUE ]]; then cond="1=1"
  elif ((L_EXPECTED >= 0)); then cond="@dbt_cond = 0 AND @dbt_rows = $L_EXPECTED"
  else cond="@dbt_cond = 0"; fi
  LOADED_ROWS=0; LOAD_WARNINGS=0
  for ((attempt = 1; attempt <= maxtry; attempt++)); do
    errf=$(mktemp "$TMP_DIR/err.XXXXXX")
    src=$L_FILE; fifo=""; gzpid=""
    if [[ $L_FILE == *.gz ]]; then
      fifo="$TMP_DIR/fifo.$BASHPID.$RANDOM"
      mkfifo -m 600 "$fifo"
      gzip -dc -- "$L_FILE" >"$fifo" 2>>"$errf" &
      gzpid=$!
      src=$fifo
    fi
    # sql_notes=0 : Note (例: 生成列の DECIMAL 丸め) は判定に含めない。
    #   LOCAL 指定時のデータ不正 (範囲外・日付不正・重複・桁あふれ等) は Warning として数える。
    sql="$(sql_preamble "$L_MODE" "$L_TZ" "$L_FK")
SET SESSION sql_notes=0;
SET SESSION transaction_isolation='READ-COMMITTED';
SET autocommit=0;
LOAD DATA LOCAL INFILE $(sql_str "$src") INTO TABLE $(qtable "$L_TABLE") CHARACTER SET $L_CHARSET
  FIELDS TERMINATED BY X'2C' OPTIONALLY ENCLOSED BY X'22' ESCAPED BY $esc
  LINES TERMINATED BY $eol
  IGNORE $ign LINES
  ($L_COLLIST)${L_SETLIST:+
  SET $L_SETLIST};
GET DIAGNOSTICS @dbt_rows = ROW_COUNT, @dbt_cond = NUMBER;
SHOW WARNINGS LIMIT 20;
SELECT '#DBT_RESULT', @dbt_rows, @dbt_cond, @@warning_count;
SET SESSION sql_mode = IF($cond, @@SESSION.sql_mode, CONCAT('DBTOOL_LOAD_REJECTED_rows_', @dbt_rows, '_warnings_', @dbt_cond));
COMMIT;"
    if ((DRY_RUN)); then
      printf '%s\n' "-- [dry-run] $L_LABEL" "$sql"
      [[ -n $gzpid ]] && { kill "$gzpid" 2>/dev/null || true; wait "$gzpid" 2>/dev/null || true; rm -f -- "$fifo"; }
      rm -f -- "$errf"; LOADED_ROWS=$L_EXPECTED; return 0
    fi
    if out=$(printf '%s\n' "$sql" | "$MYSQL_BIN" "${MYSQL_OPTS[@]}" --local-infile=1 --batch --skip-column-names 2>>"$errf"); then rc=0; else rc=$?; fi
    if [[ -n $gzpid ]]; then
      if kill -0 "$gzpid" 2>/dev/null; then kill "$gzpid" 2>/dev/null || true; fi
      wait "$gzpid" 2>/dev/null || true
      rm -f -- "$fifo"
    fi
    res=$(grep '^#DBT_RESULT' <<<"$out" || true)
    msgs=$(grep -E '^(Warning|Note|Error)'$'\t' <<<"$out" || true)
    if [[ -n $res ]]; then
      IFS=$'\t' read -r _ rows _ nwarn <<<"$res"
      LOADED_ROWS=$rows; LOAD_WARNINGS=$nwarn
    fi
    if ((rc == 0)); then
      if ((LOAD_WARNINGS > 0)); then
        log_warn "$L_LABEL: 警告 $LOAD_WARNINGS 件 (on_warning=CONTINUE のためコミットしました)"
        log_block WARN "    " "$msgs"
      fi
      rm -f -- "$errf"
      return 0
    fi
    if grep -q 'DBTOOL_LOAD_REJECTED' "$errf"; then
      log_error "$L_LABEL: ロード結果が不正なためロールバックしました (取込 $(fmt_num "${rows:-0}") 件 / 期待 $( ((L_EXPECTED >= 0)) && fmt_num "$L_EXPECTED" || printf '不明') 件, 警告 ${nwarn:-0} 件)"
      [[ -n $msgs ]] && log_block ERROR "    " "$(head -n 10 <<<"$msgs")$( (( $(wc -l <<<"$msgs") > 10 )) && printf '\n... (先頭10件のみ表示)')"
      rm -f -- "$errf"
      return 1
    fi
    if grep -Eq 'ERROR (1213|1205)' "$errf" && ((attempt < maxtry)); then
      log_warn "$L_LABEL: デッドロック/ロック待ちタイムアウトのため再試行します ($attempt/$maxtry): $(mysql_errmsg "$errf")"
      rm -f -- "$errf"; sleep $((attempt * 3)); continue
    fi
    log_error "$L_LABEL: ロードに失敗しました (ロールバック済み): $(mysql_errmsg "$errf")"
    rm -f -- "$errf"
    return 1
  done
  return 1
}

# ---- 削除 ---------------------------------------------------------------------
# delete_rows TABLE WHERE(空=全件) BATCH FK(0/1) → DELETED_ROWS
delete_rows() {
  local t=$1 where=$2 batch=$3 fk=$4 per=20 sql out n total=0 done=0 i
  while ((!done)); do
    sql="SET SESSION foreign_key_checks=$fk;"
    for ((i = 0; i < per; i++)); do
      sql+=$'\n'"DELETE FROM $(qtable "$t")${where:+ WHERE ($where)} LIMIT $batch;"$'\n'"SELECT ROW_COUNT();"
    done
    if ((DRY_RUN)); then printf '%s\n' "-- [dry-run] $t" "DELETE FROM $(qtable "$t")${where:+ WHERE ($where)} LIMIT $batch; (繰返し)"; DELETED_ROWS=0; return 0; fi
    out=$(db_query "$sql" --raw)
    while IFS= read -r n; do
      [[ -z $n ]] && continue
      total=$((total + n))
      ((n < batch)) && done=1
    done <<<"$out"
    ((done)) || log_info "  $t: $(fmt_num "$total") 件削除 (継続中)"
  done
  DELETED_ROWS=$total
}

# delete_range TABLE COLUMN START LAST STEP BATCH FK → DELETED_ROWS (連番の範囲を区間ごとに削除)
delete_range() {
  local t=$1 col=$2 start=$3 last=$4 step=$5 batch=$6 fk=$7
  local lo hi span a b sql out n total=0 i per=20 qcol extra
  qcol=$(sql_ident "$col")
  if ((start <= last)); then lo=$start; hi=$last; else lo=$last; hi=$start; fi
  span=$(( batch * (step < 0 ? -step : step) ))
  extra=""
  if ((step != 1 && step != -1)); then extra=" AND MOD($qcol - ($start), ${step#-}) = 0"; fi
  a=$lo
  while ((a <= hi)); do
    sql="SET SESSION foreign_key_checks=$fk;"
    for ((i = 0; i < per && a <= hi; i++)); do
      b=$((a + span - 1)); ((b > hi)) && b=$hi
      sql+=$'\n'"DELETE FROM $(qtable "$t") WHERE $qcol BETWEEN $a AND $b$extra;"$'\n'"SELECT ROW_COUNT();"
      a=$((b + 1))
    done
    if ((DRY_RUN)); then printf '%s\n' "-- [dry-run] $t" "DELETE FROM $(qtable "$t") WHERE $qcol BETWEEN $lo AND $hi$extra; (区間ごと)"; DELETED_ROWS=0; return 0; fi
    out=$(db_query "$sql" --raw)
    while IFS= read -r n; do [[ -n $n ]] && total=$((total + n)); done <<<"$out"
    ((a > hi)) || log_info "  $t: $(fmt_num "$total") 件削除 ($col ≦ $((a - 1)), 継続中)"
  done
  DELETED_ROWS=$total
}

truncate_table() { # truncate_table TABLE
  if ((DRY_RUN)); then printf '%s\n' "-- [dry-run]" "SET SESSION foreign_key_checks=0; TRUNCATE TABLE $(qtable "$1");"; return 0; fi
  db_query "SET SESSION foreign_key_checks=0;
TRUNCATE TABLE $(qtable "$1");" >/dev/null
}

# AUTO_INCREMENT を指定値以上に戻す
restore_auto_increment() { # TABLE VALUE
  local t=$1 v=$2 cur
  [[ -z $v || $v == NULL ]] && return 0
  cur=$(get_auto_increment "$t")
  [[ -z $cur ]] && return 0
  if ((v > cur)); then
    if ((DRY_RUN)); then printf '%s\n' "-- [dry-run] ALTER TABLE $(qtable "$t") AUTO_INCREMENT = $v;"; return 0; fi
    db_query "ALTER TABLE $(qtable "$t") AUTO_INCREMENT = $v;" >/dev/null
    log_info "  $t: AUTO_INCREMENT を $v に戻しました"
  fi
}

# エクスポートした CSV からテーブルを復元 (TRUNCATE → LOAD → 件数確認 → AUTO_INCREMENT)
#   TRUNCATE=0 のときは既存データに追加し、件数は「追加前 + ROWS」で確認する
restore_table_from_csv() { # TABLE FILE ROWS AUTOINC [TRUNCATE=1]
  local t=$1 f=$2 rows=$3 ai=$4 trunc=${5:-1} sf hdrf spec cnt base=0
  [[ -f $f ]] || die "バックアップファイルがありません: $f"
  if ((trunc)); then truncate_table "$t"; elif ((!DRY_RUN)); then base=$(count_rows "$t"); fi
  if ((rows > 0)); then
    sf=$(schema_tmp "$t")
    hdrf=$(mktemp "$TMP_DIR/hdr.XXXXXX")
    csv_header "$f" mysql 0 >"$hdrf"
    spec=$(DBT_TABLE="$t" awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/colspec.awk" -v MODE=load "$sf" "$hdrf") ||
      { log_block ERROR "  " "$(grep '^ERROR' <<<"$spec" | cut -f2-)"; die "バックアップの列がテーブル定義と一致しません: $t"; }
    log_block WARN "  " "$(grep '^WARN' <<<"$spec" | cut -f2-)"
    L_TABLE=$t L_FILE=$f L_COLLIST=$(spec_get "$spec" COLLIST) L_SETLIST=$(spec_get "$spec" SETLIST) L_EXPECTED=$rows \
      L_HEADER=1 L_DIALECT=mysql L_CRLF=0 L_CHARSET=utf8mb4 L_MODE=restore L_TZ='+00:00' L_FK=0 L_ONWARN=ROLLBACK \
      L_LABEL="$t (復元)" load_csv_file || die "テーブルの復元に失敗しました: $t"
  fi
  if ((!DRY_RUN)); then
    cnt=$(count_rows "$t")
    ((cnt == base + rows)) || die "復元後の件数が一致しません: $t (期待 $((base + rows)) 件 / 実際 $cnt 件)"
  fi
  restore_auto_increment "$t" "$ai"
  log_info "  $t: $(fmt_num "$rows") 件を$( ((trunc)) && echo 復元 || echo 追加)しました"
}

# CSV ヘッダーの列名 (tsv_escape 済み, 1行1列) を出力
csv_header() { # FILE DIALECT CRLF
  local f=$1 dialect=$2 crlf=$3
  if [[ $f == *.gz ]]; then
    (set +o pipefail; gzip -dc -- "$f" 2>/dev/null | awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=header -v DIALECT="$dialect" -v CRLF="$crlf" -v HAS_HEADER=1)
  else
    awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=header -v DIALECT="$dialect" -v CRLF="$crlf" -v HAS_HEADER=1 "$f"
  fi
}
