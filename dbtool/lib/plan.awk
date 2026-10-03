# =============================================================================
# plan.awk : データ生成設定ファイルの検証と生成計画の作成
#   DBT_MODE=generate|prepare DBT_BASE='YYYY-MM-DD HH:MM:SS' DBT_DBNAME=<接続先DB>
#   DBT_REQFILE=<phase1 要求出力> DBT_PLANDIR=<phase2 計画出力先>
#   LC_ALL=C TZ=UTC gawk -f util.awk -f schema_lib.awk -f plan.awk -v PHASE=1|2 \
#       schema.tsv config.conf [resolve.tsv]
#
#   PHASE=1 : 静的な検証。DB への問い合わせが必要な項目を REQFILE に出力
#             MAX    table column                      (SEQ 開始値 AUTO)
#             REFDB  key parent_table col1 [col2 ...]  (外部キー参照値)
#             WKT    table column wkt srid             (空間データの変換)
#             JSON   table column k value              (JSON 妥当性)
#             RANGE  table column lo hi start step     (既存データとの重複確認)
#   PHASE=2 : 問い合わせ結果 (resolve.tsv) を使って最終検証し、計画を PLANDIR に出力
#             MAX table column value / REF key src count start step file /
#             WKT table column OK|ERR hex|message geomtype / JSON table column k 0|1 /
#             RANGE table column count
#   標準出力: LEVEL<TAB>table<TAB>column<TAB>message   (LEVEL = ERROR / WARN / INFO)
# =============================================================================

BEGIN {
    FS = "\t"; util_init()
    MODE = ENVIRON["DBT_MODE"]; BASE_DATETIME = ENVIRON["DBT_BASE"]; DBNAME = ENVIRON["DBT_DBNAME"]
    REQFILE = ENVIRON["DBT_REQFILE"]; PLANDIR = ENVIRON["DBT_PLANDIR"]
    if (BASE_DATETIME != "" && !set_base(BASE_DATETIME)) { emit("ERROR", "", "", "基準日時が不正です: " BASE_DATETIME); }
    split("SEQ TEMPLATE RANDOM_INT RANDOM_DECIMAL UNIQUE_INT RANDOM_STRING UNIQUE_STRING UUID LIST CYCLE RANDOM_DATE RANDOM_DATETIME RANDOM_TIME SEQ_DATETIME REF RANDOM_BYTES FIXED COPY NULL DEFAULT", _r, " ")
    for (_i in _r) RULES[_r[_i]] = 1
    G_DEF["rows_per_file"] = "100000"; G_DEF["parallel"] = "1"; G_DEF["fk_checks"] = "ON"
    G_DEF["time_zone"] = ""; G_DEF["base_datetime"] = ""; G_DEF["on_warning"] = "ROLLBACK"; G_DEF["database"] = ""
    UNIQ_CLASSES = " digit upper lower alpha alnum hex hexupper alnumupper "
}

ARGIND == 1 { if (!schema_record()) { emit("ERROR", "", "", "スキーマ情報の形式が不正です"); exit 2 }; next }
ARGIND == 2 { config_line(); next }
ARGIND == 3 { resolve_line(); next }

END {
    if (FATAL) exit 2
    if (!CFG_MAGIC) { emit("ERROR", "", "", "設定ファイルの1行目が #DBTOOL-DATAGEN-CONFIG ではありません (Excel から出力したファイルを指定してください)"); exit 2 }
    validate_globals()
    order_tables()
    for (o = 1; o <= NORD; o++) validate_table(ORD[o])
    for (o = 1; o <= NORD; o++) validate_table_post(ORD[o])
    if (PHASE == 1) { close(REQFILE) }
    else if (ERRORS == 0) emit_plans()
    exit (ERRORS > 0) ? 1 : 0
}

# ---- メッセージ ---------------------------------------------------------------
# stage="R" は問い合わせ結果に依存する検査 (PHASE2 でのみ出力)。
# PHASE2 は全メッセージを出力し、呼び出し側で PHASE1 と重複しない行だけを表示する。
function emit(level, t, c, m) { print level "\t" tsv_escape(t) "\t" tsv_escape(c) "\t" tsv_escape(m); if (level == "ERROR") ERRORS++ }
function err(t, c, m, stage)  { if (stage == "R" && PHASE == 1) return; emit("ERROR", t, c, m) }
function warn(t, c, m, stage) { if (stage == "R" && PHASE == 1) return; emit("WARN", t, c, m) }
function info(t, c, m, stage) { if (stage == "R" && PHASE == 1) return; emit("INFO", t, c, m) }
function req(line) { if (PHASE == 1) print line > REQFILE }

# ---- 設定ファイル -------------------------------------------------------------
function config_line(    n, i, f, t, c, key) {
    if (FNR == 1) sub(/^\357\273\277/, "")
    sub(/\r$/, "")
    if (FNR == 1) {
        if ($1 == "#DBTOOL-DATAGEN-CONFIG") {
            CFG_MAGIC = 1
            if ($2 != "1") { emit("ERROR", "", "", "設定ファイルの形式バージョン " $2 " には対応していません"); FATAL = 1 }
        }
        return
    }
    if ($0 ~ /^[ \t]*$/ || substr($0, 1, 1) == "#") return
    n = split($0, f, "\t")
    for (i = 1; i <= n; i++) f[i] = tsv_unescape(f[i])
    if (f[1] == "GLOBAL") {
        key = tolower(trim(f[2]))
        if (!(key in G_DEF)) { emit("WARN", "", "", "未知の共通設定です (無視します): " f[2]); return }
        GLOBAL[key] = f[3]
        return
    }
    if (f[1] == "TABLE") {
        t = f[2]
        if (t in CT_SEEN) { emit("ERROR", t, "", "テーブル設定が重複しています"); return }
        CT_SEEN[t] = 1; NCT++; CT_LIST[NCT] = t
        CT_EN[t] = toupper(trim(f[3])); CT_ROWS[t] = trim(f[4]); CT_ORDER[t] = trim(f[5])
        CT_BEFORE[t] = toupper(trim(f[6])); CT_BACKUP[t] = toupper(trim(f[7])); CT_CLEAN[t] = toupper(trim(f[8]))
        CT_WHERE[t] = trim(f[9]); CT_SEED[t] = trim(f[10]); CT_JMROWS[t] = trim(f[11]); CT_LINE[t] = FNR
        return
    }
    if (f[1] == "COLUMN") {
        t = f[2]; c = f[3]
        if ((t, c) in CC_SEEN) { emit("ERROR", t, c, "列設定が重複しています"); return }
        CC_SEEN[t, c] = 1; n = ++CC_N[t]; CC_LIST[t, n] = c
        CC_TYPE[t, c] = f[4]; CC_RULE[t, c] = toupper(trim(f[5]))
        CC_P1[t, c] = f[6]; CC_P2[t, c] = f[7]; CC_P3[t, c] = f[8]
        CC_NULLR[t, c] = trim(f[9]); CC_JM[t, c] = toupper(trim(f[10]))
        return
    }
    emit("ERROR", "", "", "設定ファイル " FNR " 行目: 不明なレコード種別です: " f[1])
}

function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }

function resolve_line(    f, n, i) {
    n = split($0, f, "\t")
    for (i = 1; i <= n; i++) f[i] = tsv_unescape(f[i])
    if (f[1] == "MAX") RES_MAX[f[2], f[3]] = f[4]
    else if (f[1] == "REF") { RES_REF[f[2]] = 1; RES_REF_SRC[f[2]] = f[3]; RES_REF_CNT[f[2]] = f[4]; RES_REF_START[f[2]] = f[5]; RES_REF_STEP[f[2]] = f[6]; RES_REF_FILE[f[2]] = f[7] }
    else if (f[1] == "WKT") { RES_WKT[f[2], f[3]] = f[4]; RES_WKT_V[f[2], f[3]] = f[5]; RES_WKT_T[f[2], f[3]] = f[6] }
    else if (f[1] == "JSON") RES_JSON[f[2], f[3], f[4]] = f[5]
    else if (f[1] == "RANGE") RES_RANGE[f[2], f[3]] = f[4]
}

# ---- 共通設定 -----------------------------------------------------------------
function validate_globals(    k, v) {
    for (k in G_DEF) if (!(k in GLOBAL)) GLOBAL[k] = G_DEF[k]
    for (k in GLOBAL) GLOBAL[k] = trim(GLOBAL[k])
    if (GLOBAL["database"] == "") emit("ERROR", "", "", "共通設定 database (データベース名) が指定されていません")
    v = GLOBAL["rows_per_file"]
    if (!is_int_str(v) || v + 0 < 1 || v + 0 > 100000000) emit("ERROR", "", "", "共通設定 rows_per_file (ファイル分割件数) は 1～100000000 の整数で指定してください: " v)
    v = GLOBAL["parallel"]
    if (!is_int_str(v) || v + 0 < 1 || v + 0 > 32) emit("ERROR", "", "", "共通設定 parallel (並列数) は 1～32 の整数で指定してください: " v)
    GLOBAL["fk_checks"] = toupper(GLOBAL["fk_checks"])
    if (GLOBAL["fk_checks"] != "ON" && GLOBAL["fk_checks"] != "OFF") emit("ERROR", "", "", "共通設定 fk_checks は ON または OFF を指定してください")
    GLOBAL["on_warning"] = toupper(GLOBAL["on_warning"])
    if (GLOBAL["on_warning"] != "ROLLBACK" && GLOBAL["on_warning"] != "CONTINUE") emit("ERROR", "", "", "共通設定 on_warning は ROLLBACK または CONTINUE を指定してください")
    if (GLOBAL["base_datetime"] != "" && parse_datetime(GLOBAL["base_datetime"]) == "") emit("ERROR", "", "", "共通設定 base_datetime (基準日時) の書式が不正です: " GLOBAL["base_datetime"])
    if (GLOBAL["time_zone"] != "" && GLOBAL["time_zone"] !~ /^([+-]([0-9]|0[0-9]|1[0-4]):[0-5][0-9]|[A-Za-z][A-Za-z0-9_\/+-]*)$/) emit("ERROR", "", "", "共通設定 time_zone の書式が不正です (例: +09:00 / Asia/Tokyo): " GLOBAL["time_zone"])
    if (PHASE == 1 && DBNAME != "" && GLOBAL["database"] != "" && GLOBAL["database"] != DBNAME) emit("WARN", "", "", "設定ファイルのデータベース名 (" GLOBAL["database"] ") と接続先 (" DBNAME ") が異なります")
}

# ---- テーブル -----------------------------------------------------------------
function order_tables(    i, t, j, k, tmp, rt) {
    NORD = 0
    for (i = 1; i <= NCT; i++) {
        t = CT_LIST[i]
        rt = real_table(t)
        if (CT_EN[t] != "Y" && CT_EN[t] != "N") { err(t, "", "対象 は Y または N を指定してください: " CT_EN[t]); continue }
        if (CT_EN[t] == "N") continue
        if (rt == "") { err(t, "", "テーブルがデータベースに存在しません"); continue }
        CT_REAL[t] = rt
        if (!is_int_str(CT_ORDER[t])) { err(t, "", "処理順 は整数で指定してください: " CT_ORDER[t]); CT_ORDER[t] = 999999 }
        ORD[++NORD] = t; EN[t] = 1
    }
    # 処理順 → 設定ファイル記載順 で安定ソート
    for (i = 2; i <= NORD; i++) {
        tmp = ORD[i]; j = i - 1
        while (j >= 1 && CT_ORDER[ORD[j]] + 0 > CT_ORDER[tmp] + 0) { ORD[j + 1] = ORD[j]; j-- }
        ORD[j + 1] = tmp
    }
    for (i = 1; i <= NORD; i++) ORDPOS[ORD[i]] = i
}

function validate_table(t,    rt, n, i, c, rc, rows, v) {
    rt = CT_REAL[t]
    v = CT_ROWS[t]
    if (!is_int_str(v) || v + 0 < 0 || v + 0 > 10000000000) { err(t, "", "生成件数 は 0～10000000000 の整数で指定してください: " v); ROWS[t] = 0 }
    else ROWS[t] = v + 0
    if (CT_BEFORE[t] !~ /^(NONE|TRUNCATE|DELETE)$/) err(t, "", "事前処理 は NONE / TRUNCATE / DELETE のいずれかです: " CT_BEFORE[t])
    if (CT_BACKUP[t] !~ /^(Y|N)$/) err(t, "", "事前バックアップ は Y または N を指定してください: " CT_BACKUP[t])
    if (CT_CLEAN[t] !~ /^(RESTORE|DELETE_GENERATED|DELETE_WHERE|TRUNCATE|NONE)$/) err(t, "", "後片付け は RESTORE / DELETE_GENERATED / DELETE_WHERE / TRUNCATE / NONE のいずれかです: " CT_CLEAN[t])
    if (CT_CLEAN[t] == "RESTORE" && CT_BACKUP[t] != "Y") err(t, "", "後片付け RESTORE には 事前バックアップ=Y が必要です")
    if (CT_CLEAN[t] == "DELETE_WHERE" && CT_WHERE[t] == "") err(t, "", "後片付け DELETE_WHERE には 後片付け条件(WHERE) の指定が必要です")
    if (CT_CLEAN[t] != "DELETE_WHERE" && CT_WHERE[t] != "") warn(t, "", "後片付け条件(WHERE) は 後片付け=DELETE_WHERE のときだけ使用されます")
    if (CT_WHERE[t] ~ /;/) err(t, "", "後片付け条件(WHERE) にセミコロンは使用できません")
    if (CT_SEED[t] == "") CT_SEED[t] = "12345"
    if (!is_int_str(CT_SEED[t]) || CT_SEED[t] + 0 < 0 || CT_SEED[t] + 0 > 2147483647) err(t, "", "乱数シード は 0～2147483647 の整数で指定してください: " CT_SEED[t])
    if (CT_JMROWS[t] == "") CT_JMROWS[t] = "0"
    if (!is_int_str(CT_JMROWS[t]) || CT_JMROWS[t] + 0 < 0) err(t, "", "JMeter出力件数 は 0 以上の整数で指定してください: " CT_JMROWS[t])
    if (T_TYPE[rt] != "BASE TABLE") err(t, "", "通常のテーブルではありません (" T_TYPE[rt] ")")
    if (T_ENGINE[rt] != "InnoDB") warn(t, "", "ストレージエンジンが InnoDB ではありません (" T_ENGINE[rt] ")。ロード失敗時のロールバックができません")
    if (TRIGGERS[rt] != "") info(t, "", "トリガーがあります (ロード時に実行されます): " TRIGGERS[rt])
    if (CHECKS[rt] != "") info(t, "", "CHECK 制約があります。生成値が制約を満たすことを確認してください: " CHECKS[rt])

    # 設定にある列
    NPC[t] = 0
    for (i = 1; i <= CC_N[t]; i++) {
        c = CC_LIST[t, i]; rc = real_column(rt, c)
        if (rc == "") { err(t, c, "列がテーブルに存在しません"); continue }
        CMAP[t, rc] = c
        if (CC_TYPE[t, c] != "" && tolower(CC_TYPE[t, c]) != tolower(C_CT[rt, rc])) warn(t, c, "データ型が Excel 作成時から変更されています (設定: " CC_TYPE[t, c] " / DB: " C_CT[rt, rc] ")")
    }
    # DB の列順に計画列を作成
    for (n = 1; n <= T_NCOL[rt]; n++) {
        rc = COLS[rt, n]
        if (!((t, rc) in CMAP)) {
            if (C_GEN[rt, rc]) continue
            if (!C_HASDEF[rt, rc]) err(t, rc, "設定ファイルにこの列がありません (NOT NULL かつデフォルト値なしのため必須)")
            else warn(t, rc, "設定ファイルにこの列がないため DEFAULT (デフォルト値) として扱います")
            continue
        }
        validate_column(t, rt, rc, CMAP[t, rc])
    }
}

# ---- 列 -----------------------------------------------------------------------
function validate_column(t, rt, c, cfgc,    k, rule, p1, p2, p3, r1, nr, jm, idx, out, msg) {
    k = C_KIND[rt, c]; rule = CC_RULE[t, cfgc]
    r1 = CC_P1[t, cfgc]; p1 = trim(r1); p2 = trim(CC_P2[t, cfgc]); p3 = trim(CC_P3[t, cfgc])
    nr = CC_NULLR[t, cfgc]; jm = CC_JM[t, cfgc]
    if (rule == "") { err(t, c, "生成方式が指定されていません"); return }
    if (!(rule in RULES)) { err(t, c, "不明な生成方式です: " rule); return }
    if (k == "unknown") { if (rule != "DEFAULT" && rule != "NULL") { err(t, c, "未対応のデータ型です (" C_DT[rt, c] ")。DEFAULT または NULL を指定してください"); return } }
    if (C_GEN[rt, c] && rule != "DEFAULT") { err(t, c, "生成列には DEFAULT 以外指定できません"); return }
    if (jm == "") jm = "N"
    if (jm != "Y" && jm != "N") err(t, c, "JMeter出力 は Y または N を指定してください: " jm)
    if (nr == "") nr = "0"
    if (!is_dec_str(nr) || nr + 0 < 0 || nr + 0 > 100) { err(t, c, "NULL率(%) は 0～100 の数値で指定してください: " nr); nr = 0 }
    nr = nr + 0
    if (nr > 0 && !C_NULL[rt, c]) { err(t, c, "NOT NULL 列には NULL率を指定できません"); nr = 0 }
    if (nr > 0 && (rule == "NULL" || rule == "DEFAULT" || rule == "COPY")) { warn(t, c, "生成方式 " rule " では NULL率 は無視されます"); nr = 0 }

    if (rule == "DEFAULT") {
        if (!C_HASDEF[rt, c]) err(t, c, "NOT NULL かつデフォルト値がない列は DEFAULT にできません")
        if (jm == "Y") warn(t, c, "DEFAULT の列は JMeter 用 CSV に出力できません (DB が値を決めるため)")
        return
    }
    if (rule == "NULL" && !C_NULL[rt, c]) { err(t, c, "NOT NULL 列に NULL は指定できません"); return }

    idx = ++NPC[t]; PCOL[t, idx] = c; PIDX[t, c] = idx
    PRULE[t, idx] = rule; PNULL[t, idx] = nr; PJM[t, idx] = jm; PNV[t, idx] = 0
    POUT[t, idx] = kind_out(k)
    PA1[t, idx] = ""; PA2[t, idx] = ""; PA3[t, idx] = ""; PA4[t, idx] = ""; PA5[t, idx] = ""
    PUNIQ[t, idx] = 0; PDOM[t, idx] = -1; PMAXC[t, idx] = 0; PMAXB[t, idx] = 0
    if (rule == "SEQ") v_seq(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "TEMPLATE") v_template(t, rt, c, idx, k, r1, p2, p3)
    else if (rule == "RANDOM_INT" || rule == "UNIQUE_INT") v_int(t, rt, c, idx, k, rule, p1, p2)
    else if (rule == "RANDOM_DECIMAL") v_decimal(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "RANDOM_STRING") v_rstring(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "UNIQUE_STRING") v_ustring(t, rt, c, idx, k, p1, p2, CC_P3[t, cfgc])
    else if (rule == "UUID") v_uuid(t, rt, c, idx, k, p1)
    else if (rule == "LIST" || rule == "CYCLE") v_list(t, rt, c, idx, k, rule, r1, p2)
    else if (rule == "FIXED") v_fixed(t, rt, c, idx, k, r1, p2)
    else if (rule == "RANDOM_DATE") v_rdate(t, rt, c, idx, k, p1, p2)
    else if (rule == "RANDOM_DATETIME") v_rdatetime(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "RANDOM_TIME") v_rtime(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "SEQ_DATETIME") v_seqdt(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "REF") v_ref(t, rt, c, idx, k, p1, p2, p3)
    else if (rule == "RANDOM_BYTES") v_bytes(t, rt, c, idx, k, p1, p2)
    else if (rule == "COPY") { PA1[t, idx] = p1; if (p1 == "") err(t, c, "COPY のパラメータ1 にコピー元の列名を指定してください") }
    else if (rule == "NULL") { PDOM[t, idx] = 1 }
}

function allow(t, c, k, rule, kinds) {
    if (index(" " kinds " ", " " k " ") > 0) return 1
    err(t, c, "生成方式 " rule " はこの列のデータ型 (" k ") には使用できません")
    return 0
}

# 文字列系の列で値の長さ (文字数/バイト数) を検査
function check_len(t, rt, c, maxc, maxb, what) {
    if (C_KIND[rt, c] == "char" && maxc > C_CHARMAX[rt, c] + 0) { err(t, c, what "の最大長 " maxc " 文字が列の長さ " C_CHARMAX[rt, c] " を超えています"); return 0 }
    if ((C_KIND[rt, c] == "text" || C_KIND[rt, c] == "bin" || C_KIND[rt, c] == "blob") && maxb > C_OCTMAX[rt, c] + 0) { err(t, c, what "の最大長 " maxb " バイトが列の上限 " C_OCTMAX[rt, c] " バイトを超えています"); return 0 }
    return 1
}

# 数値 (2^53 以内の整数) の値域検査
function check_int_value(t, rt, c, v, what,    k, lim) {
    k = C_KIND[rt, c]
    if (k == "int" || k == "year" || k == "bit") {
        int_range(rt, c)
        if (int_cmp(v, IR_MIN) < 0 || int_cmp(v, IR_MAX) > 0) { err(t, c, what " " v " が列の範囲 (" IR_MIN "～" IR_MAX ") 外です"); return 0 }
        return 1
    }
    if (k == "dec" || k == "float") {
        lim = dec_int_limit(rt, c)
        if (lim >= 0 && dec_int_digits(v) > lim) { err(t, c, what " " v " の整数部が列の桁数 (" lim " 桁) を超えています"); return 0 }
        if (C_UNSIGNED[rt, c] && substr(norm_int(v), 1, 1) == "-") { err(t, c, what " " v " は UNSIGNED 列に設定できません"); return 0 }
        return 1
    }
    return 1
}

function v_seq(t, rt, c, idx, k, p1, p2, p3,    start, step, rep, last, auto, s) {
    if (!allow(t, c, k, "SEQ", "int dec float year bit char text bin blob")) return
    if (p2 == "") p2 = "1"; if (p3 == "") p3 = "1"
    if (!int_safe(p2) || p2 + 0 == 0) { err(t, c, "SEQ の増分 は 0 以外の整数で指定してください: " p2); return }
    if (!is_int_str(p3) || p3 + 0 < 1) { err(t, c, "SEQ の繰返し回数 は 1 以上の整数で指定してください: " p3); return }
    step = p2 + 0; rep = p3 + 0
    if (p1 == "") p1 = "1"
    auto = (toupper(p1) == "AUTO")
    if (auto) {
        if (k != "int" && k != "dec" && k != "float") { err(t, c, "開始値 AUTO は数値型の列でのみ使用できます"); return }
        if (CT_BEFORE[t] == "TRUNCATE" || CT_BEFORE[t] == "DELETE") start = 1
        else {
            req("MAX\t" tsv_escape(rt) "\t" tsv_escape(c))
            if (PHASE == 1) { start = 1 }
            else {
                if (!((rt, c) in RES_MAX)) { err(t, c, "開始値 AUTO の最大値を取得できませんでした", "R"); return }
                s = RES_MAX[rt, c]
                if (!int_safe(s)) { err(t, c, "既存の最大値 " s " が大きすぎるため AUTO を使用できません (2^53 以下が必要)", "R"); return }
                start = s + 1
            }
        }
    } else {
        if (!int_safe(p1)) { err(t, c, "SEQ の開始値 は整数 (2^53 以内) または AUTO を指定してください: " p1); return }
        start = p1 + 0
    }
    last = start + (int((ROWS[t] + rep - 1) / rep) - 1) * step
    if (ROWS[t] == 0) last = start
    if (last > TWO53 || last < -TWO53) { err(t, c, "連番の最終値 " sprintf("%.0f", last) " が扱える範囲 (±2^53) を超えます", auto ? "R" : ""); return }
    if (!check_int_value(t, rt, c, sprintf("%d", start), "連番の開始値")) return
    if (!check_int_value(t, rt, c, sprintf("%d", last), "連番の最終値")) return
    if (k == "char" || k == "text" || k == "bin" || k == "blob") {
        s = (digits_of(start) > digits_of(last)) ? digits_of(start) : digits_of(last)
        check_len(t, rt, c, s, s, "連番")
        PMAXC[t, idx] = s
    }
    if (k == "bin" || k == "blob") POUT[t, idx] = "b"
    PA1[t, idx] = sprintf("%d", start); PA2[t, idx] = sprintf("%d", step); PA3[t, idx] = rep
    PUNIQ[t, idx] = (rep == 1); PDOM[t, idx] = int((ROWS[t] + rep - 1) / rep)
    SEQ_START[t, idx] = start; SEQ_LAST[t, idx] = last; SEQ_STEP[t, idx] = step; SEQ_AUTO[t, idx] = auto
    if (rep == 1 && !auto && CT_BEFORE[t] == "NONE" && (k == "int" || k == "dec" || k == "float") && column_unique(rt, c) && ROWS[t] > 0) {
        req("RANGE\t" tsv_escape(rt) "\t" tsv_escape(c) "\t" sprintf("%d", (start < last) ? start : last) "\t" sprintf("%d", (start < last) ? last : start) "\t" sprintf("%d", start) "\t" sprintf("%d", step))
        if (PHASE == 2 && ((rt, c) in RES_RANGE) && RES_RANGE[rt, c] + 0 > 0)
            err(t, c, "生成する連番の範囲に既存データが " RES_RANGE[rt, c] " 件あり一意制約に違反します (開始値を AUTO にするか、事前処理を TRUNCATE にしてください)", "R")
    }
}

function column_unique(rt, c) { column_index_info(rt, c); return COL_SOLE_UNIQUE }

function v_template(t, rt, c, idx, k, tpl, p2, p3,    key, msg, n, j, typ, maxc, maxb, cs, start, step, last, hasseq, fixedlen, w, lv, m, l, b, bad, cl) {
    if (!allow(t, c, k, "TEMPLATE", "char text json bin blob")) return
    if (tpl == "") { err(t, c, "TEMPLATE のパラメータ1 にテンプレートを指定してください"); return }
    key = "V" t SUBSEP idx
    msg = tpl_parse(tpl, key)
    if (msg != "") { err(t, c, msg); return }
    if (p2 == "") p2 = "1"; if (p3 == "") p3 = "1"
    if (!int_safe(p2)) { err(t, c, "TEMPLATE の連番開始値 は整数で指定してください: " p2); return }
    if (!int_safe(p3) || p3 + 0 == 0) { err(t, c, "TEMPLATE の連番増分 は 0 以外の整数で指定してください: " p3); return }
    start = p2 + 0; step = p3 + 0; last = start + (ROWS[t] > 0 ? ROWS[t] - 1 : 0) * step
    if (last > TWO53 || last < -TWO53) { err(t, c, "連番の最終値が扱える範囲 (±2^53) を超えます"); return }
    cs = (k == "bin" || k == "blob") ? "binary" : C_CS[rt, c]
    maxc = 0; maxb = 0; hasseq = 0; fixedlen = 1
    n = TP_N[key]
    for (j = 1; j <= n; j++) {
        typ = TP_T[key, j]
        if (typ == "lit") {
            maxc += u8len(TP_A1[key, j]); maxb += cs_str_bytes(TP_A1[key, j], cs)
            bad = cs_unrepresentable(TP_A1[key, j], cs)
            if (bad != "") { err(t, c, "テンプレートの文字 '" bad "' は列の文字コード " cs " で表現できません"); return }
        } else if (typ == "seq") {
            hasseq = 1; w = TP_A1[key, j]
            l = (digits_of(start) > digits_of(last)) ? digits_of(start) : digits_of(last)
            if (w > l) l = w
            maxc += l; maxb += l
        } else if (typ == "int") {
            w = TP_A3[key, j]
            l = (digits_of(TP_A1[key, j]) > digits_of(TP_A2[key, j])) ? digits_of(TP_A1[key, j]) : digits_of(TP_A2[key, j])
            if (TP_A1[key, j] < 0 || digits_of(TP_A1[key, j]) != digits_of(TP_A2[key, j]) && w < l) fixedlen = 0
            if (w > l) l = w
            maxc += l; maxb += l
        } else if (typ == "cls") {
            cl = TP_A1[key, j]
            if ((cl in CLS_JP) && cs_family(cs) != "uni4" && cs_family(cs) != "uni3" && cs_family(cs) != "jp" && cs != "binary") { err(t, c, "文字種 " cl " は列の文字コード " cs " では使用できません"); return }
            if (TP_A2[key, j] != TP_A3[key, j]) fixedlen = 0
            maxc += TP_A3[key, j]; maxb += TP_A3[key, j] * cls_max_bytes(cl, cs)
        } else if (typ == "list") {
            m = 0; b = 0
            for (l = 1; l <= TP_LN[key, j]; l++) {
                lv = TP_L[key, j, l]
                if (u8len(lv) > m) m = u8len(lv)
                if (cs_str_bytes(lv, cs) > b) b = cs_str_bytes(lv, cs)
                if (l > 1 && u8len(lv) != u8len(TP_L[key, j, 1])) fixedlen = 0
                bad = cs_unrepresentable(lv, cs)
                if (bad != "") { err(t, c, "テンプレートの文字 '" bad "' は列の文字コード " cs " で表現できません"); return }
            }
            maxc += m; maxb += b
        } else if (typ == "uuid") { maxc += 36; maxb += 36 }
    }
    if (!check_len(t, rt, c, maxc, maxb, "テンプレート")) return
    PMAXC[t, idx] = maxc; PMAXB[t, idx] = maxb
    PA1[t, idx] = tpl; PA2[t, idx] = sprintf("%d", start); PA3[t, idx] = sprintf("%d", step)
    if (k == "bin" || k == "blob") POUT[t, idx] = "b"
    PUNIQ[t, idx] = (hasseq && fixedlen)
    PDOM[t, idx] = hasseq ? -1 : tpl_domain(key)
    if (k == "json") info(t, c, "JSON 列のテンプレートは生成結果が正しい JSON になるよう注意してください (不正な JSON はロード時にエラーになります)")
}

# テンプレートが取りうる値の数 (概算, 上限 1e300)
function tpl_domain(key,    n, j, d, typ, x) {
    d = 1; n = TP_N[key]
    for (j = 1; j <= n; j++) {
        typ = TP_T[key, j]
        if (typ == "int") x = TP_A2[key, j] - TP_A1[key, j] + 1
        else if (typ == "cls") x = (TP_A3[key, j] * log(CLS_N[TP_A1[key, j]]) > 690) ? 1e300 : CLS_N[TP_A1[key, j]] ^ TP_A3[key, j]
        else if (typ == "list") x = TP_LN[key, j]
        else if (typ == "uuid") x = 1e36
        else x = 1
        d = (d > 1e300 / (x < 1 ? 1 : x)) ? 1e300 : d * x
    }
    return d
}

function v_int(t, rt, c, idx, k, rule, p1, p2,    lo, hi, s) {
    if (!allow(t, c, k, rule, "int dec float year bit char text")) return
    if (!int_safe(p1) || !int_safe(p2)) { err(t, c, rule " の最小値/最大値は整数 (±2^53 以内) で指定してください: " p1 " / " p2); return }
    lo = p1 + 0; hi = p2 + 0
    if (lo > hi) { err(t, c, rule " の最小値が最大値より大きくなっています"); return }
    if (!check_int_value(t, rt, c, norm_int(p1), "最小値")) return
    if (!check_int_value(t, rt, c, norm_int(p2), "最大値")) return
    if (k == "char" || k == "text") {
        s = (digits_of(lo) > digits_of(hi)) ? digits_of(lo) : digits_of(hi)
        if (!check_len(t, rt, c, s, s, "数値")) return
        PMAXC[t, idx] = s
    }
    PA1[t, idx] = sprintf("%d", lo)
    if (rule == "RANDOM_INT") { PA2[t, idx] = sprintf("%d", hi); PDOM[t, idx] = hi - lo + 1; return }
    if (hi - lo + 1 > TWO52) { err(t, c, "UNIQUE_INT の値域 (最大値-最小値+1) は 2^52 以下にしてください"); return }
    if (ROWS[t] > hi - lo + 1) { err(t, c, "UNIQUE_INT の値域 " sprintf("%d", hi - lo + 1) " 件が生成件数 " ROWS[t] " より少ないため重複しない値を作れません"); return }
    PA2[t, idx] = sprintf("%d", hi - lo + 1); PUNIQ[t, idx] = 1
}

# 10進文字列 → 10^scale 倍の整数 (小数部が scale 桁を超える場合は "")
function dec_scaled(s, scale,    neg, ip, fp) {
    neg = 0
    if (substr(s, 1, 1) == "+") s = substr(s, 2); else if (substr(s, 1, 1) == "-") { neg = 1; s = substr(s, 2) }
    ip = s; fp = ""
    if (index(s, ".") > 0) { ip = substr(s, 1, index(s, ".") - 1); fp = substr(s, index(s, ".") + 1) }
    sub(/0+$/, "", fp)
    if (length(fp) > scale) return ""
    while (length(fp) < scale) fp = fp "0"
    s = ip fp; sub(/^0+/, "", s); if (s == "") s = "0"
    if (!int_safe(s)) return "X"
    return (neg && s != "0" ? "-" : "") s
}

function v_decimal(t, rt, c, idx, k, p1, p2, p3,    scale, lo, hi, lim, s) {
    if (!allow(t, c, k, "RANDOM_DECIMAL", "dec float char text")) return
    if (p3 == "") p3 = (k == "dec" || k == "float" && C_CT[rt, c] ~ /\(/) ? C_SCALE[rt, c] + 0 : 2
    if (!is_int_str(p3) || p3 + 0 < 0 || p3 + 0 > 30) { err(t, c, "RANDOM_DECIMAL の小数桁数 は 0～30 の整数で指定してください: " p3); return }
    scale = p3 + 0
    if (k == "dec" && scale > C_SCALE[rt, c] + 0) { err(t, c, "小数桁数 " scale " が列の小数桁数 " C_SCALE[rt, c] " を超えています"); return }
    if (!is_dec_str(p1) || !is_dec_str(p2)) { err(t, c, "RANDOM_DECIMAL の最小値/最大値は10進数で指定してください: " p1 " / " p2); return }
    lo = dec_scaled(p1, scale); hi = dec_scaled(p2, scale)
    if (lo == "" || hi == "") { err(t, c, "最小値/最大値の小数部が小数桁数 " scale " 桁を超えています"); return }
    if (lo == "X" || hi == "X") { err(t, c, "最小値/最大値 × 10^小数桁数 が扱える範囲 (2^53) を超えます"); return }
    if (lo + 0 > hi + 0) { err(t, c, "RANDOM_DECIMAL の最小値が最大値より大きくなっています"); return }
    if (k == "dec" || k == "float") {
        lim = dec_int_limit(rt, c)
        if (lim >= 0 && (dec_int_digits(p1) > lim || dec_int_digits(p2) > lim)) { err(t, c, "最小値/最大値の整数部が列の桁数 (" lim " 桁) を超えています"); return }
        if (C_UNSIGNED[rt, c] && (lo + 0 < 0)) { err(t, c, "UNSIGNED 列に負の値は設定できません"); return }
        if (k == "float" && C_DT[rt, c] == "float" && (p1 + 0 > 3.4028234e38 || p1 + 0 < -3.4028234e38 || p2 + 0 > 3.4028234e38 || p2 + 0 < -3.4028234e38)) { err(t, c, "FLOAT の範囲を超えています"); return }
    } else {
        s = (digits_of(int(p1 + 0)) > digits_of(int(p2 + 0)) ? digits_of(int(p1 + 0)) : digits_of(int(p2 + 0))) + (scale > 0 ? scale + 1 : 0) + 1
        if (!check_len(t, rt, c, s, s, "数値")) return
        PMAXC[t, idx] = s
    }
    PA1[t, idx] = lo; PA2[t, idx] = hi; PA3[t, idx] = scale; PDOM[t, idx] = hi - lo + 1
}

function v_rstring(t, rt, c, idx, k, p1, p2, p3,    mn, mx, cls, cs, eff, L, d) {
    if (!allow(t, c, k, "RANDOM_STRING", "char text bin blob")) return
    if (p3 == "") p3 = "alnum"
    cls = tolower(p3)
    if (!is_class(cls)) { err(t, c, "文字種が不正です: " p3 " (digit/upper/lower/alpha/alnum/hex/hexupper/ascii/hira/kata/hankana/kanji/zenkaku)"); return }
    if (!is_int_str(p1) || !is_int_str(p2) || p1 + 0 < 0 || p1 + 0 > p2 + 0 || p2 + 0 > 16777215) { err(t, c, "RANDOM_STRING の最小長/最大長が不正です: " p1 " / " p2); return }
    mn = p1 + 0; mx = p2 + 0
    cs = (k == "bin" || k == "blob") ? "binary" : C_CS[rt, c]
    if ((cls in CLS_JP) && cs != "binary" && cs_family(cs) != "uni4" && cs_family(cs) != "uni3" && cs_family(cs) != "jp") { err(t, c, "文字種 " cls " は列の文字コード " cs " では使用できません"); return }
    if (!check_len(t, rt, c, mx, mx * cls_max_bytes(cls, cs), "文字列")) return
    PMAXC[t, idx] = mx; PMAXB[t, idx] = mx * cls_max_bytes(cls, cs)
    if (k == "bin" || k == "blob") POUT[t, idx] = "b"
    PA1[t, idx] = mn; PA2[t, idx] = mx; PA3[t, idx] = cls
    eff = CLS_N[cls]
    if (C_COLL[rt, c] ~ /_ci$/) { if (cls == "alpha") eff = 26; else if (cls == "alnum") eff = 36; else if (cls == "zenkaku" || cls == "hira" || cls == "kata") eff = int(eff / 2) }
    d = 0
    for (L = mn; L <= mx && d < 1e300; L++) d += (L * log(eff) > 690) ? 1e300 : eff ^ L
    PDOM[t, idx] = d
}

function v_ustring(t, rt, c, idx, k, p1, p2, prefix,    L, cls, cs, n, kk, kmax, pw, total) {
    if (!allow(t, c, k, "UNIQUE_STRING", "char text bin blob")) return
    if (!is_int_str(p1) || p1 + 0 < 1 || p1 + 0 > 10000) { err(t, c, "UNIQUE_STRING の長さ は 1 以上の整数で指定してください: " p1); return }
    if (p2 == "") p2 = "alnum"
    cls = tolower(p2)
    if (index(UNIQ_CLASSES, " " cls " ") == 0) { err(t, c, "UNIQUE_STRING の文字種は digit/upper/lower/alpha/alnum/hex/hexupper のいずれかです: " p2); return }
    if (C_COLL[rt, c] ~ /_ci$/ && (cls == "alpha" || cls == "alnum")) {
        warn(t, c, "照合順序 " C_COLL[rt, c] " は大文字小文字を区別しないため、文字種 " cls " を " (cls == "alpha" ? "upper" : "alnumupper (数字+英大文字)") " に変更して生成します")
        cls = (cls == "alpha") ? "upper" : "alnumupper"
    }
    L = p1 + 0; n = CLS_N[cls]
    kmax = 0; pw = 1
    while (pw * n <= TWO52 && kmax < L) { pw *= n; kmax++ }
    if (pw < ROWS[t]) { err(t, c, "長さ " L " の " cls " では " ROWS[t] " 件の一意な値を作れません (長さを増やしてください)"); return }
    cs = (k == "bin" || k == "blob") ? "binary" : C_CS[rt, c]
    if (cs_unrepresentable(prefix, cs) != "") { err(t, c, "接頭辞の文字 '" cs_unrepresentable(prefix, cs) "' は列の文字コード " cs " で表現できません"); return }
    total = u8len(prefix) + L
    if (!check_len(t, rt, c, total, cs_str_bytes(prefix, cs) + L, "文字列")) return
    PMAXC[t, idx] = total
    if (k == "bin" || k == "blob") POUT[t, idx] = "b"
    PA1[t, idx] = L; PA2[t, idx] = cls; PA3[t, idx] = prefix; PA4[t, idx] = kmax; PUNIQ[t, idx] = 1
}

function v_uuid(t, rt, c, idx, k, p1,    fmt, need) {
    if (!allow(t, c, k, "UUID", "char text bin blob")) return
    fmt = toupper(p1); if (fmt == "") fmt = "STD"
    if (k == "bin" || k == "blob") {
        if (C_OCTMAX[rt, c] + 0 < 16) { err(t, c, "UUID(バイナリ) には 16 バイト以上の列が必要です"); return }
        if (fmt != "STD" && fmt != "BINARY") warn(t, c, "バイナリ列のため UUID は 16 バイトのバイナリで生成します")
        fmt = "BINARY"; POUT[t, idx] = "h"
    } else {
        if (fmt != "STD" && fmt != "UPPER" && fmt != "NOHYPHEN") { err(t, c, "UUID の形式は STD / UPPER / NOHYPHEN のいずれかです: " p1); return }
        need = (fmt == "NOHYPHEN") ? 32 : 36
        if (!check_len(t, rt, c, need, need, "UUID")) return
        PMAXC[t, idx] = need
    }
    if (ROWS[t] > 281474976710656) { err(t, c, "UUID の一意生成は 2^48 件までです"); return }
    PA1[t, idx] = fmt; PUNIQ[t, idx] = 1
}

# 1つの値を列の型で検査・正規化 (成功時 CV に正規化値を設定して "" を返す)
function check_value(t, rt, c, v, what,    k, s, d, frac, fsp, n, ev, i, m, parts, ok, bad, cs) {
    k = C_KIND[rt, c]; CV = v
    if (k == "int" || k == "year") {
        if (!is_int_str(v)) return what "は整数で指定してください: " v
        int_range(rt, c)
        if (int_cmp(v, IR_MIN) < 0 || int_cmp(v, IR_MAX) > 0) return what " " v " が列の範囲 (" IR_MIN "～" IR_MAX ") 外です"
        CV = norm_int(v); return ""
    }
    if (k == "bit") {
        if (v ~ /^[bB]'[01]+'$/) {
            s = substr(v, 3, length(v) - 3)
            if (length(s) > 53) return what "の b'...' 表記は 53 ビットまでです"
            d = 0; for (i = 1; i <= length(s); i++) d = d * 2 + (substr(s, i, 1) == "1")
            v = sprintf("%d", d)
        }
        if (!is_int_str(v)) return what "は整数または b'0101' 形式で指定してください: " v
        int_range(rt, c)
        if (int_cmp(v, IR_MIN) < 0 || int_cmp(v, IR_MAX) > 0) return what " " v " が列の範囲 (" IR_MIN "～" IR_MAX ") 外です"
        CV = norm_int(v); return ""
    }
    if (k == "dec") {
        if (!is_dec_str(v)) return what "は10進数で指定してください: " v
        if (dec_int_digits(v) > C_PREC[rt, c] - C_SCALE[rt, c]) return what " " v " の整数部が列の桁数を超えています"
        if (dec_frac_digits(v) > C_SCALE[rt, c] + 0) return what " " v " の小数部が列の小数桁数 " C_SCALE[rt, c] " を超えています"
        if (C_UNSIGNED[rt, c] && v ~ /^-/ && v + 0 != 0) return what " " v " は UNSIGNED 列に設定できません"
        CV = v; sub(/^\+/, "", CV); return ""
    }
    if (k == "float") {
        if (!is_float_str(v)) return what "は数値で指定してください: " v
        if (C_DT[rt, c] == "float" && (v + 0 > 3.4028234e38 || v + 0 < -3.4028234e38)) return what " " v " が FLOAT の範囲外です"
        if (dec_int_limit(rt, c) >= 0 && v !~ /[eE]/ && dec_int_digits(v) > dec_int_limit(rt, c)) return what " " v " の整数部が列の桁数を超えています"
        if (C_UNSIGNED[rt, c] && v + 0 < 0) return what " " v " は UNSIGNED 列に設定できません"
        CV = v; sub(/^\+/, "", CV); return ""
    }
    if (k == "date") {
        d = date_value(v)
        if (d == "") return (REL_ERR != "" ? REL_ERR : what "は日付 (YYYY-MM-DD) で指定してください: " v)
        if (d < -354285 || d > 2932896) return what " " v " が DATE の範囲 (1000-01-01～9999-12-31) 外です"
        CV = fmt_date(d); return ""
    }
    if (k == "datetime" || k == "timestamp") {
        s = dt_value(v)
        if (s == "") return (REL_ERR != "" ? REL_ERR : what "は日時 (YYYY-MM-DD HH:MM:SS) で指定してください: " v)
        fsp = C_DTPREC[rt, c] + 0
        if (length(DTV_FRAC) > fsp) return what " " v " の小数秒の桁数が列の精度 (" fsp ") を超えています"
        if (!dt_in_range(k, s)) return what " " v " が " toupper(k) " の範囲外です"
        CV = fmt_dt(s) (DTV_FRAC != "" ? "." DTV_FRAC : ""); return ""
    }
    if (k == "time") {
        s = parse_time(v)
        if (s == "") return what "は時刻 ([-]HH:MM:SS) で指定してください: " v
        if (length(PDT_FRAC) > C_DTPREC[rt, c] + 0) return what " " v " の小数秒の桁数が列の精度を超えています"
        CV = v; return ""
    }
    if (k == "enum") {
        n = enum_values(C_CT[rt, c], ev)
        for (i = 1; i <= n; i++) if (ev[i] == v) return ""
        return what " '" v "' は ENUM の値 (" C_CT[rt, c] ") に含まれません"
    }
    if (k == "set") {
        n = enum_values(C_CT[rt, c], ev)
        if (v == "") return ""
        m = split(v, parts, ",")
        for (i = 1; i <= m; i++) { ok = 0; for (d = 1; d <= n; d++) if (ev[d] == parts[i]) ok = 1; if (!ok) return what " '" parts[i] "' は SET の要素 (" C_CT[rt, c] ") に含まれません" }
        return ""
    }
    if (k == "char" || k == "text" || k == "json") {
        cs = C_CS[rt, c]
        bad = cs_unrepresentable(v, cs)
        if (bad != "") return what "の文字 '" bad "' は列の文字コード " cs " で表現できません"
        if (index(v, sprintf("%c", 0)) > 0) return what "に NUL 文字は使用できません"
        if (k == "char" && u8len(v) > C_CHARMAX[rt, c] + 0) return what "の長さ " u8len(v) " 文字が列の長さ " C_CHARMAX[rt, c] " を超えています"
        if (k == "text" && cs_str_bytes(v, cs) > C_OCTMAX[rt, c] + 0) return what "の長さが列の上限 " C_OCTMAX[rt, c] " バイトを超えています"
        return ""
    }
    if (k == "bin" || k == "blob") {
        if (v ~ /^0[xX]([0-9A-Fa-f][0-9A-Fa-f])*$/) CV = toupper(substr(v, 3))
        else CV = hex_of_bytes(v)
        if (length(CV) / 2 > C_OCTMAX[rt, c] + 0) return what "の長さ " length(CV) / 2 " バイトが列の上限 " C_OCTMAX[rt, c] " バイトを超えています"
        return ""
    }
    return what "はこのデータ型では使用できません"
}

# 日付値 (絶対/相対) → 日数
function date_value(v,    d) {
    REL_ERR = ""
    d = parse_rel(v, "date"); if (d != "" || REL_ERR != "") return d
    d = parse_date(v); if (d != "") return d
    d = parse_datetime(v); if (d != "") return int(d / 86400)
    return ""
}

# 日時値 (絶対/相対) → 秒 (小数秒は DTV_FRAC)
function dt_value(v,    s) {
    REL_ERR = ""; DTV_FRAC = ""
    s = parse_rel(v, "dt"); if (s != "" || REL_ERR != "") return s
    s = parse_datetime(v); if (s == "") return ""
    DTV_FRAC = PDT_FRAC
    return s
}

# TIMESTAMP はタイムゾーン差を考慮して安全側の範囲で判定
function dt_in_range(k, s) {
    if (k == "timestamp") return (s >= 86400 && s <= 2147385600)
    return (s >= -30610224000 && s <= 253402300799)
}

function v_list(t, rt, c, idx, k, rule, raw, p2,    n, vals, i, j, a, b, m, total, w, ws, nw, seen, key, cnt, lo, hi, s, xv) {
    if (k == "geo") { err(t, c, rule " は空間データ型には使用できません (FIXED を使用してください)"); return }
    if (raw == "") { err(t, c, rule " のパラメータ1 に値リストを指定してください (例: A|B|C, 1..100)"); return }
    n = split_list(raw, vals)
    # 範囲 "a..b" の単独指定 → 数値の範囲として扱う
    if (n == 1 && vals[1] ~ /^[+-]?[0-9]+\.\.[+-]?[0-9]+$/ && (k == "int" || k == "dec" || k == "float" || k == "year" || k == "bit" || k == "char" || k == "text")) {
        a = vals[1]; sub(/\.\..*$/, "", a); b = vals[1]; sub(/^.*\.\./, "", b)
        if (!int_safe(a) || !int_safe(b)) { err(t, c, "範囲指定の値が扱える範囲 (±2^53) を超えます: " vals[1]); return }
        lo = (a + 0 < b + 0) ? a + 0 : b + 0; hi = (a + 0 < b + 0) ? b + 0 : a + 0
        if (!check_int_value(t, rt, c, sprintf("%d", lo), "範囲の値")) return
        if (!check_int_value(t, rt, c, sprintf("%d", hi), "範囲の値")) return
        if (k == "char" || k == "text") { s = (digits_of(lo) > digits_of(hi)) ? digits_of(lo) : digits_of(hi); if (!check_len(t, rt, c, s, s, "数値")) return; PMAXC[t, idx] = s }
        if (rule == "LIST") { PRULE[t, idx] = "RANDOM_INT"; PA1[t, idx] = sprintf("%d", lo); PA2[t, idx] = sprintf("%d", hi); PDOM[t, idx] = hi - lo + 1; return }
        if (p2 == "") p2 = "1"
        if (!is_int_str(p2) || p2 + 0 < 1) { err(t, c, "CYCLE の繰返し回数 は 1 以上の整数で指定してください: " p2); return }
        PRULE[t, idx] = "CYCLE_RANGE"; PA1[t, idx] = a + 0; PA2[t, idx] = hi - lo + 1; PA3[t, idx] = p2 + 0; PA4[t, idx] = (a + 0 <= b + 0) ? 1 : -1
        PUNIQ[t, idx] = (p2 + 0 == 1 && ROWS[t] <= hi - lo + 1); PDOM[t, idx] = hi - lo + 1
        CYC_N[t, idx] = hi - lo + 1; CYC_REP[t, idx] = p2 + 0
        return
    }
    # 範囲を展開
    total = 0
    for (i = 1; i <= n; i++) {
        if (vals[i] ~ /^[+-]?[0-9]+\.\.[+-]?[0-9]+$/ && k != "enum" && k != "set" && k != "char" && k != "text" && k != "json") {
            a = vals[i]; sub(/\.\..*$/, "", a); b = vals[i]; sub(/^.*\.\./, "", b)
            if (!int_safe(a) || !int_safe(b) || (b - a > 100000) || (a - b > 100000)) { err(t, c, "範囲指定 " vals[i] " が大きすぎます (リスト内では 100000 件まで)"); return }
            if (a + 0 <= b + 0) for (j = a + 0; j <= b + 0; j++) xv[++total] = sprintf("%d", j)
            else for (j = a + 0; j >= b + 0; j--) xv[++total] = sprintf("%d", j)
        } else xv[++total] = vals[i]
        if (total > 100000) { err(t, c, "値リストは 100000 件までです"); return }
    }
    m = 0; cnt = 0
    for (i = 1; i <= total; i++) {
        s = check_value(t, rt, c, xv[i], "値 " i)
        if (s != "") { err(t, c, s); return }
        PV[t, idx, i] = CV
        if (u8len(CV) > m) m = u8len(CV)
        key = (C_COLL[rt, c] ~ /_ci$/) ? tolower(CV) : CV
        if (!(key in seen)) { seen[key] = 1; cnt++ }
        if (k == "json") req("JSON\t" tsv_escape(rt) "\t" tsv_escape(c) "\t" i "\t" tsv_escape(CV))
        if (k == "json" && PHASE == 2 && ((rt, c, i) in RES_JSON) && RES_JSON[rt, c, i] != "1") { err(t, c, "値 " i " が正しい JSON ではありません: " CV, "R"); return }
    }
    PNV[t, idx] = total; PMAXC[t, idx] = m; PDOM[t, idx] = cnt
    if (k == "bin" || k == "blob") POUT[t, idx] = "h"
    for (i = 1; i <= total; i++) PW[t, idx, i] = 0
    if (rule == "LIST" && p2 != "") {
        nw = split_list(p2, ws)
        if (nw != total) { err(t, c, "重みの数 (" nw ") が値の数 (" total ") と一致しません"); return }
        w = 0
        for (i = 1; i <= nw; i++) {
            if (!is_dec_str(trim(ws[i])) || trim(ws[i]) + 0 < 0) { err(t, c, "重みは 0 以上の数値で指定してください: " ws[i]); return }
            w += trim(ws[i]) + 0; PW[t, idx, i] = w
        }
        if (w <= 0) { err(t, c, "重みの合計が 0 です"); return }
    }
    if (rule == "CYCLE") {
        if (p2 == "") p2 = "1"
        if (!is_int_str(p2) || p2 + 0 < 1) { err(t, c, "CYCLE の繰返し回数 は 1 以上の整数で指定してください: " p2); return }
        PA2[t, idx] = p2 + 0
        PUNIQ[t, idx] = (p2 + 0 == 1 && ROWS[t] <= total && cnt == total)
        CYC_N[t, idx] = total; CYC_REP[t, idx] = p2 + 0
    }
}

function v_fixed(t, rt, c, idx, k, raw, p2,    s, srid) {
    if (k == "geo") {
        if (trim(raw) == "") { err(t, c, "空間データ型の FIXED にはパラメータ1 に WKT (例: POINT(139.7 35.6)) を指定してください"); return }
        srid = (p2 != "") ? p2 : ((C_SRS[rt, c] != "" && C_SRS[rt, c] != "NULL") ? C_SRS[rt, c] : "0")
        if (!is_int_str(srid) || srid + 0 < 0) { err(t, c, "SRID は 0 以上の整数で指定してください: " srid); return }
        if (C_SRS[rt, c] != "" && C_SRS[rt, c] != "NULL" && srid + 0 != C_SRS[rt, c] + 0) { err(t, c, "SRID " srid " が列の SRID " C_SRS[rt, c] " と一致しません"); return }
        req("WKT\t" tsv_escape(rt) "\t" tsv_escape(c) "\t" tsv_escape(trim(raw)) "\t" srid)
        PNV[t, idx] = 1; PV[t, idx, 1] = ""; PW[t, idx, 1] = 0; POUT[t, idx] = "h"; PDOM[t, idx] = 1
        if (PHASE == 2) {
            if (!((rt, c) in RES_WKT)) { err(t, c, "WKT の変換結果を取得できませんでした", "R"); return }
            if (RES_WKT[rt, c] != "OK") { err(t, c, "WKT を変換できません: " RES_WKT_V[rt, c], "R"); return }
            if (C_DT[rt, c] != "geometry" && tolower(RES_WKT_T[rt, c]) != C_DT[rt, c] && !(C_DT[rt, c] == "geomcollection" && tolower(RES_WKT_T[rt, c]) ~ /geomcollection|geometrycollection/)) { err(t, c, "WKT の型 (" RES_WKT_T[rt, c] ") が列の型 (" C_DT[rt, c] ") と一致しません", "R"); return }
            PV[t, idx, 1] = RES_WKT_V[rt, c]
        }
        return
    }
    s = check_value(t, rt, c, raw, "固定値")
    if (s != "") { err(t, c, s); return }
    if (k == "json") {
        req("JSON\t" tsv_escape(rt) "\t" tsv_escape(c) "\t1\t" tsv_escape(CV))
        if (PHASE == 2 && ((rt, c, 1) in RES_JSON) && RES_JSON[rt, c, 1] != "1") { err(t, c, "固定値が正しい JSON ではありません: " CV, "R"); return }
    }
    PNV[t, idx] = 1; PV[t, idx, 1] = CV; PW[t, idx, 1] = 0; PDOM[t, idx] = 1; PMAXC[t, idx] = u8len(CV)
    if (k == "bin" || k == "blob") POUT[t, idx] = "h"
}

function v_rdate(t, rt, c, idx, k, p1, p2,    lo, hi) {
    if (!allow(t, c, k, "RANDOM_DATE", "date datetime timestamp char text")) return
    if (p1 == "") p1 = "TODAY-365"; if (p2 == "") p2 = "TODAY"
    lo = date_value(p1); if (lo == "") { err(t, c, (REL_ERR != "" ? REL_ERR : "開始日の書式が不正です: " p1)); return }
    hi = date_value(p2); if (hi == "") { err(t, c, (REL_ERR != "" ? REL_ERR : "終了日の書式が不正です: " p2)); return }
    if (lo > hi) { err(t, c, "開始日 " fmt_date(lo) " が終了日 " fmt_date(hi) " より後です"); return }
    if (k == "timestamp" && !(dt_in_range(k, lo * 86400) && dt_in_range(k, hi * 86400))) { err(t, c, "TIMESTAMP の範囲 (1970-01-02～2038-01-18) 外の日付が含まれます"); return }
    if (!(dt_in_range("date", lo * 86400) && dt_in_range("date", hi * 86400))) { err(t, c, "日付の範囲 (1000-01-01～9999-12-31) 外です"); return }
    if ((k == "char" || k == "text") && !check_len(t, rt, c, 10, 10, "日付")) return
    PA1[t, idx] = lo; PA2[t, idx] = hi; PA3[t, idx] = (k == "datetime" || k == "timestamp") ? "dt" : "date"
    PDOM[t, idx] = hi - lo + 1; PMAXC[t, idx] = 10
}

function v_rdatetime(t, rt, c, idx, k, p1, p2, p3,    lo, hi, lof, hif, fsp, p, span, flags) {
    if (!allow(t, c, k, "RANDOM_DATETIME", "datetime timestamp date char text")) return
    if (p1 == "") p1 = "NOW-365d"; if (p2 == "") p2 = "NOW"
    if (p3 == "") p3 = (k == "datetime" || k == "timestamp") ? C_DTPREC[rt, c] + 0 : 0
    if (!is_int_str(p3) || p3 + 0 < 0 || p3 + 0 > 6) { err(t, c, "小数秒桁数 は 0～6 の整数で指定してください: " p3); return }
    fsp = p3 + 0
    if ((k == "datetime" || k == "timestamp") && fsp > C_DTPREC[rt, c] + 0) { err(t, c, "小数秒桁数 " fsp " が列の精度 " C_DTPREC[rt, c] " を超えています"); return }
    if (k == "date") fsp = 0
    lo = dt_value(p1); if (lo == "") { err(t, c, (REL_ERR != "" ? REL_ERR : "開始日時の書式が不正です: " p1)); return }
    lof = DTV_FRAC
    hi = dt_value(p2); if (hi == "") { err(t, c, (REL_ERR != "" ? REL_ERR : "終了日時の書式が不正です: " p2)); return }
    hif = DTV_FRAC
    if (length(lof) > fsp || length(hif) > fsp) { err(t, c, "開始/終了日時の小数秒の桁数が小数秒桁数 " fsp " を超えています"); return }
    p = pow10(fsp)
    while (length(lof) < fsp) lof = lof "0"; while (length(hif) < fsp) hif = hif "0"
    lof = lof + 0; hif = hif + 0
    if (lo * p + lof > hi * p + hif) { err(t, c, "開始日時が終了日時より後です"); return }
    if (!(dt_in_range(k == "timestamp" ? k : "datetime", lo) && dt_in_range(k == "timestamp" ? k : "datetime", hi))) { err(t, c, (k == "timestamp" ? "TIMESTAMP の範囲 (1970-01-02～2038-01-18)" : "DATETIME の範囲") " 外の日時が含まれます"); return }
    if (k == "char" || k == "text") { if (!check_len(t, rt, c, 19 + (fsp > 0 ? fsp + 1 : 0), 19 + (fsp > 0 ? fsp + 1 : 0), "日時")) return; PMAXC[t, idx] = 19 + (fsp > 0 ? fsp + 1 : 0) }
    span = (hi - lo) * p + (hif - lof)
    flags = (k == "date") ? "D" : ""
    if (span > TWO52) { flags = flags "W"; PA2[t, idx] = hi } else PA2[t, idx] = span
    PA1[t, idx] = lo; PA3[t, idx] = fsp; PA4[t, idx] = lof; PA5[t, idx] = flags
    PDOM[t, idx] = (k == "date") ? int(hi / 86400) - int(lo / 86400) + 1 : span + 1
}

function v_rtime(t, rt, c, idx, k, p1, p2, p3,    lo, hi, fsp, p, lof, hif, neg) {
    if (!allow(t, c, k, "RANDOM_TIME", "time char text")) return
    if (p1 == "") p1 = "00:00:00"; if (p2 == "") p2 = "23:59:59"
    if (p3 == "") p3 = (k == "time") ? C_DTPREC[rt, c] + 0 : 0
    if (!is_int_str(p3) || p3 + 0 < 0 || p3 + 0 > 6) { err(t, c, "小数秒桁数 は 0～6 の整数で指定してください: " p3); return }
    fsp = p3 + 0
    if (k == "time" && fsp > C_DTPREC[rt, c] + 0) { err(t, c, "小数秒桁数 " fsp " が列の精度 " C_DTPREC[rt, c] " を超えています"); return }
    p = pow10(fsp)
    lo = parse_time(p1); lof = PDT_FRAC; if (lo == "") { err(t, c, "開始時刻の書式が不正です ([-]HH:MM:SS): " p1); return }
    if (length(lof) > fsp) { err(t, c, "開始時刻の小数秒の桁数が小数秒桁数を超えています"); return }
    while (length(lof) < fsp) lof = lof "0"
    neg = (substr(p1, 1, 1) == "-"); lo = (neg ? -1 : 1) * ((neg ? -lo : lo) * p + lof)
    hi = parse_time(p2); hif = PDT_FRAC; if (hi == "") { err(t, c, "終了時刻の書式が不正です ([-]HH:MM:SS): " p2); return }
    if (length(hif) > fsp) { err(t, c, "終了時刻の小数秒の桁数が小数秒桁数を超えています"); return }
    while (length(hif) < fsp) hif = hif "0"
    neg = (substr(p2, 1, 1) == "-"); hi = (neg ? -1 : 1) * ((neg ? -hi : hi) * p + hif)
    if (lo > hi) { err(t, c, "開始時刻が終了時刻より後です"); return }
    if ((k == "char" || k == "text") && !check_len(t, rt, c, 10 + (fsp > 0 ? fsp + 1 : 0), 10 + (fsp > 0 ? fsp + 1 : 0), "時刻")) return
    PA1[t, idx] = lo; PA2[t, idx] = hi; PA3[t, idx] = fsp; PDOM[t, idx] = hi - lo + 1
    PMAXC[t, idx] = 10 + (fsp > 0 ? fsp + 1 : 0)
}

function v_seqdt(t, rt, c, idx, k, p1, p2, p3,    datemode, start, step, rep, n, unit, last, lim) {
    if (!allow(t, c, k, "SEQ_DATETIME", "date datetime timestamp char text")) return
    if (p1 == "") { err(t, c, "SEQ_DATETIME のパラメータ1 に開始日時を指定してください (例: 2026-01-01 00:00:00 / NOW / TODAY)"); return }
    datemode = (k == "date") || ((k == "char" || k == "text") && (parse_date(p1) != "" || toupper(p1) ~ /^TODAY/))
    if (p2 == "") p2 = datemode ? "1d" : "1s"
    if (p3 == "") p3 = "1"
    if (tolower(p2) !~ /^[+-]?[0-9]+[dhms]?$/) { err(t, c, "SEQ_DATETIME の増分は 1d / 12h / 30m / 10s の形式で指定してください: " p2); return }
    if (!is_int_str(p3) || p3 + 0 < 1) { err(t, c, "SEQ_DATETIME の繰返し回数 は 1 以上の整数で指定してください: " p3); return }
    rep = p3 + 0
    unit = tolower(substr(p2, length(p2), 1)); n = p2
    if (unit ~ /[0-9]/) unit = datemode ? "d" : "s"; else n = substr(p2, 1, length(p2) - 1)
    n = n + 0
    step = n * ((unit == "d") ? 86400 : (unit == "h") ? 3600 : (unit == "m") ? 60 : 1)
    if (step == 0) { err(t, c, "SEQ_DATETIME の増分に 0 は指定できません"); return }
    if (datemode) {
        if (step % 86400 != 0) { err(t, c, "日付の連番の増分は日単位 (例: 1d) で指定してください: " p2); return }
        start = date_value(p1); if (start == "") { err(t, c, (REL_ERR != "" ? REL_ERR : "開始日の書式が不正です: " p1)); return }
        step = step / 86400
        last = start + (int((ROWS[t] + rep - 1) / rep) - (ROWS[t] > 0 ? 1 : 0)) * step
        if (!(dt_in_range(k == "timestamp" ? k : "date", start * 86400) && dt_in_range(k == "timestamp" ? k : "date", last * 86400))) { err(t, c, "連番の日付 (" fmt_date(start) "～" fmt_date(last) ") が範囲外になります"); return }
        PA4[t, idx] = "date"; PMAXC[t, idx] = 10
    } else {
        start = dt_value(p1); if (start == "") { err(t, c, (REL_ERR != "" ? REL_ERR : "開始日時の書式が不正です: " p1)); return }
        if (DTV_FRAC != "" && DTV_FRAC + 0 != 0) { err(t, c, "SEQ_DATETIME の開始日時に小数秒は指定できません"); return }
        last = start + (int((ROWS[t] + rep - 1) / rep) - (ROWS[t] > 0 ? 1 : 0)) * step
        if (!(dt_in_range(k == "timestamp" ? k : "datetime", start) && dt_in_range(k == "timestamp" ? k : "datetime", last))) { err(t, c, "連番の日時 (" fmt_dt(start) "～" fmt_dt(last) ") が範囲外になります"); return }
        PA4[t, idx] = "dt"; PMAXC[t, idx] = 19
    }
    if ((k == "char" || k == "text") && !check_len(t, rt, c, PMAXC[t, idx], PMAXC[t, idx], "日時")) return
    PA1[t, idx] = start; PA2[t, idx] = step; PA3[t, idx] = rep
    PUNIQ[t, idx] = (rep == 1); PDOM[t, idx] = int((ROWS[t] + rep - 1) / rep)
}

function v_bytes(t, rt, c, idx, k, p1, p2) {
    if (!allow(t, c, k, "RANDOM_BYTES", "bin blob")) return
    if (!is_int_str(p1) || !is_int_str(p2) || p1 + 0 < 0 || p1 + 0 > p2 + 0) { err(t, c, "RANDOM_BYTES の最小/最大バイト数が不正です: " p1 " / " p2); return }
    if (p2 + 0 > C_OCTMAX[rt, c] + 0) { err(t, c, "最大バイト数 " p2 " が列の上限 " C_OCTMAX[rt, c] " を超えています"); return }
    if (p2 + 0 > 16777215) { err(t, c, "最大バイト数は 16777215 までです"); return }
    PA1[t, idx] = p1 + 0; PA2[t, idx] = p2 + 0; POUT[t, idx] = "h"
    PDOM[t, idx] = (p2 * log(256) > 690) ? 1e300 : 256 ^ p2
}

function v_ref(t, rt, c, idx, k, p1, p2, p3,    pt, pc, rpt, rpc, mode, rep, g, dot) {
    if (p1 == "" || index(p1, ".") == 0) { err(t, c, "REF のパラメータ1 に 参照先テーブル.列 を指定してください: " p1); return }
    dot = match(p1, /\.[^.]*$/)
    pt = substr(p1, 1, dot - 1); pc = substr(p1, dot + 1)
    rpt = real_table(pt)
    if (rpt == "") { err(t, c, "参照先テーブル " pt " がデータベースに存在しません"); return }
    rpc = real_column(rpt, pc)
    if (rpc == "") { err(t, c, "参照先の列 " pt "." pc " が存在しません"); return }
    if (rpt == rt) { err(t, c, "自分自身のテーブルは REF で参照できません (COPY / NULL などを使用してください)"); return }
    if (kind_out(C_KIND[rpt, rpc]) != kind_out(k)) { err(t, c, "参照先の列の型 (" C_CT[rpt, rpc] ") とこの列の型 (" C_CT[rt, c] ") の互換性がありません"); return }
    if (k == "char" && C_KIND[rpt, rpc] == "char" && C_CHARMAX[rpt, rpc] + 0 > C_CHARMAX[rt, c] + 0) warn(t, c, "参照先の列の長さ (" C_CHARMAX[rpt, rpc] ") がこの列 (" C_CHARMAX[rt, c] ") より長いため、値が収まらない場合があります")
    mode = toupper(p2); if (mode == "") mode = "RANDOM"
    rep = 1
    if (mode ~ /^SEQ:[0-9]+$/) { rep = substr(mode, 5) + 0; mode = "SEQ"; if (rep < 1) { err(t, c, "REF の SEQ:n の n は 1 以上を指定してください"); return } }
    else if (mode != "RANDOM" && mode != "SEQ") { err(t, c, "REF の選択方法は RANDOM / SEQ / SEQ:n のいずれかです: " p2); return }
    g = (p3 != "") ? "G:" p3 : "C:" c
    if ((t, g) in RG_PT) {
        if (RG_PT[t, g] != rpt) { err(t, c, "同じグループ " p3 " の REF は同じ参照先テーブルを指定してください"); return }
        if (RG_MODE[t, g] != mode || RG_REP[t, g] != rep) { err(t, c, "同じグループ " p3 " の REF は同じ選択方法を指定してください"); return }
    } else {
        RG_PT[t, g] = rpt; RG_MODE[t, g] = mode; RG_REP[t, g] = rep; RG_N[t]++; RG_LIST[t, RG_N[t]] = g; RG_NC[t, g] = 0
    }
    RG_NC[t, g]++; RG_COL[t, g, RG_NC[t, g]] = rpc; RG_CIDX[t, g, RG_NC[t, g]] = idx
    PA1[t, idx] = g; PA2[t, idx] = RG_NC[t, g]
    if (k == "char") PMAXC[t, idx] = C_CHARMAX[rpt, rpc] + 0
    if (k == "bin" || k == "blob" || k == "geo") POUT[t, idx] = "h"
}

# ---- テーブル単位の後処理 (REF 解決, 一意性, 後片付け方式) ----------------------------
function validate_table_post(t,    rt, n, idx, g, pt, src, key, i, cols, pi, prule, pidx, c, cnt) {
    rt = CT_REAL[t]
    # COPY の解決
    for (idx = 1; idx <= NPC[t]; idx++) {
        if (PRULE[t, idx] != "COPY") continue
        c = real_column(rt, PA1[t, idx])
        if (c == "" || !((t, c) in PIDX)) { err(t, PCOL[t, idx], "COPY 元の列 " PA1[t, idx] " がない、または DEFAULT のためコピーできません"); continue }
        i = PIDX[t, c]
        if (PRULE[t, i] == "COPY") { err(t, PCOL[t, idx], "COPY 元の列 " c " も COPY です (COPY の連鎖はできません)"); continue }
        if (POUT[t, i] != kind_out(C_KIND[rt, PCOL[t, idx]]) && kind_out(C_KIND[rt, PCOL[t, idx]]) != "s") { err(t, PCOL[t, idx], "COPY 元の列 " c " とデータ型の互換性がありません"); continue }
        if (C_KIND[rt, PCOL[t, idx]] == "char" && PMAXC[t, i] > C_CHARMAX[rt, PCOL[t, idx]] + 0) warn(t, PCOL[t, idx], "COPY 元の値が列の長さを超える可能性があります")
        PA1[t, idx] = i; PUNIQ[t, idx] = PUNIQ[t, i]; PDOM[t, idx] = PDOM[t, i]; POUT[t, idx] = kind_out(C_KIND[rt, PCOL[t, idx]]) == "h" ? "h" : POUT[t, idx]
        if (POUT[t, i] == "b" && POUT[t, idx] == "h") POUT[t, idx] = "b"
    }
    # REF のグループ解決
    for (n = 1; n <= RG_N[t]; n++) {
        g = RG_LIST[t, n]; pt = RG_PT[t, g]
        src = ""; pi = ""
        for (i = 1; i <= NORD; i++) if (CT_REAL[ORD[i]] == pt) { pi = ORD[i]; break }
        if (pi != "" && ROWS[pi] > 0) {
            if (ORDPOS[pi] >= ORDPOS[t]) { err(t, "", "REF の参照先 " pt " はこのテーブルより先に処理する必要があります (処理順を確認してください)"); continue }
            src = ref_source_from_config(t, g, pi)
        } else {
            cols = ""
            for (i = 1; i <= RG_NC[t, g]; i++) cols = cols "\t" tsv_escape(RG_COL[t, g, i])
            req("REFDB\t" tsv_escape(t "|" g) "\t" tsv_escape(pt) cols)
            src = "DB"
            if (PHASE == 2) {
                if (!((t "|" g) in RES_REF)) { err(t, "", "参照先 " pt " のキーを取得できませんでした", "R"); continue }
                if (RES_REF_CNT[t "|" g] + 0 == 0) { err(t, RG_COL_NAME(t, g), "参照先 " pt " にデータがありません (NULL 以外の値が 0 件)", "R"); continue }
                RGS_SRC[t, g] = RES_REF_SRC[t "|" g]; RGS_CNT[t, g] = RES_REF_CNT[t "|" g]
                RGS_START[t, g] = RES_REF_START[t "|" g]; RGS_STEP[t, g] = RES_REF_STEP[t "|" g]; RGS_FILE[t, g] = RES_REF_FILE[t "|" g]
            }
        }
        for (i = 1; i <= RG_NC[t, g]; i++) { idx = RG_CIDX[t, g, i]; PDOM[t, idx] = (RGS_CNT[t, g] + 0 > 0) ? RGS_CNT[t, g] + 0 : -1 }
        if (RGS_SRC[t, g] == "" && PHASE == 1) REF_PENDING[t] = 1
    }
    if (GLOBAL["fk_checks"] == "ON") {
        for (idx = 1; idx <= NPC[t]; idx++) {
            c = PCOL[t, idx]
            if (((rt, c) in C_FK) && PRULE[t, idx] !~ /^(REF|NULL|COPY)$/ && FK_RTBL[rt, C_FK[rt, c]] != rt)
                warn(t, c, "外部キー列ですが生成方式が " PRULE[t, idx] " です。参照先に存在しない値はロード時にエラーになります (REF の使用を推奨)")
        }
    }
    check_uniques(t, rt)
    choose_delete_key(t, rt)
}

function RG_COL_NAME(t, g) { return PCOL[t, RG_CIDX[t, g, 1]] }

# 参照先が同じ設定内で生成される場合のキー供給方法
function ref_source_from_config(t, g, pt,    i, prc, pidx, prule, tpl, key, j, ok) {
    RGS_CNT[t, g] = ROWS[pt]
    if (RG_NC[t, g] == 1) {
        prc = RG_COL[t, g, 1]
        if (!((pt, prc) in PIDX)) {
            if (MODE == "prepare") { RGS_SRC[t, g] = "LATE"; RGS_PT[t, g] = pt; RGS_CNT[t, g] = 0; return "LATE" }
            err(t, RG_COL_NAME(t, g), "参照先 " pt "." prc " は DEFAULT (DB 採番) のため、generate では参照値を決められません (prepare では実行できます)")
            return ""
        }
        pidx = PIDX[pt, prc]; prule = PRULE[pt, pidx]
        if (prule == "SEQ" && PA3[pt, pidx] + 0 == 1 && PNULL[pt, pidx] == 0) {
            RGS_SRC[t, g] = "ARITH"; RGS_START[t, g] = PA1[pt, pidx]; RGS_STEP[t, g] = PA2[pt, pidx]; return "ARITH"
        }
        if (prule == "TEMPLATE" && PNULL[pt, pidx] == 0) {
            key = "V" pt SUBSEP pidx; ok = 1
            for (j = 1; j <= TP_N[key]; j++) if (TP_T[key, j] != "lit" && TP_T[key, j] != "seq") ok = 0
            if (ok) { RGS_SRC[t, g] = "TPL"; RGS_START[t, g] = PA2[pt, pidx]; RGS_STEP[t, g] = PA3[pt, pidx]; RGS_FILE[t, g] = PA1[pt, pidx]; return "TPL" }
        }
    }
    for (i = 1; i <= RG_NC[t, g]; i++) {
        prc = RG_COL[t, g, i]
        if (!((pt, prc) in PIDX)) {
            if (MODE == "prepare") { RGS_SRC[t, g] = "LATE"; RGS_PT[t, g] = pt; RGS_CNT[t, g] = 0; return "LATE" }
            err(t, RG_COL_NAME(t, g), "参照先 " pt "." prc " は DEFAULT (DB 採番) のため、generate では参照値を決められません (prepare では実行できます)")
            return ""
        }
        RGS_PCOLS[t, g] = RGS_PCOLS[t, g] (i > 1 ? "," : "") PIDX[pt, prc]
    }
    RGS_SRC[t, g] = "PCSV"; RGS_PT[t, g] = pt; RGS_CNT[t, g] = 0
    return "PCSV"
}

# 一意インデックスごとに重複の可能性を判定
function check_uniques(t, rt,    n, k, i, c, idx, guaranteed, nn, prob, dom, rows, aidx, desc, r, cidx, okpat, j, ref_ok) {
    rows = ROWS[t]
    if (rows <= 1) return
    if (REF_PENDING[t]) return      # 参照キー件数が未確定 (PHASE2 で判定)
    for (n = 1; n <= T_NIDX[rt]; n++) {
        k = IDX_LIST[rt, n]
        if (!I_UNIQUE[rt, k]) continue
        desc = (k == "PRIMARY") ? "主キー" : "一意キー " k
        if (I_FUNC[rt, k]) { warn(t, "", desc " は関数インデックスのため一意性を検証できません"); continue }
        guaranteed = 0; dom = 1; nn = 0
        for (i = 1; i <= I_NCOL[rt, k]; i++) {
            c = I_COL[rt, k, i]
            if (C_GEN[rt, c]) { dom = -1; continue }
            if (!((t, c) in PIDX)) { if (C_AUTOINC[rt, c]) guaranteed = 1; else dom = -1; continue }
            idx = PIDX[t, c]
            if (PUNIQ[t, idx]) guaranteed = 1
            if (PDOM[t, idx] < 0 || dom < 0) dom = -1
            else dom = (dom > 1e300 / (PDOM[t, idx] < 1 ? 1 : PDOM[t, idx])) ? 1e300 : dom * PDOM[t, idx]
        }
        if (guaranteed) {
            if (I_PREFIX[rt, k]) warn(t, "", desc " は前方一致インデックスです。生成値の先頭部分が重複しないことを確認してください")
            continue
        }
        # 複合キーの定型パターン: (SEQ 繰返しr | REF SEQ:r) + (CYCLE n>=r)
        if (I_NCOL[rt, k] >= 2) {
            okpat = 0
            for (i = 1; i <= I_NCOL[rt, k] && !okpat; i++) {
                c = I_COL[rt, k, i]; if (!((t, c) in PIDX)) continue
                aidx = PIDX[t, c]; r = 0; ref_ok = 0
                if (PRULE[t, aidx] == "SEQ" && PNULL[t, aidx] == 0) { r = PA3[t, aidx] + 0; ref_ok = 1 }
                if (PRULE[t, aidx] == "SEQ_DATETIME" && PNULL[t, aidx] == 0) { r = PA3[t, aidx] + 0; ref_ok = 1 }
                if (PRULE[t, aidx] == "REF" && RG_MODE[t, PA1[t, aidx]] == "SEQ" && RG_NC[t, PA1[t, aidx]] == 1) { r = RG_REP[t, PA1[t, aidx]]; ref_ok = (RGS_CNT[t, PA1[t, aidx]] == "" || RGS_CNT[t, PA1[t, aidx]] + 0 == 0 || rows <= (RGS_CNT[t, PA1[t, aidx]] + 0) * r) }
                if (!ref_ok || r < 1) continue
                for (j = 1; j <= I_NCOL[rt, k]; j++) {
                    if (j == i) continue
                    c = I_COL[rt, k, j]; if (!((t, c) in PIDX)) continue
                    cidx = PIDX[t, c]
                    if (PNULL[t, cidx] > 0) continue
                    if ((PRULE[t, cidx] == "CYCLE" || PRULE[t, cidx] == "CYCLE_RANGE") && CYC_REP[t, cidx] == 1 && CYC_N[t, cidx] >= r) { okpat = 1; break }
                    if (PRULE[t, cidx] == "REF" && RG_MODE[t, PA1[t, cidx]] == "SEQ" && RG_REP[t, PA1[t, cidx]] == 1 && (RGS_CNT[t, PA1[t, cidx]] == "" || RGS_CNT[t, PA1[t, cidx]] + 0 == 0 || RGS_CNT[t, PA1[t, cidx]] + 0 >= r)) { okpat = 1; break }
                }
            }
            if (okpat) continue
        }
        if (dom < 0) { warn(t, "", desc " (" index_cols(rt, k) ") の一意性を保証できません。重複するとロード時にエラーになります"); continue }
        prob = (rows > dom) ? 1 : 1 - exp(-(rows * (rows - 1)) / (2 * dom))
        if (prob >= 0.5) err(t, "", desc " (" index_cols(rt, k) ") の値が重複する可能性が非常に高いです (推定 " sprintf("%.1f", prob * 100) "%)。一意な値を生成する方式 (SEQ / UNIQUE_INT / UNIQUE_STRING / UUID / TEMPLATE の ${seq} など) を指定してください")
        else if (prob > 1e-6) warn(t, "", desc " (" index_cols(rt, k) ") の値が重複する確率 約 " sprintf("%.3g", prob * 100) "% (重複時はロードが失敗します)")
    }
}

function index_cols(rt, k,    i, s) { s = ""; for (i = 1; i <= I_NCOL[rt, k]; i++) s = s (i > 1 ? "," : "") I_COL[rt, k, i]; return s }

# DELETE_GENERATED で使う識別列 (数値の SEQ) を選ぶ
function choose_delete_key(t, rt,    idx, c, best, score, s) {
    if (CT_CLEAN[t] != "DELETE_GENERATED") return
    best = 0; score = 0
    for (idx = 1; idx <= NPC[t]; idx++) {
        c = PCOL[t, idx]
        if (PRULE[t, idx] != "SEQ" || PA3[t, idx] + 0 != 1 || PNULL[t, idx] > 0) continue
        if (C_KIND[rt, c] != "int" && C_KIND[rt, c] != "dec") continue
        column_index_info(rt, c)
        s = (COL_IN_PK && COL_SOLE_UNIQUE) ? 4 : COL_SOLE_UNIQUE ? 3 : (column_index_info(rt, c) != "") ? 2 : 1
        if (s > score) { score = s; best = idx }
    }
    if (!best) { err(t, "", "後片付け DELETE_GENERATED には、数値型の列に SEQ (繰返し1, NULL率0) が必要です (生成した行を特定するため)"); return }
    if (score == 1) warn(t, PCOL[t, best], "後片付けの識別列 " PCOL[t, best] " にインデックスがないため削除に時間がかかります")
    DEL_IDX[t] = best
}

# ---- 計画の出力 ---------------------------------------------------------------
function emit_plans(    o, t, rt, f, idx, header, jh, cl, sl, v, i, g, n, src, gl, dk, k, fn) {
    printf "" > (PLANDIR "/tables.tsv")
    for (o = 1; o <= NORD; o++) {
        t = ORD[o]; rt = CT_REAL[t]
        fn = PLANDIR "/" sprintf("%03d", o) ".plan"
        header = ""; jh = ""; cl = ""; sl = ""
        for (idx = 1; idx <= NPC[t]; idx++) {
            header = header (idx > 1 ? "," : "") csv_quote(PCOL[t, idx])
            if (PJM[t, idx] == "Y") jh = jh (jh == "" ? "" : ",") jm_quote(PCOL[t, idx])
            v = load_target(rt, PCOL[t, idx], idx)
            cl = cl (idx > 1 ? "," : "") v
            if (LOAD_SET != "") sl = sl (sl == "" ? "" : ",") LOAD_SET
        }
        printf "T\t%s\t%d\t%s\t%s\t%s\t%s\n", tsv_escape(rt), ROWS[t], CT_SEED[t], CT_JMROWS[t], tsv_escape(header), tsv_escape(jh) > fn
        for (idx = 1; idx <= NPC[t]; idx++) {
            printf "C\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", idx, tsv_escape(PCOL[t, idx]), POUT[t, idx], PRULE[t, idx], PNULL[t, idx], PJM[t, idx], \
                tsv_escape(PA1[t, idx]), tsv_escape(PA2[t, idx]), tsv_escape(PA3[t, idx]), tsv_escape(PA4[t, idx]), tsv_escape(PA5[t, idx]) > fn
            for (i = 1; i <= PNV[t, idx]; i++) printf "V\t%d\t%d\t%s\t%s\n", idx, i, tsv_escape(PV[t, idx, i]), PW[t, idx, i] > fn
        }
        for (n = 1; n <= RG_N[t]; n++) {
            g = RG_LIST[t, n]; src = RGS_SRC[t, g]
            gl = "G\t" tsv_escape(g) "\t" RG_MODE[t, g] "\t" RG_REP[t, g] "\t"
            if (src == "ARITH") gl = gl "ARITH\t" RGS_CNT[t, g] "\t" RGS_START[t, g] "\t" RGS_STEP[t, g] "\t"
            else if (src == "TPL") gl = gl "TPL\t" RGS_CNT[t, g] "\t" RGS_START[t, g] "\t" RGS_STEP[t, g] "\t" tsv_escape(RGS_FILE[t, g])
            else if (src == "FILE") gl = gl "FILE\t" RGS_CNT[t, g] "\t0\t0\t" tsv_escape(RGS_FILE[t, g])
            else if (src == "PCSV") gl = gl "DEFER\t0\t0\t0\t\tPCSV\t" sprintf("%03d", ORDPOS[RGS_PT[t, g]]) "\t" RGS_PCOLS[t, g]
            else if (src == "LATE") {
                k = ""
                for (i = 1; i <= RG_NC[t, g]; i++) k = k "\t" tsv_escape(RG_COL[t, g, i])
                gl = gl "DEFER\t0\t0\t0\t\tLATE\t" tsv_escape(RGS_PT[t, g]) k
            }
            print gl > fn
        }
        close(fn)
        dk = ""
        if (DEL_IDX[t] != "") { i = DEL_IDX[t]; dk = tsv_escape(PCOL[t, i]) "\t" sprintf("%d", SEQ_START[t, i]) "\t" sprintf("%d", SEQ_LAST[t, i]) "\t" sprintf("%d", SEQ_STEP[t, i]) }
        else dk = "\t\t\t"
        printf "TABLE\t%03d\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", o, tsv_escape(rt), ROWS[t], CT_BEFORE[t], CT_BACKUP[t], CT_CLEAN[t], \
            tsv_escape(CT_WHERE[t]), dk, tsv_escape(cl), tsv_escape(sl), CT_SEED[t], (jh != "") ? "Y" : "N" >> (PLANDIR "/tables.tsv")
    }
    close(PLANDIR "/tables.tsv")
    printf "" > (PLANDIR "/globals.tsv")
    for (k in GLOBAL) printf "%s\t%s\n", k, tsv_escape(GLOBAL[k]) >> (PLANDIR "/globals.tsv")
    close(PLANDIR "/globals.tsv")
}
