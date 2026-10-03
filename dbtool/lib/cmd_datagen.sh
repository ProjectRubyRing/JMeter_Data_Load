# shellcheck shell=bash
# =============================================================================
# cmd_datagen.sh : schema / validate / generate / prepare / cleanup / runs
# =============================================================================

declare -A CFG_G=()
CFG_TABLES=()
RUN_STATE=""
RUN_FINISHED=0

# ---- 設定ファイル (Excel 出力) ---------------------------------------------------
read_config() {
  local f=$1 k v magic=0
  [[ -f $f ]] || die "設定ファイルがありません: $f"
  CFG_G=(); CFG_TABLES=()
  while IFS=$'\x1f' read -r k v; do
    case $k in
      '#MAGIC') magic=1 ;;
      '#T') CFG_TABLES+=("$v") ;;
      *) CFG_G[$k]=$v ;;
    esac
  done < <(awkc -f "$LIB/util.awk" -F'\t' -e '
    FNR == 1 { sub(/^\357\273\277/, ""); sub(/\r$/, ""); if ($1 == "#DBTOOL-DATAGEN-CONFIG") print "#MAGIC\037" $2; next }
    { sub(/\r$/, "") }
    $1 == "GLOBAL" { print tolower(tsv_unescape($2)) "\037" tsv_unescape($3) }
    $1 == "TABLE"  { t = tsv_unescape($2); if (!(t in seen)) { seen[t] = 1; print "#T\037" t } }
    $1 == "COLUMN" && toupper($5) ~ /^[ ]*REF[ ]*$/ {
        p = tsv_unescape($6); sub(/^[ ]+/, "", p); sub(/[ ]+$/, "", p)
        if (match(p, /\.[^.]*$/)) { t = substr(p, 1, RSTART - 1); if (!(t in seen)) { seen[t] = 1; print "#T\037" t } }
    }' "$f")
  ((magic)) || die "Excel から出力した設定ファイルを指定してください (1行目が #DBTOOL-DATAGEN-CONFIG ではありません): $f"
  ((${#CFG_TABLES[@]} > 0)) || die "設定ファイルにテーブルがありません: $f"
}

# 設定ファイルの検証と生成計画の作成 (成功 0 / 設定に誤り 1)
run_plan() { # MODE CONFIG PLANDIR
  local mode=$1 cfg=$2 pd=$3 base tz rc
  mk_private_dir "$pd"; mk_private_dir "$pd/refkeys"
  PLAN_SCHEMA="$pd/schema.tsv"
  fetch_schema "${CFG_TABLES[@]}" >"$PLAN_SCHEMA"
  tz=${CFG_G[time_zone]-}
  base=${CFG_G[base_datetime]-}
  if [[ -z $base ]]; then
    base=$(db_query "${tz:+SET SESSION time_zone=$(sql_str "$tz");}
SELECT DATE_FORMAT(NOW(), '%Y-%m-%d %H:%i:%s');" --raw)
  fi
  log_info "基準日時 (NOW / TODAY): $base${tz:+ (タイムゾーン $tz)}"
  PLAN_ERRORS=0; PLAN_WARNINGS=0
  rc=0
  DBT_MODE=$mode DBT_BASE=$base DBT_DBNAME=$DB_NAME DBT_REQFILE="$pd/requests.tsv" DBT_PLANDIR="$pd" \
    awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/plan.awk" -v PHASE=1 "$PLAN_SCHEMA" "$cfg" >"$pd/messages1.tsv" || rc=$?
  show_plan_messages "$pd/messages1.tsv" ""
  ((rc == 0)) || return 1
  : >"$pd/resolve.tsv"
  [[ -s $pd/requests.tsv ]] && resolve_requests "$pd/requests.tsv" "$pd/resolve.tsv" "$pd/refkeys"
  rc=0
  DBT_MODE=$mode DBT_BASE=$base DBT_DBNAME=$DB_NAME DBT_REQFILE="$pd/requests2.tsv" DBT_PLANDIR="$pd" \
    awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/plan.awk" -v PHASE=2 "$PLAN_SCHEMA" "$cfg" "$pd/resolve.tsv" >"$pd/messages2.tsv" || rc=$?
  show_plan_messages "$pd/messages2.tsv" "$pd/messages1.tsv"
  ((rc == 0)) || return 1
  read_plan_tables "$pd"
  read_plan_globals "$pd"
  return 0
}

show_plan_messages() { # FILE [除外するFILE]
  local f=$1 ex=${2-} lv t c m loc
  while IFS=$'\x1f' read -r lv t c m; do
    loc=$t${c:+.$c}
    case $lv in
      ERROR) log_error "${loc:+$loc: }$m"; PLAN_ERRORS=$((PLAN_ERRORS + 1)) ;;
      WARN)  log_warn "${loc:+$loc: }$m"; PLAN_WARNINGS=$((PLAN_WARNINGS + 1)) ;;
      INFO)  log_info "${loc:+$loc: }$m" ;;
    esac
  done < <(if [[ -n $ex && -s $ex ]]; then grep -vxF -f "$ex" -- "$f" || true; else cat -- "$f"; fi |
    awkc -f "$LIB/util.awk" -F'\t' -e '{ print $1 "\037" tsv_unescape($2) "\037" tsv_unescape($3) "\037" $4 }')
}

# ---- DB への問い合わせ (PHASE1 の要求を解決) -----------------------------------------
resolve_requests() { # REQ RES KEYDIR
  local req=$1 res=$2 kd=$3 n=0 key
  local -a F
  local -A seen=()
  while IFS=$'\x1f' read -r -a F; do
    key="${F[*]}"
    [[ -n ${seen[$key]-} ]] && continue
    seen[$key]=1
    case ${F[0]} in
      MAX)   resolve_max "$(tsv_unescape "${F[1]}")" "$(tsv_unescape "${F[2]}")" >>"$res" ;;
      REFDB) n=$((n + 1)); resolve_refdb "$kd/db_$n.tsv" "$(tsv_unescape "${F[1]}")" "$(tsv_unescape "${F[2]}")" "${F[@]:3}" >>"$res" ;;
      WKT)   resolve_wkt "$(tsv_unescape "${F[1]}")" "$(tsv_unescape "${F[2]}")" "$(tsv_unescape "${F[3]}")" "${F[4]}" >>"$res" ;;
      JSON)  resolve_json "$(tsv_unescape "${F[1]}")" "$(tsv_unescape "${F[2]}")" "${F[3]}" "$(tsv_unescape "${F[4]-}")" >>"$res" ;;
      RANGE) resolve_range "$(tsv_unescape "${F[1]}")" "$(tsv_unescape "${F[2]}")" "${F[3]}" "${F[4]}" "${F[5]}" "${F[6]}" >>"$res" ;;
      *) die "内部エラー: 不明な問い合わせ要求です: ${F[0]}" ;;
    esac
  done < <(tr '\t' '\037' <"$req")
}

resolve_max() {
  local t=$1 c=$2 v
  v=$(db_query "SELECT IFNULL(CEILING(MAX($(sql_ident "$c"))),0) FROM $(qtable "$t")" --raw)
  printf 'MAX\t%s\t%s\t%s\n' "$(tsv_escape "$t")" "$(tsv_escape "$c")" "$v"
}

# 参照先のキー集合を取得 (整数の連続値なら ARITH, それ以外はファイル)
resolve_refdb() { # KEYFILE KEY PARENT COL(escaped)...
  local kf=$1 key=$2 pt=$3; shift 3
  local -a cols=()
  local c spec sel where kind out cnt mn mx errf
  for c in "$@"; do cols+=("$(tsv_unescape "$c")"); done
  spec=$(DBT_TABLE="$pt" DBT_COLS="$(printf '%s\n' "${cols[@]}")" awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/colspec.awk" -v MODE=exprs "$PLAN_SCHEMA") ||
    die "参照先 $pt の列情報を取得できません: $(grep '^ERROR' <<<"$spec" | cut -f2-)"
  sel=$(spec_get "$spec" SELECT); where=$(spec_get "$spec" WHERE); kind=$(spec_get "$spec" KIND)
  log_info "参照キーを取得しています: $pt (${cols[*]})"
  if [[ $kind == int ]]; then
    out=$(db_query "SELECT COUNT(DISTINCT $(sql_ident "${cols[0]}")), IFNULL(MIN($(sql_ident "${cols[0]}")),0), IFNULL(MAX($(sql_ident "${cols[0]}")),0) FROM $(qtable "$pt") WHERE $where" --raw)
    IFS=$'\t' read -r cnt mn mx <<<"$out"
    if ((cnt > 0)) && ((${#mn} <= 15 && ${#mx} <= 15)) && ((mx - mn + 1 == cnt)); then
      printf 'REF\t%s\tARITH\t%s\t%s\t1\t\n' "$(tsv_escape "$key")" "$cnt" "$mn"
      log_info "  $pt: $(fmt_num "$cnt") 件 (連続値 $mn～$mx)"
      return 0
    fi
  fi
  errf=$(mktemp "$TMP_DIR/err.XXXXXX")
  local ob="" i
  for ((i = 1; i <= ${#cols[@]}; i++)); do ob+="${ob:+,}$i"; done
  if ! { sql_preamble strict; printf 'SET SESSION net_write_timeout=3600;\nSELECT DISTINCT %s FROM %s WHERE %s ORDER BY %s;\n' "$sel" "$(qtable "$pt")" "$where" "$ob"; } |
    "$MYSQL_BIN" "${MYSQL_OPTS[@]}" --batch --skip-column-names --quick >"$kf" 2>"$errf"; then
    die "参照キーの取得に失敗しました ($pt): $(mysql_errmsg "$errf")"
  fi
  cnt=$(wc -l <"$kf")
  ((cnt > 5000000)) && log_warn "  参照キーが $(fmt_num "$cnt") 件あります。生成処理のメモリ使用量が大きくなります"
  printf 'REF\t%s\tFILE\t%s\t0\t0\t%s\n' "$(tsv_escape "$key")" "$cnt" "$(tsv_escape "$kf")"
  log_info "  $pt: $(fmt_num "$cnt") 件"
}

resolve_wkt() {
  local t=$1 c=$2 wkt=$3 srid=$4 hex gt
  if db_try "SELECT HEX(g), ST_GeometryType(g) FROM (SELECT ST_GeomFromText($(sql_str "$wkt"), $srid) AS g) x" --raw; then
    IFS=$'\t' read -r hex gt <<<"$DB_OUT"
    printf 'WKT\t%s\t%s\tOK\t%s\t%s\n' "$(tsv_escape "$t")" "$(tsv_escape "$c")" "$hex" "$gt"
  else
    printf 'WKT\t%s\t%s\tERR\t%s\t\n' "$(tsv_escape "$t")" "$(tsv_escape "$c")" "$(tsv_escape "$DB_ERROR")"
  fi
}

resolve_json() {
  local t=$1 c=$2 k=$3 v=$4 ok
  ok=$(db_query "SELECT JSON_VALID($(sql_str "$v"))" --raw)
  printf 'JSON\t%s\t%s\t%s\t%s\n' "$(tsv_escape "$t")" "$(tsv_escape "$c")" "$k" "$ok"
}

resolve_range() {
  local t=$1 c=$2 lo=$3 hi=$4 start=$5 step=$6 q n extra=""
  q=$(sql_ident "$c")
  ((step != 1 && step != -1)) && extra=" AND MOD($q - ($start), ${step#-}) = 0"
  n=$(db_query "SELECT COUNT(*) FROM $(qtable "$t") WHERE $q BETWEEN $lo AND $hi$extra" --raw)
  printf 'RANGE\t%s\t%s\t%s\n' "$(tsv_escape "$t")" "$(tsv_escape "$c")" "$n"
}

# ---- 計画の読込 ---------------------------------------------------------------
read_plan_tables() {
  local pd=$1
  local -a F
  PT_SEQ=(); PT_NAME=(); PT_ROWS=(); PT_BEFORE=(); PT_BACKUP=(); PT_CLEAN=(); PT_WHERE=()
  PT_DKCOL=(); PT_DKSTART=(); PT_DKLAST=(); PT_DKSTEP=(); PT_COLLIST=(); PT_SETLIST=(); PT_SEED=(); PT_HASJM=()
  while IFS=$'\x1f' read -r -a F; do
    [[ ${F[0]} == TABLE ]] || continue
    PT_SEQ+=("${F[1]}"); PT_NAME+=("$(tsv_unescape "${F[2]}")"); PT_ROWS+=("${F[3]}")
    PT_BEFORE+=("${F[4]}"); PT_BACKUP+=("${F[5]}"); PT_CLEAN+=("${F[6]}"); PT_WHERE+=("$(tsv_unescape "${F[7]-}")")
    PT_DKCOL+=("$(tsv_unescape "${F[8]-}")"); PT_DKSTART+=("${F[9]-}"); PT_DKLAST+=("${F[10]-}"); PT_DKSTEP+=("${F[11]-}")
    PT_COLLIST+=("$(tsv_unescape "${F[12]-}")"); PT_SETLIST+=("$(tsv_unescape "${F[13]-}")"); PT_SEED+=("${F[14]-}"); PT_HASJM+=("${F[15]-N}")
  done < <(tr '\t' '\037' <"$pd/tables.tsv")
}

declare -A PG=()
read_plan_globals() {
  local pd=$1 k v
  PG=()
  while IFS=$'\t' read -r k v; do PG[$k]=$(tsv_unescape "$v"); done <"$pd/globals.tsv"
}

print_plan_summary() {
  local i
  printf '\n  %-4s %-30s %15s  %-9s %-6s %-17s\n' "順" "テーブル" "生成件数" "事前処理" "バックアップ" "後片付け" >&2
  for ((i = 0; i < ${#PT_NAME[@]}; i++)); do
    printf '  %-4s %-30s %15s  %-9s %-6s %-17s\n' "$((i + 1))" "${PT_NAME[i]}" "$(fmt_num "${PT_ROWS[i]}")" "${PT_BEFORE[i]}" "${PT_BACKUP[i]}" \
      "${PT_CLEAN[i]}${PT_DKCOL[i]:+ (${PT_DKCOL[i]})}" >&2
  done
  printf '\n  ファイル分割 %s 件 / 並列数 %s / 外部キー検査 %s / 警告時 %s%s\n\n' "$(fmt_num "${PG[rows_per_file]}")" "${PG[parallel]}" "${PG[fk_checks]}" "${PG[on_warning]}" \
    "${PG[time_zone]:+ / タイムゾーン ${PG[time_zone]}}" >&2
}

# ---- 生成 ---------------------------------------------------------------------
# DEFER (実行時に決まる参照キー) を解決した計画ファイルを作成
finalize_plan() { # PLAN OUT OUTDIR
  local plan=$1 out=$2 od=$3 line n=0
  : >"$out.part"
  while IFS= read -r line; do
    if [[ $line == G$'\t'* && $line == *$'\t'DEFER$'\t'* ]]; then
      n=$((n + 1))
      line=$(resolve_defer_line "$line" "$od" "$(basename -- "$plan" .plan)_$n")
    fi
    printf '%s\n' "$line" >>"$out.part"
  done <"$plan"
  mv -f -- "$out.part" "$out"
}

resolve_defer_line() { # LINE OUTDIR NAME → G 行
  local line=$1 od=$2 name=$3 kf cnt res
  local -a F files
  IFS=$'\x1f' read -r -a F <<<"${line//$'\t'/$'\x1f'}"
  kf="$od/refkeys/$name.tsv"
  mk_private_dir "$od/refkeys"
  if [[ ${F[9]} == PCSV ]]; then
    files=("$od"/data/"${F[10]}"_*/part-*.csv)
    [[ -f ${files[0]} ]] || die "参照先の生成データがありません (計画 ${F[10]})"
    awkc -f "$LIB/util.awk" -f "$LIB/csv.awk" -v MODE=extract -v COLS="${F[11]}" "${files[@]}" >"$kf" || die "参照キーの抽出に失敗しました"
    cnt=$(wc -l <"$kf")
    ((cnt > 0)) || die "参照先の生成データに有効なキーがありません (すべて NULL)"
    printf 'G\t%s\t%s\t%s\tFILE\t%s\t0\t0\t%s' "${F[1]}" "${F[2]}" "${F[3]}" "$cnt" "$(tsv_escape "$kf")"
    return 0
  fi
  # LATE: 先にロードした参照先テーブルから取得
  res=$(resolve_refdb "$kf" "late" "$(tsv_unescape "${F[10]}")" "${F[@]:11}")
  local _r _k src rcnt rstart rstep rfile
  IFS=$'\x1f' read -r _r _k src rcnt rstart rstep rfile <<<"${res//$'\t'/$'\x1f'}"
  ((rcnt > 0)) || die "参照先 $(tsv_unescape "${F[10]}") にデータがありません"
  printf 'G\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "${F[1]}" "${F[2]}" "${F[3]}" "$src" "$rcnt" "$rstart" "$rstep" "$rfile"
}

# generate_table INDEX OUTDIR PARALLEL ROWS_PER_FILE → GEN_DIR
generate_table() {
  local i=$1 od=$2 par=$3 rpf=$4
  local seq=${PT_SEQ[i]} t=${PT_NAME[i]} rows=${PT_ROWS[i]} plan fplan dir nch k start cnt jm t0=$SECONDS jh
  plan="$PLAN_DIR/$seq.plan"; fplan="$od/plan_final/$seq.plan"
  dir="$od/data/${seq}_$(safe_name "$t")"
  mk_private_dir "$dir"; mk_private_dir "$od/plan_final"; mk_private_dir "$od/jmeter_parts"; mk_private_dir "$od/jmeter"
  finalize_plan "$plan" "$fplan" "$od"
  nch=$(( (rows + rpf - 1) / rpf ))
  log_info "データ生成: $t $(fmt_num "$rows") 件 ($nch ファイル)"
  JOBS_FAILED=0
  for ((k = 1; k <= nch; k++)); do
    start=$(( (k - 1) * rpf )); cnt=$(( rows - start < rpf ? rows - start : rpf ))
    jm=""; [[ ${PT_HASJM[i]} == Y ]] && jm="$od/jmeter_parts/${seq}_$(printf '%06d' "$k").csv"
    job_wait_slot "$par"
    job_start _gen_chunk "$fplan" "$k" "$start" "$cnt" "$dir/part-$(printf '%06d' "$k").csv" "$jm"
  done
  job_wait_all
  ((JOBS_FAILED == 0)) || die "データ生成に失敗しました: $t"
  if [[ ${PT_HASJM[i]} == Y ]]; then
    jh=$(awk -F'\t' 'NR == 1 { print $7 }' "$fplan")
    { printf '%s\n' "$(tsv_unescape "$jh")"; cat -- "$od/jmeter_parts/${seq}"_*.csv; } >"$od/jmeter/$(safe_name "$t").csv"
    rm -f -- "$od/jmeter_parts/${seq}"_*.csv
    log_info "  JMeter 用 CSV: $od/jmeter/$(safe_name "$t").csv ($(fmt_num $(( $(wc -l <"$od/jmeter/$(safe_name "$t").csv") - 1 ))) 件)"
  fi
  log_info "  生成完了: $t ($(du -sh -- "$dir" | cut -f1), $(fmt_duration $((SECONDS - t0))))"
  GEN_DIR=$dir
}

_gen_chunk() {
  local plan=$1 k=$2 start=$3 cnt=$4 out=$5 jm=$6 errf lines
  errf=$(mktemp "$TMP_DIR/gen.XXXXXX")
  if ! DBT_OUTF=$out DBT_JOUTF=$jm awkc -f "$LIB/util.awk" -f "$LIB/gen.awk" -v START="$start" -v COUNT="$cnt" -v CHUNK="$k" "$plan" 2>"$errf"; then
    log_error "データ生成エラー ($out): $(tr '\n' ' ' <"$errf")"
    return 1
  fi
  lines=$(wc -l <"$out")
  if ((lines != cnt + 1)); then log_error "生成件数が一致しません ($out: 期待 $((cnt + 1)) 行 / 実際 $lines 行)"; return 1; fi
  rm -f -- "$errf"
}

# load_table_parts INDEX DIR PARALLEL FK TZ ONWARN
load_table_parts() {
  local i=$1 dir=$2 par=$3 fk=$4 tz=$5 onwarn=$6 f k=0 nf
  local -a files=("$dir"/part-*.csv)
  nf=${#files[@]}
  JOBS_FAILED=0
  for f in "${files[@]}"; do
    k=$((k + 1))
    job_wait_slot "$par"
    job_start _load_part "$i" "$f" "$fk" "$tz" "$onwarn" "$k/$nf"
    ((JOBS_FAILED == 0)) || break
  done
  job_wait_all
  ((JOBS_FAILED == 0))
}

_load_part() {
  local i=$1 f=$2 fk=$3 tz=$4 onwarn=$5 label=$6 n
  n=$(( $(wc -l <"$f") - 1 ))
  L_TABLE=${PT_NAME[i]} L_FILE=$f L_COLLIST=${PT_COLLIST[i]} L_SETLIST=${PT_SETLIST[i]} L_EXPECTED=$n L_HEADER=1 \
    L_DIALECT=mysql L_CRLF=0 L_CHARSET=utf8mb4 L_MODE=strict L_TZ=$tz L_FK=$fk L_ONWARN=$onwarn \
    L_LABEL="${PT_NAME[i]} [$label]" load_csv_file || return 1
  log_info "  ${PT_NAME[i]} [$label]: $(fmt_num "$LOADED_ROWS") 件ロード"
}

# ---- schema -------------------------------------------------------------------
usage_schema() {
  cat <<'EOF'
使い方: dbtool.sh schema -d DB -t テーブル[,テーブル...] [オプション]
  テーブル定義を取得し、生成方式の初期値を自動判定した設定用 Excel (.xlsm) を出力します。
    -t, --tables LIST    対象テーブル (カンマ区切り, * でワイルドカード)
        --with-parents   外部キーの参照先テーブルも含める
    -o, --output FILE    出力ファイル (.xlsm)。既定: output/<DB>_datagen_<日時>.xlsm
        --rows N         生成件数の初期値 (既定 10000)
        --tsv-only       Excel を作らずスキーマ TSV のみ出力 (Excel の「スキーマ取込」で読込可)
EOF
}

cmd_schema() {
  local db="" tables="" out="" rows=10000 parents=0 tsvonly=0
  while (($#)); do
    case $1 in
      -d|--database) db=${2-}; shift ;;
      -t|--tables) tables=${2-}; shift ;;
      -o|--output) out=${2-}; shift ;;
      --rows) rows=${2-}; shift ;;
      --with-parents) parents=1 ;;
      --tsv-only) tsvonly=1 ;;
      -h|--help) usage_schema; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh schema --help を参照)" ;;
    esac
    shift
  done
  [[ $rows =~ ^[0-9]+$ ]] || die "--rows は整数で指定してください"
  db_init; db_connect
  use_database "${db:-$(conf DEFAULT_DATABASE)}"
  expand_tables "$tables"
  local sf added p
  sf=$(mktemp "$TMP_DIR/schema.XXXXXX")
  fetch_schema "${TABLES[@]}" >"$sf"
  if ((parents)); then
    while :; do
      added=0
      while IFS= read -r p; do
        [[ -z $p ]] && continue
        if [[ " ${TABLES[*]} " != *" $p "* ]]; then TABLES+=("$p"); added=1; fi
      done < <(awk -F'\t' -v DB="$DB_NAME" '$1 == "F" && $6 == DB { print $7 }' "$sf" | sort -u)
      ((added)) || break
      fetch_schema "${TABLES[@]}" >"$sf"
    done
  fi
  local base tsv tpl
  if [[ -z $out ]]; then
    mk_private_dir "$(resolve_path output)"
    out="$(resolve_path output)/${DB_NAME}_datagen_$(now_ts).xlsm"
  fi
  [[ $out == *.xlsm ]] || out+=".xlsm"
  base=${out%.xlsm}; tsv="$base.tsv"
  mkdir -p -- "$(dirname -- "$out")"
  DBT_DB=$DB_NAME DBT_GENERATED_AT=$(now_disp) DBT_SERVER_VERSION=$SERVER_VERSION DBT_SERVER_HOST=$DB_HOSTNAME \
    DBT_TOOL_VERSION=$DBTOOL_VERSION DBT_REQ="$(printf '%s\n' "${TABLES[@]}")" \
    awkc -f "$LIB/util.awk" -f "$LIB/schema_lib.awk" -f "$LIB/schema.awk" -v DEFROWS="$rows" "$sf" >"$tsv" ||
    die "スキーマ情報の作成に失敗しました"
  log_info "スキーマ情報: $tsv ($(grep -c '^TABLE' "$tsv") テーブル / $(grep -c '^COLUMN' "$tsv") 列)"
  if ((tsvonly)); then
    log_info "Excel (DataGenConfig.xlsm) の「スキーマ取込」ボタンでこのファイルを読み込んでください"
    return 0
  fi
  tpl="$DBTOOL_HOME/templates/DataGenConfig.xlsm"
  [[ -f $tpl ]] || die "Excel テンプレートがありません: $tpl (--tsv-only で TSV のみ出力できます)"
  command -v python3 >/dev/null 2>&1 || die "python3 がないため Excel を作成できません (--tsv-only で TSV のみ出力し、Excel の「スキーマ取込」で読み込んでください)"
  python3 "$LIB/xlsm_embed.py" "$tpl" "$tsv" "$out" || die "Excel の作成に失敗しました"
  chmod 600 -- "$out" 2>/dev/null || true
  log_info "設定用 Excel を作成しました: $out"
  log_info "  1. Windows にコピーして Excel で開き、[コンテンツの有効化] でマクロを有効にします (列設定シートが自動作成されます)"
  log_info "  2. テーブル設定/列設定シートを編集し、[設定ファイル出力] ボタンで設定ファイル (.conf) を出力します"
  log_info "  3. 設定ファイルをこのサーバーにコピーし、dbtool.sh validate / prepare -c <設定ファイル> を実行します"
}

# ---- validate -----------------------------------------------------------------
cmd_validate() {
  local cfg="" db=""
  while (($#)); do
    case $1 in
      -c|--config) cfg=${2-}; shift ;;
      -d|--database) db=${2-}; shift ;;
      -h|--help) printf '使い方: dbtool.sh validate -c 設定ファイル [-d DB]\n  設定ファイルを検証します (DB の現在の定義・データと照合)。データは変更しません。\n'; return 0 ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
  [[ -n $cfg ]] || die "設定ファイルを -c で指定してください"
  read_config "$cfg"
  db_init; db_connect
  use_database "${db:-${CFG_G[database]-}}"
  PLAN_DIR="$TMP_DIR/plan"
  if ! run_plan prepare "$cfg" "$PLAN_DIR"; then
    die "設定ファイルに誤りがあります (エラー $PLAN_ERRORS 件, 警告 $PLAN_WARNINGS 件)"
  fi
  print_plan_summary
  log_info "検証 OK: エラーなし (警告 $PLAN_WARNINGS 件)"
}

# ---- generate -----------------------------------------------------------------
usage_generate() {
  cat <<'EOF'
使い方: dbtool.sh generate -c 設定ファイル [-o 出力ディレクトリ]
  設定ファイルに従ってテストデータの CSV を生成します (DB へのロードは行いません)。
  参照先の値の取得などのため DB には接続します (読み取りのみ)。
    -o, --output DIR   出力先 (既定: WORK_DIR/generate/<DB>_<日時>)
  出力: data/<順>_<テーブル>/part-NNNNNN.csv, jmeter/<テーブル>.csv
EOF
}

cmd_generate() {
  local cfg="" db="" od=""
  while (($#)); do
    case $1 in
      -c|--config) cfg=${2-}; shift ;;
      -d|--database) db=${2-}; shift ;;
      -o|--output) od=${2-}; shift ;;
      -h|--help) usage_generate; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh generate --help を参照)" ;;
    esac
    shift
  done
  [[ -n $cfg ]] || die "設定ファイルを -c で指定してください"
  read_config "$cfg"
  db_init; db_connect
  use_database "${db:-${CFG_G[database]-}}"
  od=$(resolve_path "${od:-$WORK_DIR/generate/${DB_NAME}_$(now_ts)}")
  [[ -e $od && -n $(ls -A -- "$od" 2>/dev/null) ]] && die "出力先が空ではありません: $od"
  mk_private_dir "$od"
  PLAN_DIR="$od/plan"
  run_plan generate "$cfg" "$PLAN_DIR" || die "設定ファイルに誤りがあります (エラー $PLAN_ERRORS 件)"
  print_plan_summary
  local i t0=$SECONDS
  for ((i = 0; i < ${#PT_NAME[@]}; i++)); do
    ((PT_ROWS[i] > 0)) || continue
    generate_table "$i" "$od" "${PG[parallel]}" "${PG[rows_per_file]}"
  done
  rmdir -- "$od/jmeter_parts" 2>/dev/null || true
  log_info "生成完了: $od ($(fmt_duration $((SECONDS - t0))))"
}

# ---- prepare ------------------------------------------------------------------
usage_prepare() {
  cat <<'EOF'
使い方: dbtool.sh prepare -c 設定ファイル [オプション]
  性能テスト用データを一括で準備します。
    1. 事前バックアップ (事前バックアップ=Y のテーブルを CSV に出力)
    2. 事前処理 (TRUNCATE / DELETE)
    3. テストデータの生成とロード (処理順に従い、テーブルごとに生成→ロード)
    4. JMeter 用 CSV の出力
  実行内容は work/runs/<実行ID> に記録され、cleanup で後片付けできます。
    -d, --database DB   接続先データベース (省略時は設定ファイルの database)
        --run-id ID     実行ID (既定: <DB>_<日時>)
        --keep-data     生成した CSV を削除せずに残す
        --no-verify     ロード後の件数確認 (COUNT(*)) を省略
        --dry-run       実行される SQL を表示するだけで DB を変更しない
    -y, --yes           確認を省略
EOF
}

cmd_prepare() {
  local cfg="" db="" runid="" keep=0 verify=1
  while (($#)); do
    case $1 in
      -c|--config) cfg=${2-}; shift ;;
      -d|--database) db=${2-}; shift ;;
      --run-id) runid=${2-}; shift ;;
      --keep-data) keep=1 ;;
      --no-verify) verify=0 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_prepare; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh prepare --help を参照)" ;;
    esac
    shift
  done
  [[ -n $cfg ]] || die "設定ファイルを -c で指定してください"
  read_config "$cfg"
  db_init; db_connect; require_local_infile
  use_database "${db:-${CFG_G[database]-}}"
  check_allowed_db
  acquire_lock
  runid=${runid:-${DB_NAME}_$(now_ts)}
  [[ $runid =~ ^[A-Za-z0-9._-]+$ ]] || die "実行ID に使用できない文字が含まれています: $runid"
  local rd="$WORK_DIR/runs/$runid"
  [[ -e $rd ]] && die "同じ実行ID のディレクトリが既にあります: $rd"
  mk_private_dir "$rd"
  cp -- "$cfg" "$rd/config.conf"
  PLAN_DIR="$rd/plan"
  if ! run_plan prepare "$cfg" "$PLAN_DIR"; then
    rm -rf -- "$rd"
    die "設定ファイルに誤りがあります (エラー $PLAN_ERRORS 件)。データベースは変更していません"
  fi
  print_plan_summary
  local i n t t0=$SECONDS fk tz onwarn par rpf before after f
  local -a affected=()
  for ((i = 0; i < ${#PT_NAME[@]}; i++)); do
    if [[ ${PT_BEFORE[i]} != NONE || ${PT_CLEAN[i]} != NONE ]]; then affected+=("${PT_NAME[i]}"); fi
  done
  warn_external_refs "$PLAN_SCHEMA" "${affected[@]}"
  confirm "$SERVER_INFO のデータベース $DB_NAME で上記のテストデータ準備を実行します (実行ID: $runid)。" "$rd"
  if ((DRY_RUN)); then log_info "[dry-run] 以降は実行する SQL を表示します (DB は変更しません)"; fi

  RUN_STATE="$rd/state.tsv"; RUN_FINISHED=0
  printf '%s\tRUN\tSTART\t%s\t%s\t%s\n' "$(now_disp)" "$(tsv_escape "$DB_NAME")" "$(tsv_escape "$SERVER_INFO")" "$DBTOOL_VERSION" >>"$RUN_STATE"
  fk=$([[ ${PG[fk_checks]} == ON ]] && echo 1 || echo 0)
  tz=${PG[time_zone]}; onwarn=${PG[on_warning]}; par=${PG[parallel]}; rpf=${PG[rows_per_file]}

  # 1. バックアップ
  mk_private_dir "$rd/backup"
  for ((i = 0; i < ${#PT_NAME[@]}; i++)); do
    [[ ${PT_BACKUP[i]} == Y ]] || continue
    t=${PT_NAME[i]}
    f="$rd/backup/${PT_SEQ[i]}_$(safe_name "$t").csv"
    export_table "$t" "$f" 0
    printf '%s\tTABLE\t%s\t%s\tBACKUP\t%s\t%s\t%s\t%s\n' "$(now_disp)" "${PT_SEQ[i]}" "$(tsv_escape "$t")" "$(tsv_escape "$f")" "$EXPORT_ROWS" "${EXPORT_AUTOINC:-}" "$(sha256_of "$f")" >>"$RUN_STATE"
  done

  # 2. 事前処理 (子テーブルから逆順)
  for ((i = ${#PT_NAME[@]} - 1; i >= 0; i--)); do
    t=${PT_NAME[i]}
    case ${PT_BEFORE[i]} in
      TRUNCATE|DELETE)
        printf '%s\tTABLE\t%s\t%s\tPRELOAD\t%s\n' "$(now_disp)" "${PT_SEQ[i]}" "$(tsv_escape "$t")" "${PT_BEFORE[i]}" >>"$RUN_STATE"
        if [[ ${PT_BEFORE[i]} == TRUNCATE ]]; then truncate_table "$t"; log_info "事前処理: $t を TRUNCATE しました"
        else delete_rows "$t" "" "$(conf DELETE_BATCH_ROWS 10000)" 0; log_info "事前処理: $t を全件 DELETE しました ($(fmt_num "$DELETED_ROWS") 件)"; fi
        ;;
    esac
  done

  # 3. 生成とロード
  mk_private_dir "$rd/jmeter"
  for ((i = 0; i < ${#PT_NAME[@]}; i++)); do
    t=${PT_NAME[i]}
    ((PT_ROWS[i] > 0)) || { log_info "$t: 生成件数 0 のためロードしません"; continue; }
    generate_table "$i" "$rd" "$par" "$rpf"
    before=0
    if ((verify && !DRY_RUN)) && [[ ${PT_BEFORE[i]} == NONE ]]; then before=$(count_rows "$t"); fi
    printf '%s\tTABLE\t%s\t%s\tLOAD_START\n' "$(now_disp)" "${PT_SEQ[i]}" "$(tsv_escape "$t")" >>"$RUN_STATE"
    log_info "ロード開始: $t"
    n=$SECONDS
    load_table_parts "$i" "$GEN_DIR" "$par" "$fk" "$tz" "$onwarn" ||
      die "ロードに失敗しました: $t (失敗したファイルはロールバック済み。後片付けは dbtool.sh cleanup --run $runid)"
    if ((verify && !DRY_RUN)); then
      after=$(count_rows "$t")
      if ((after != before + PT_ROWS[i])); then
        log_warn "$t: ロード後の件数が想定と異なります (想定 $(fmt_num $((before + PT_ROWS[i]))) 件 / 実際 $(fmt_num "$after") 件)。トリガー等の影響を確認してください"
      else
        log_info "  件数確認 OK: $t $(fmt_num "$after") 件"
      fi
    fi
    printf '%s\tTABLE\t%s\t%s\tLOADED\t%s\n' "$(now_disp)" "${PT_SEQ[i]}" "$(tsv_escape "$t")" "${PT_ROWS[i]}" >>"$RUN_STATE"
    log_info "ロード完了: $t $(fmt_num "${PT_ROWS[i]}") 件 ($(fmt_duration $((SECONDS - n))))"
  done
  rmdir -- "$rd/jmeter_parts" 2>/dev/null || true
  if ((!keep)); then rm -rf -- "$rd/data" "$rd/refkeys"; fi
  printf '%s\tRUN\tDONE\n' "$(now_disp)" >>"$RUN_STATE"
  RUN_FINISHED=1
  if ((DRY_RUN)); then
    rm -rf -- "$rd"
    log_info "[dry-run] 完了しました (DB は変更していません。実行記録は残しません)"
    return 0
  fi
  log_info "テストデータの準備が完了しました (実行ID: $runid, $(fmt_duration $((SECONDS - t0))))"
  if compgen -G "$rd/jmeter/*.csv" >/dev/null; then
    log_info "JMeter 用 CSV:"
    for f in "$rd"/jmeter/*.csv; do log_info "  $f"; done
  fi
  log_info "テスト後の後片付け: $0 cleanup --run $runid"
}

# ---- 実行履歴 -------------------------------------------------------------------
# run_status RUNDIR → "DB<TAB>状態<TAB>開始日時"
run_status() {
  awk -F'\t' '
    $2 == "RUN" && $3 == "START" { db = $4; st = "RUNNING"; started = $1 }
    $2 == "RUN" && $3 == "DONE" { st = "COMPLETED" }
    $2 == "RUN" && $3 == "FAILED" { st = "FAILED" }
    $2 == "CLEANUP" && $3 == "START" { st = "CLEANING" }
    $2 == "CLEANUP" && $3 == "DONE" { st = "CLEANED" }
    $2 == "CLEANUP" && $3 == "FAILED" { st = "CLEANUP_FAILED" }
    END { printf "%s\t%s\t%s\n", db, st, started }' "$1/state.tsv"
}

cmd_runs() {
  local del="" d st db started
  while (($#)); do
    case $1 in
      --delete) del=${2-}; shift ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) printf '使い方: dbtool.sh runs [--delete 実行ID]\n  prepare の実行履歴を表示します。--delete で記録 (バックアップを含む) を削除します。\n'; return 0 ;;
      *) die "不明なオプションです: $1" ;;
    esac
    shift
  done
  if [[ -n $del ]]; then
    [[ $del =~ ^[A-Za-z0-9._-]+$ ]] || die "実行ID が不正です: $del"
    d="$WORK_DIR/runs/$del"
    [[ -d $d ]] || die "実行ID がありません: $del"
    IFS=$'\t' read -r db st started <<<"$(run_status "$d")"
    [[ $st == CLEANED ]] || log_warn "この実行はまだ後片付けされていません (状態: $st)。バックアップも削除されます"
    confirm "実行記録 $del ($d) を削除します。"
    rm -rf -- "$d"
    log_info "削除しました: $del"
    return 0
  fi
  printf '%-36s %-20s %-15s %-20s %s\n' "実行ID" "データベース" "状態" "開始日時" "サイズ"
  [[ -d $WORK_DIR/runs ]] || return 0
  for d in "$WORK_DIR"/runs/*/; do
    [[ -f $d/state.tsv ]] || continue
    IFS=$'\t' read -r db st started <<<"$(run_status "$d")"
    printf '%-36s %-20s %-15s %-20s %s\n' "$(basename -- "$d")" "$(tsv_unescape "$db")" "$st" "$started" "$(du -sh -- "$d" | cut -f1)"
  done
}

# ---- cleanup ------------------------------------------------------------------
usage_cleanup() {
  cat <<'EOF'
使い方: dbtool.sh cleanup [--run 実行ID] [オプション]
  prepare で変更したテーブルを、設定の「後片付け」に従って元に戻します (処理順の逆順)。
    RESTORE          : TRUNCATE してから事前バックアップを復元 (AUTO_INCREMENT も復元)
    DELETE_GENERATED : 生成した行 (連番の範囲) だけを削除
    DELETE_WHERE     : 後片付け条件 (WHERE) に一致する行を削除
    TRUNCATE         : 全件削除
    NONE             : 何もしない
    --run ID      対象の実行ID (省略時は後片付けしていない最新の実行)
    -d DB         実行ID 省略時に対象データベースで絞り込む
    --force       後片付け済み/未変更のテーブルも再実行する
    --dry-run     実行される SQL を表示するだけで DB を変更しない
    -y, --yes     確認を省略
EOF
}

cmd_cleanup() {
  local runid="" db="" force=0 cfg=""
  while (($#)); do
    case $1 in
      --run) runid=${2-}; shift ;;
      -d|--database) db=${2-}; shift ;;
      -c|--config) cfg=${2-}; shift ;;
      --force) force=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -h|--help) usage_cleanup; return 0 ;;
      *) die "不明なオプションです: $1 (dbtool.sh cleanup --help を参照)" ;;
    esac
    shift
  done
  if [[ -n $cfg && -z $db ]]; then read_config "$cfg"; db=${CFG_G[database]-}; fi
  local rd d st rdb started best="" bestts=""
  if [[ -n $runid ]]; then
    [[ $runid =~ ^[A-Za-z0-9._-]+$ ]] || die "実行ID が不正です: $runid"
    rd="$WORK_DIR/runs/$runid"
    [[ -f $rd/state.tsv ]] || die "実行記録がありません: $rd"
  else
    for d in "$WORK_DIR"/runs/*/; do
      [[ -f $d/state.tsv ]] || continue
      IFS=$'\t' read -r rdb st started <<<"$(run_status "$d")"
      [[ $st == CLEANED ]] && continue
      [[ -n $db && $(tsv_unescape "$rdb") != "$db" ]] && continue
      if [[ -z $best || $started > $bestts ]]; then best=${d%/}; bestts=$started; fi
    done
    [[ -n $best ]] || die "後片付けの対象となる実行記録がありません (dbtool.sh runs で確認できます)"
    rd=$best; runid=$(basename -- "$rd")
  fi
  IFS=$'\t' read -r rdb st started <<<"$(run_status "$rd")"
  rdb=$(tsv_unescape "$rdb")
  if [[ $st == CLEANED && $force -eq 0 ]]; then die "実行 $runid は後片付け済みです (再実行する場合は --force)"; fi
  db_init; db_connect
  use_database "$rdb"
  check_allowed_db
  acquire_lock
  PLAN_DIR="$rd/plan"
  read_plan_tables "$PLAN_DIR"
  # テーブルごとの状態
  local -A bk_file=() bk_rows=() bk_ai=() bk_sum=() touched=() cleaned=()
  local -a F
  while IFS=$'\x1f' read -r -a F; do
    if [[ ${F[1]} == TABLE ]]; then
      case ${F[4]} in
        BACKUP) bk_file[${F[2]}]=$(tsv_unescape "${F[5]}"); bk_rows[${F[2]}]=${F[6]}; bk_ai[${F[2]}]=${F[7]-}; bk_sum[${F[2]}]=${F[8]-} ;;
        PRELOAD|LOAD_START|LOADED) touched[${F[2]}]=1 ;;
      esac
    elif [[ ${F[1]} == CLEANUP && ${F[2]} == TABLE ]]; then
      cleaned[${F[3]}]=1
    fi
  done < <(tr '\t' '\037' <"$rd/state.tsv")
  local i t seq act
  local -a todo=()
  log_info "後片付け対象 (実行ID $runid, 状態 $st, データベース $DB_NAME):"
  for ((i = ${#PT_NAME[@]} - 1; i >= 0; i--)); do
    seq=${PT_SEQ[i]}; t=${PT_NAME[i]}; act=${PT_CLEAN[i]}
    if [[ -z ${touched[$seq]-} && $force -eq 0 ]]; then log_info "  $t: 変更されていないためスキップ"; continue; fi
    if [[ -n ${cleaned[$seq]-} && $force -eq 0 ]]; then log_info "  $t: 後片付け済みのためスキップ"; continue; fi
    if [[ $act == NONE ]]; then log_info "  $t: 後片付けなし (NONE)"; continue; fi
    if [[ $act == RESTORE && -z ${bk_file[$seq]-} ]]; then die "$t: RESTORE に必要な事前バックアップがありません"; fi
    case $act in
      RESTORE) log_info "  $t: RESTORE (バックアップ $(fmt_num "${bk_rows[$seq]}") 件を復元)" ;;
      DELETE_GENERATED) log_info "  $t: DELETE_GENERATED (${PT_DKCOL[i]} が ${PT_DKSTART[i]}～${PT_DKLAST[i]} の行を削除)" ;;
      DELETE_WHERE) log_info "  $t: DELETE_WHERE (${PT_WHERE[i]})" ;;
      TRUNCATE) log_info "  $t: TRUNCATE" ;;
    esac
    todo+=("$i")
  done
  ((${#todo[@]} > 0)) || { log_info "後片付けするテーブルはありません"; return 0; }
  for i in "${todo[@]}"; do
    seq=${PT_SEQ[i]}
    if [[ ${PT_CLEAN[i]} == RESTORE ]]; then
      [[ -f ${bk_file[$seq]} ]] || die "バックアップファイルがありません: ${bk_file[$seq]}"
      [[ -z ${bk_sum[$seq]-} || $(sha256_of "${bk_file[$seq]}") == "${bk_sum[$seq]}" ]] || die "バックアップファイルが変更/破損しています: ${bk_file[$seq]}"
    fi
  done
  confirm "上記の後片付けを $SERVER_INFO のデータベース $DB_NAME で実行します。"
  RUN_STATE="$rd/state.tsv"; RUN_FINISHED=1
  printf '%s\tCLEANUP\tSTART\n' "$(now_disp)" >>"$RUN_STATE"
  local ok=1 batch
  batch=$(conf DELETE_BATCH_ROWS 10000)
  for i in "${todo[@]}"; do
    seq=${PT_SEQ[i]}; t=${PT_NAME[i]}
    log_info "後片付け: $t (${PT_CLEAN[i]})"
    # errexit を有効にしたまま実行するため子プロセスで実行して終了を待つ
    _cleanup_one "$i" "${bk_file[$seq]-}" "${bk_rows[$seq]-0}" "${bk_ai[$seq]-}" "$batch" &
    if ! wait $!; then
      ok=0
      printf '%s\tCLEANUP\tTABLE\t%s\t%s\t%s\tFAILED\n' "$(now_disp)" "$seq" "$(tsv_escape "$t")" "${PT_CLEAN[i]}" >>"$RUN_STATE"
      log_error "$t の後片付けに失敗しました。原因を確認して再実行してください (dbtool.sh cleanup --run $runid)"
      break
    fi
    ((DRY_RUN)) || printf '%s\tCLEANUP\tTABLE\t%s\t%s\t%s\tDONE\n' "$(now_disp)" "$seq" "$(tsv_escape "$t")" "${PT_CLEAN[i]}" >>"$RUN_STATE"
  done
  if ((ok)); then
    ((DRY_RUN)) || printf '%s\tCLEANUP\tDONE\n' "$(now_disp)" >>"$RUN_STATE"
    log_info "後片付けが完了しました (実行ID: $runid)"
  else
    printf '%s\tCLEANUP\tFAILED\n' "$(now_disp)" >>"$RUN_STATE"
    exit 1
  fi
}

_cleanup_one() { # INDEX BACKUP_FILE BACKUP_ROWS BACKUP_AUTOINC BATCH
  local i=$1 bf=$2 br=$3 bai=$4 batch=$5 t=${PT_NAME[$1]}
  case ${PT_CLEAN[i]} in
    RESTORE) restore_table_from_csv "$t" "$bf" "$br" "$bai" ;;
    DELETE_GENERATED)
      delete_range "$t" "${PT_DKCOL[i]}" "${PT_DKSTART[i]}" "${PT_DKLAST[i]}" "${PT_DKSTEP[i]}" "$batch" 0
      log_info "  $t: $(fmt_num "$DELETED_ROWS") 件削除しました" ;;
    DELETE_WHERE)
      delete_rows "$t" "${PT_WHERE[i]}" "$batch" 0
      log_info "  $t: $(fmt_num "$DELETED_ROWS") 件削除しました" ;;
    TRUNCATE) truncate_table "$t"; log_info "  $t: TRUNCATE しました" ;;
  esac
}
