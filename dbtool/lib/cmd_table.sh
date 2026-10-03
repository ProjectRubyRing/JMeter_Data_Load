# shellcheck shell=bash
# =============================================================================
# cmd_table.sh : export / import / load / truncate / delete / count / ping
# =============================================================================

# ---- export -------------------------------------------------------------------
usage_export() {
  cat <<'EOF'
使い方: dbtool.sh export -d DB -t テーブル[,テーブル...] [オプション]
  テーブルの全データを CSV にバックアップします (import で完全に復元できる形式)。
    -t, --tables LIST    対象テーブル (カンマ区切り, * でワイルドカード)
    -o, --output DIR     出力先ディレクトリ (既定: BACKUP_DIR/export_<DB>_<日時>)
        --gzip           gzip 圧縮して出力
  出力: <テーブル>.csv と manifest.tsv (件数・AUTO_INCREMENT・チェックサム)
EOF
}

cmd_export() {
  local db="" tables="" outdir="" gz=0
  while (($#)); do
    case $1 in
      -d|--database) db=${2-}; shift ;;
      -t|--tables) tables=${2-}; shift ;;
      -o|--output) outdir=${2-}; shift ;;
      --gzip) gz=1 ;;
      -h|--help) usage_export; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh export --help を参照)" ;;
    esac
    shift
  done
  db_init; db_connect
  use_database "${db:-$(conf DEFAULT_DATABASE)}"
  expand_tables "$tables"
  outdir=${outdir:-$(conf BACKUP_DIR backup)/export_${DB_NAME}_$(now_ts)}
  outdir=$(resolve_path "$outdir")
  mk_private_dir "$outdir"
  [[ -e $outdir/manifest.tsv ]] && die "出力先に既に manifest.tsv があります: $outdir"
  export_tables_to_dir "$outdir" "$gz" "${TABLES[@]}"
  log_info "エクスポート完了: $outdir (${#TABLES[@]} テーブル)"
}

# export_tables_to_dir DIR GZ TABLE...  (manifest.tsv を作成)
export_tables_to_dir() {
  local dir=$1 gz=$2; shift 2
  local t f man="$dir/manifest.tsv"
  {
    printf '#DBTOOL-EXPORT\t1\n'
    printf 'database\t%s\n' "$(tsv_escape "$DB_NAME")"
    printf 'exported_at\t%s\n' "$(now_disp)"
    printf 'server\t%s\n' "$(tsv_escape "$SERVER_INFO")"
  } >"$man.part"
  for t in "$@"; do
    f="$(safe_name "$t").csv"; ((gz)) && f+=".gz"
    export_table "$t" "$dir/$f" "$gz"
    printf 'TABLE\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(tsv_escape "$t")" "$(tsv_escape "$f")" "$EXPORT_ROWS" "$EXPORT_AUTOINC" "$(sha256_of "$dir/$f")" "$EXPORT_COLUMNS" >>"$man.part"
  done
  mv -f -- "$man.part" "$man"
}

# テーブル名をファイル名として安全な文字列に
safe_name() { local s=$1; s=${s//\//_}; s=${s//$'\n'/_}; [[ $s == .* ]] && s="_$s"; printf '%s' "$s"; }

# ---- import -------------------------------------------------------------------
usage_import() {
  cat <<'EOF'
使い方: dbtool.sh import -i エクスポートディレクトリ [オプション]
  export で取得した CSV からテーブルを復元します (TRUNCATE → ロード → 件数確認 → AUTO_INCREMENT 復元)。
    -i, --input DIR      export の出力ディレクトリ (manifest.tsv があるディレクトリ)
    -d, --database DB    復元先データベース (省略時は取得元と同じ)
    -t, --tables LIST    一部のテーブルだけ復元
        --append         TRUNCATE せずに追加でロードする
        --skip-verify    チェックサムの検証を省略
    -y, --yes            確認を省略
EOF
}

cmd_import() {
  local db="" tables="" append=0 verify=1 dir=""
  while (($#)); do
    case $1 in
      -i|--input) dir=${2-}; shift ;;
      -d|--database) db=${2-}; shift ;;
      -t|--tables) tables=${2-}; shift ;;
      --append) append=1 ;;
      --skip-verify) verify=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_import; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh import --help を参照)" ;;
    esac
    shift
  done
  [[ -n $dir ]] || die "エクスポートディレクトリを -i で指定してください"
  local man="$dir/manifest.tsv"
  [[ -f $man ]] || die "manifest.tsv がありません: $man"
  [[ $(head -n 1 -- "$man") == $'#DBTOOL-EXPORT\t1' ]] || die "manifest.tsv の形式が不正です: $man"
  local srcdb
  srcdb=$(tsv_unescape "$(awk -F'\t' '$1 == "database" { print $2 }' "$man")")
  db_init; db_connect; require_local_infile
  use_database "${db:-$srcdb}"
  check_allowed_db
  local -a names=() files=() rows=() ais=() sums=()
  local -A want=()
  local _k t f r a s _c i
  if [[ -n $tables ]]; then split_list "$tables"; for t in "${LIST_RESULT[@]}"; do want[$t]=1; done; fi
  while IFS=$'\x1f' read -r _k t f r a s _c; do
    [[ $_k == TABLE ]] || continue
    t=$(tsv_unescape "$t"); f=$(tsv_unescape "$f")
    if [[ -n $tables && -z ${want[$t]-} ]]; then continue; fi
    names+=("$t"); files+=("$dir/$f"); rows+=("$r"); ais+=("$a"); sums+=("$s")
    unset 'want[$t]'
  done < <(tr '\t' '\037' <"$man")
  ((${#want[@]} == 0)) || die "manifest.tsv にないテーブルが指定されました: ${!want[*]}"
  ((${#names[@]} > 0)) || die "復元対象のテーブルがありません"
  for ((i = 0; i < ${#names[@]}; i++)); do
    [[ -f ${files[i]} ]] || die "CSV ファイルがありません: ${files[i]}"
    if ((verify)); then
      [[ $(sha256_of "${files[i]}") == "${sums[i]}" ]] || die "チェックサムが一致しません (ファイルが変更/破損しています): ${files[i]}"
    fi
  done
  log_info "復元対象 (${DB_NAME}):"
  for ((i = 0; i < ${#names[@]}; i++)); do log_info "  ${names[i]}: $(fmt_num "${rows[i]}") 件 ← ${files[i]}"; done
  if ((append)); then
    confirm "上記のデータを $SERVER_INFO のデータベース $DB_NAME の各テーブルに追加します。"
  else
    confirm "上記のテーブルを TRUNCATE してから $SERVER_INFO のデータベース $DB_NAME に復元します。現在のデータは失われます。"
  fi
  local sf
  sf=$(schema_tmp "${names[@]}")
  ((append)) || warn_external_refs "$sf" "${names[@]}"
  for ((i = 0; i < ${#names[@]}; i++)); do
    restore_table_from_csv "${names[i]}" "${files[i]}" "${rows[i]}" "${ais[i]}" "$((!append))"
  done
  log_info "復元完了: ${#names[@]} テーブル"
}

# ---- load ---------------------------------------------------------------------
usage_load() {
  cat <<'EOF'
使い方: dbtool.sh load -d DB -t テーブル -f CSVファイル[,ファイル...] [オプション]
  CSV ファイルをテーブルに一括ロードします (LOAD DATA LOCAL INFILE)。
  ファイルごとに1トランザクションで処理し、警告・件数不一致があればロールバックします。
    -f, --file LIST          CSV ファイル (カンマ区切りで複数可, .gz 可)
        --format FMT         mysql   : dbtool 形式 (\ でエスケープ, 既定)
                             rfc4180 : Excel 等の一般的な CSV ("" でエスケープ)
        --no-header          1行目もデータとして扱う (列順はテーブル定義順)
        --encoding CS        ファイルの文字コード (既定 utf8mb4。Excel の CSV は cp932)
        --truncate           ロード前にテーブルを TRUNCATE する
        --chunk-rows N       N 件ごとに分割してコミットする (大きなファイル向け)
    -P, --parallel N         分割したファイルを N 並列でロード (既定 1)
        --on-warning MODE    rollback (既定) / continue (警告があってもコミット)
        --fk-checks on|off   外部キー検査 (既定 off)
        --time-zone TZ       TIMESTAMP 列の解釈に使うタイムゾーン
                             (既定: mysql 形式は +00:00, rfc4180 形式はサーバー既定)
        --empty-as-null on|off
                             文字列型 (CHAR/VARCHAR/TEXT/SET) 以外の列の空フィールドを NULL にする
                             (既定: rfc4180 形式は on, mysql 形式は off)
        --no-scan            事前の件数・列数チェックを省略
    -y, --yes                確認を省略
EOF
}

cmd_load() {
  local db="" table="" filespec="" format=mysql header=1 enc=utf8mb4 trunc=0 chunk=0 par=1 onwarn=ROLLBACK fk=off tz=__DEFAULT__ scan=1 en=auto
  while (($#)); do
    case $1 in
      -d|--database) db=${2-}; shift ;;
      -t|--tables|--table) table=${2-}; shift ;;
      -f|--file) filespec=${2-}; shift ;;
      --format) format=${2-}; shift ;;
      --no-header) header=0 ;;
      --encoding) enc=${2-}; shift ;;
      --truncate) trunc=1 ;;
      --chunk-rows) chunk=${2-}; shift ;;
      -P|--parallel) par=${2-}; shift ;;
      --on-warning) onwarn=$(tr '[:lower:]' '[:upper:]' <<<"${2-}"); shift ;;
      --fk-checks) fk=${2-}; shift ;;
      --time-zone) tz=${2-}; shift ;;
      --no-scan) scan=0 ;;
      --empty-as-null) en=${2-}; shift ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_load; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh load --help を参照)" ;;
    esac
    shift
  done
  [[ $format == mysql || $format == rfc4180 ]] || die "--format は mysql または rfc4180 を指定してください"
  [[ $onwarn == ROLLBACK || $onwarn == CONTINUE ]] || die "--on-warning は rollback または continue を指定してください"
  [[ $fk == on || $fk == off ]] || die "--fk-checks は on または off を指定してください"
  [[ $chunk =~ ^[0-9]+$ ]] || die "--chunk-rows は整数で指定してください"
  [[ $par =~ ^[1-9][0-9]*$ ]] || die "--parallel は 1 以上の整数で指定してください"
  [[ $enc =~ ^[A-Za-z0-9_]+$ ]] || die "--encoding が不正です: $enc"
  [[ $tz == __DEFAULT__ ]] && { if [[ $format == mysql ]]; then tz='+00:00'; else tz=""; fi; }
  case $en in
    auto) en=0; [[ $format == rfc4180 ]] && en=1 ;;
    on) en=1 ;;
    off) en=0 ;;
    *) die "--empty-as-null は on または off を指定してください" ;;
  esac
  [[ -n $table ]] || die "ロード先テーブルを -t で指定してください"
  [[ -n $filespec ]] || die "CSV ファイルを -f で指定してください"
  split_list "$filespec"
  local -a files=("${LIST_RESULT[@]}")
  local f
  for f in "${files[@]}"; do [[ -f $f ]] || die "ファイルがありません: $f"; done
  db_init; db_connect; require_local_infile
  use_database "${db:-$(conf DEFAULT_DATABASE)}"
  check_allowed_db
  expand_tables "$table"
  ((${#TABLES[@]} == 1)) || die "load のテーブルは1つだけ指定してください"
  table=${TABLES[0]}
  confirm "$(printf '%s のテーブル %s.%s に %d ファイルをロードします%s。' "$SERVER_INFO" "$DB_NAME" "$table" "${#files[@]}" "$( ((trunc)) && echo ' (事前に TRUNCATE)')")"
  if ((trunc)); then
    local sf; sf=$(schema_tmp "$table"); warn_external_refs "$sf" "$table"
    truncate_table "$table"; log_info "TRUNCATE しました: $table"
  fi
  local fkv=0; [[ $fk == on ]] && fkv=1
  local total=0
  for f in "${files[@]}"; do
    load_one_file "$table" "$f" "$format" "$header" "$enc" "$tz" "$fkv" "$onwarn" "$chunk" "$scan" "$par" "$en"
    total=$((total + LOAD_FILE_ROWS))
  done
  log_info "ロード完了: $table に $(fmt_num "$total") 件"
}

# load_one_file TABLE FILE FORMAT HEADER ENC TZ FK ONWARN CHUNK SCAN [PARALLEL] [EMPTY_NULL] → LOAD_FILE_ROWS
load_one_file() {
  local t=$1 f=$2 format=$3 header=$4 enc=$5 tz=$6 fk=$7 onwarn=$8 chunk=$9 scan=${10} par=${11:-1} en=${12:-0}
  local crlf=0 sf hdrf spec nf records=-1 out bad cl sl t0=$SECONDS
  first_line_crlf "$f" && crlf=1
  sf=$(schema_tmp "$t")
  hdrf=$(mktemp "$TMP_DIR/hdr.XXXXXX")
  if ((header)); then
    csv_header "$f" "$format" "$crlf" >"$hdrf" || die "CSV のヘッダーを読み取れません: $f"
    if [[ ! $enc =~ ^utf8 ]]; then convert_header_charset "$hdrf" "$enc"; fi
    if grep -q $'^#BOM\t1' "$hdrf"; then log_debug "BOM 付きファイル: $f"; fi
  else
    : >"$hdrf"
    if [[ $(set +o pipefail; if [[ $f == *.gz ]]; then gzip -dc -- "$f"; else cat -- "$f"; fi 2>/dev/null | head -c 3 | od -An -tx1 | tr -d ' ') == efbbbf ]]; then
      die "BOM 付きの CSV は --no-header では読めません (先頭のBOMを削除するかヘッダー行を付けてください): $f"
    fi
  fi
  spec=$(DBT_TABLE="$t" awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/colspec.awk" -v MODE=load -v EMPTY_NULL="$en" "$sf" "$hdrf") ||
    { log_block ERROR "  " "$(grep '^ERROR' <<<"$spec" | cut -f2-)"; die "CSV の列とテーブル $t の列を対応付けられません: $f"; }
  log_block WARN "  " "$(grep '^WARN' <<<"$spec" | cut -f2-)"
  out=$(grep '^MISSING' <<<"$spec" | cut -f2 || true)
  [[ -n $out ]] && log_info "  CSV にない列はデフォルト値になります: $(tr '\n' ' ' <<<"$out")"
  nf=$(spec_get "$spec" NFIELDS); cl=$(spec_get "$spec" COLLIST); sl=$(spec_get "$spec" SETLIST)
  if ((scan || chunk > 0)); then
    log_info "  CSV を検査しています: $f"
    if out=$(_csv_scan "$f" "$format" "$crlf" "$header" "$nf"); then :; else
      bad=$(grep -E '^(BADREC|UNTERMINATED)' <<<"$out" || true)
      if [[ -n $bad ]]; then
        log_error "CSV の形式が不正です: $f"
        local k a b c
        while IFS=$'\t' read -r k a b c; do
          if [[ $k == BADREC ]]; then log_error "  レコード $a (ファイル $b 行目): 列数 $c (期待 $nf)"; else log_error "  $a 行目から始まる引用符が閉じていません"; fi
        done <<<"$bad"
      fi
      die "CSV の検査でエラーが見つかったためロードを中止しました"
    fi
    records=$(awk -F'\t' '$1 == "RECORDS" { print $2 }' <<<"$out")
    log_info "  レコード数: $(fmt_num "$records") 件 (列数 $nf)"
  fi
  LOAD_FILE_ROWS=0
  if ((chunk > 0 && records > chunk)); then
    local cdir; cdir=$(mktemp -d "$TMP_DIR/chunks.XXXXXX")
    if out=$(_csv_split "$f" "$format" "$crlf" "$header" "$nf" "$chunk" "$cdir/part"); then :; else die "CSV の分割に失敗しました: $f"; fi
    local -a cf=() cn=()
    local k p n
    while IFS=$'\t' read -r k p n; do [[ $k == CHUNK ]] && { cf+=("$p"); cn+=("$n"); }; done <<<"$out"
    log_info "  ${#cf[@]} ファイルに分割してロードします (各 $(fmt_num "$chunk") 件)"
    local i; JOBS_FAILED=0
    for ((i = 0; i < ${#cf[@]}; i++)); do
      job_wait_slot "$par"
      job_start _load_chunk_job "$t" "${cf[i]}" "$cl" "$sl" "${cn[i]}" "$header" "$format" "$crlf" "$enc" "$tz" "$fk" "$onwarn" "$t $(basename -- "$f") [$((i + 1))/${#cf[@]}]"
    done
    job_wait_all
    rm -rf -- "$cdir"
    ((JOBS_FAILED == 0)) || die "$JOBS_FAILED 個の分割ファイルのロードに失敗しました ($f)。成功した分割はコミット済みです"
    LOAD_FILE_ROWS=$records
  else
    L_TABLE=$t L_FILE=$f L_COLLIST=$cl L_SETLIST=$sl L_EXPECTED=$records L_HEADER=$header L_DIALECT=$format \
      L_CRLF=$crlf L_CHARSET=$enc L_MODE=strict L_TZ=$tz L_FK=$fk L_ONWARN=$onwarn L_LABEL="$t ← $(basename -- "$f")" \
      load_csv_file || die "ロードに失敗しました: $f (このファイルの内容はロールバックされました)"
    LOAD_FILE_ROWS=$LOADED_ROWS
  fi
  log_info "  $t ← $f: $(fmt_num "$LOAD_FILE_ROWS") 件 ($(fmt_duration $((SECONDS - t0))))"
}

_load_chunk_job() {
  local t=$1 f=$2 cl=$3 sl=$4 n=$5 header=$6 format=$7 crlf=$8 enc=$9 tz=${10} fk=${11} onwarn=${12} label=${13}
  L_TABLE=$t L_FILE=$f L_COLLIST=$cl L_SETLIST=$sl L_EXPECTED=$n L_HEADER=$header L_DIALECT=$format \
    L_CRLF=$crlf L_CHARSET=$enc L_MODE=strict L_TZ=$tz L_FK=$fk L_ONWARN=$onwarn L_LABEL=$label load_csv_file || return 1
  log_info "  $label: $(fmt_num "$LOADED_ROWS") 件"
}

_csv_scan() { # FILE FORMAT CRLF HEADER NF
  local f=$1
  if [[ $f == *.gz ]]; then
    gzip -dc -- "$f" | awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=scan -v DIALECT="$2" -v CRLF="$3" -v HAS_HEADER="$4" -v NF_EXPECT="$5"
  else
    awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=scan -v DIALECT="$2" -v CRLF="$3" -v HAS_HEADER="$4" -v NF_EXPECT="$5" "$f"
  fi
}

_csv_split() { # FILE FORMAT CRLF HEADER NF CHUNK PREFIX
  local f=$1
  if [[ $f == *.gz ]]; then
    gzip -dc -- "$f" | DBT_OUT_PREFIX="$7" awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=split -v DIALECT="$2" -v CRLF="$3" -v HAS_HEADER="$4" -v NF_EXPECT="$5" -v CHUNK_ROWS="$6"
  else
    DBT_OUT_PREFIX="$7" awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=split -v DIALECT="$2" -v CRLF="$3" -v HAS_HEADER="$4" -v NF_EXPECT="$5" -v CHUNK_ROWS="$6" "$f"
  fi
}

# ヘッダーの列名を指定の文字コードから UTF-8 に変換 (LOAD DATA と同じく MySQL の変換を使用)
convert_header_charset() { # HEADER_FILE CHARSET
  local hf=$1 cs=$2 sel="" h out n=0
  while IFS= read -r h; do
    [[ $h == '#BOM'$'\t'* ]] && continue
    n=$((n + 1))
    sel+="${sel:+ UNION ALL }SELECT $n AS dbt_n, CONVERT(UNHEX('$h') USING $cs) AS dbt_name"
  done < <(awkc -f "$LIB/util.awk" -e 'BEGIN { util_init() } { if ($0 ~ /^#BOM\t/) print; else print hex_of_bytes(tsv_unescape($0)) }' "$hf")
  ((n > 0)) || return 0
  out=$(db_query "SELECT dbt_name FROM ($sel) dbt_h ORDER BY dbt_n")
  { printf '%s\n' "$out"; grep $'^#BOM\t' "$hf" || true; } >"$hf.u"
  mv -f -- "$hf.u" "$hf"
}

# ---- truncate -----------------------------------------------------------------
usage_truncate() {
  cat <<'EOF'
使い方: dbtool.sh truncate -d DB -t テーブル[,テーブル...] [-y]
  テーブルの全データを削除します (TRUNCATE TABLE, 外部キー検査は無効にして実行)。
  AUTO_INCREMENT は 1 に戻ります。
EOF
}

cmd_truncate() {
  local db="" tables=""
  while (($#)); do
    case $1 in
      -d|--database) db=${2-}; shift ;;
      -t|--tables) tables=${2-}; shift ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_truncate; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh truncate --help を参照)" ;;
    esac
    shift
  done
  db_init; db_connect
  use_database "${db:-$(conf DEFAULT_DATABASE)}"
  check_allowed_db
  expand_tables "$tables"
  local t sf
  log_info "対象テーブル ($DB_NAME):"
  for t in "${TABLES[@]}"; do log_info "  $t: $(fmt_num "$(count_rows "$t")") 件"; done
  confirm "上記テーブルの全データを削除 (TRUNCATE) します。"
  sf=$(schema_tmp "${TABLES[@]}")
  warn_external_refs "$sf" "${TABLES[@]}"
  for t in "${TABLES[@]}"; do truncate_table "$t"; log_info "TRUNCATE しました: $t"; done
}

# ---- delete -------------------------------------------------------------------
usage_delete() {
  cat <<'EOF'
使い方: dbtool.sh delete -d DB -t テーブル[,テーブル...] [--where 条件] [オプション]
  DELETE で行を削除します。一定件数ごとにコミットするため大量削除でも安全です。
  TRUNCATE と違い AUTO_INCREMENT は維持され、トリガーも実行されます。
    --where COND        削除条件 (SQL の WHERE 句。省略時は全件)
    --batch-rows N      1回の DELETE で削除する件数 (既定: conf の DELETE_BATCH_ROWS, 10000)
    --fk-checks on|off  外部キー検査 (既定 on。on の場合は参照されている行は削除できません)
    -y, --yes           確認を省略
EOF
}

cmd_delete() {
  local db="" tables="" where="" batch="" fk=on
  while (($#)); do
    case $1 in
      -d|--database) db=${2-}; shift ;;
      -t|--tables) tables=${2-}; shift ;;
      --where) where=${2-}; shift ;;
      --batch-rows) batch=${2-}; shift ;;
      --fk-checks) fk=${2-}; shift ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_delete; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh delete --help を参照)" ;;
    esac
    shift
  done
  batch=${batch:-$(conf DELETE_BATCH_ROWS 10000)}
  [[ $batch =~ ^[1-9][0-9]*$ ]] || die "--batch-rows は 1 以上の整数で指定してください"
  [[ $fk == on || $fk == off ]] || die "--fk-checks は on または off を指定してください"
  [[ $where == *';'* ]] && die "--where にセミコロンは使用できません"
  db_init; db_connect
  use_database "${db:-$(conf DEFAULT_DATABASE)}"
  check_allowed_db
  expand_tables "$tables"
  local t n
  local -A cnt=()
  log_info "削除対象 ($DB_NAME${where:+, 条件: $where}):"
  for t in "${TABLES[@]}"; do
    n=$(db_query "SELECT COUNT(*) FROM $(qtable "$t")${where:+ WHERE ($where)}" --raw)
    cnt[$t]=$n
    log_info "  $t: $(fmt_num "$n") 件"
  done
  confirm "上記の行を削除します。"
  local fkv=1; [[ $fk == off ]] && fkv=0
  for t in "${TABLES[@]}"; do
    ((${cnt[$t]} == 0)) && { log_info "  $t: 削除対象なし"; continue; }
    delete_rows "$t" "$where" "$batch" "$fkv"
    log_info "削除しました: $t $(fmt_num "$DELETED_ROWS") 件"
    if ((!DRY_RUN)); then
      n=$(db_query "SELECT COUNT(*) FROM $(qtable "$t")${where:+ WHERE ($where)}" --raw)
      ((n == 0)) || log_warn "  $t: 条件に一致する行がまだ $n 件あります (削除中に追加された可能性があります)"
    fi
  done
}

# ---- count --------------------------------------------------------------------
cmd_count() {
  local db="" tables="" estimate=0
  while (($#)); do
    case $1 in
      -d|--database) db=${2-}; shift ;;
      -t|--tables) tables=${2-}; shift ;;
      --estimate) estimate=1 ;;
      -h|--help) printf '使い方: dbtool.sh count -d DB -t テーブル[,...] [--estimate]\n  件数を表示します (--estimate は統計情報の概算値で高速)。\n'; return 0 ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
  db_init; db_connect
  use_database "${db:-$(conf DEFAULT_DATABASE)}"
  expand_tables "$tables"
  local t n
  printf '%-40s %15s\n' "テーブル" "件数$( ((estimate)) && echo '(概算)')"
  for t in "${TABLES[@]}"; do
    if ((estimate)); then
      n=$(db_query "SELECT IFNULL(TABLE_ROWS,0) FROM information_schema.TABLES WHERE TABLE_SCHEMA=$(sql_str "$DB_NAME") AND TABLE_NAME=$(sql_str "$t")" --raw)
    else
      n=$(count_rows "$t")
    fi
    printf '%-40s %15s\n' "$t" "$(fmt_num "$n")"
  done
}

# ---- ping ---------------------------------------------------------------------
cmd_ping() {
  [[ ${1-} == -h || ${1-} == --help ]] && { printf '使い方: dbtool.sh ping\n  接続確認とサーバー情報の表示を行います。\n'; return 0; }
  db_init; db_connect
  log_info "  local_infile = $DB_LOCAL_INFILE$( [[ $DB_LOCAL_INFILE == 1 ]] && echo ' (LOAD DATA LOCAL 使用可)' || echo ' (無効: ロード機能は使用できません)')"
  log_info "  time_zone = $DB_TZ (system: $DB_SYSTZ)"
  local tls
  tls=$(db_query "SELECT VARIABLE_VALUE FROM performance_schema.session_status WHERE VARIABLE_NAME='Ssl_cipher'" --raw || true)
  log_info "  SSL/TLS = ${tls:-(未使用)}"
}
