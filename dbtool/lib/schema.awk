# =============================================================================
# schema.awk : スキーマ情報 → Excel 取込用 TSV (#DBTOOL-SCHEMA) を出力
#   各列の生成方式・パラメータの初期値をデータ型/キー/外部キーから自動判定する。
#   DBT_DB=... DBT_GENERATED_AT=... DBT_SERVER_VERSION=... DBT_SERVER_HOST=... DBT_TOOL_VERSION=... \
#   DBT_REQ="t1<改行>t2..." LC_ALL=C TZ=UTC gawk -f util.awk -f schema_lib.awk -f schema.awk -v DEFROWS=10000 raw_schema.tsv
# =============================================================================

BEGIN {
    FS = "\t"; util_init(); CK_REPEAT = 5
    DB = ENVIRON["DBT_DB"]; GENERATED_AT = ENVIRON["DBT_GENERATED_AT"]; SERVER_VERSION = ENVIRON["DBT_SERVER_VERSION"]
    SERVER_HOST = ENVIRON["DBT_SERVER_HOST"]; TOOL_VERSION = ENVIRON["DBT_TOOL_VERSION"]; REQ = ENVIRON["DBT_REQ"]
    if (DEFROWS == "") DEFROWS = 10000
}
{ if (!schema_record()) { printf "schema.awk: 不明な行: %s\n", $0 > "/dev/stderr"; exit 2 } }

END {
    if (NTBL == 0) { print "schema.awk: 対象テーブルがありません" > "/dev/stderr"; exit 2 }
    table_order()
    print "#DBTOOL-SCHEMA\t1"
    info("database", DB)
    info("generated_at", GENERATED_AT)
    info("server_version", SERVER_VERSION)
    info("server_host", SERVER_HOST)
    info("tool_version", TOOL_VERSION)
    for (o = 1; o <= NORDER; o++) emit_table(ORDER[o], o * 10)
    for (o = 1; o <= NORDER; o++) emit_columns(ORDER[o])
}

function info(key, val) { print "INFO\t" tsv_escape(key) "\t" tsv_escape(val) }

function joinf(arr, n,    i, s) { s = tsv_escape(arr[1]); for (i = 2; i <= n; i++) s = s "\t" tsv_escape(arr[i]); return s }

# ---- 処理順: 外部キーの親を先にするトポロジカルソート ---------------------------------
function table_order(    i, t, n, k, p, done, indeg, req, nreq, pos, best) {
    nreq = split(REQ, req, "\n")
    for (i = 1; i <= NTBL; i++) { t = TBL_LIST[i]; pos[t] = 1000000 + i }
    for (i = 1; i <= nreq; i++) { t = real_table(req[i]); if (t != "" && pos[t] >= 1000000) pos[t] = i }
    for (i = 1; i <= NTBL; i++) {
        t = TBL_LIST[i]; indeg[t] = 0
        for (n = 1; n <= T_NFK[t]; n++) {
            k = FK_LIST[t, n]; p = FK_RTBL[t, k]
            if (FK_RSCH[t, k] != DB || p == t || !(p in TBL) || ((t, p) in EDGE)) continue
            EDGE[t, p] = 1; indeg[t]++
        }
    }
    NORDER = 0
    while (NORDER < NTBL) {
        best = ""
        for (i = 1; i <= NTBL; i++) {
            t = TBL_LIST[i]
            if ((t in done) || indeg[t] > 0) continue
            if (best == "" || pos[t] < pos[best]) best = t
        }
        if (best == "") {
            for (i = 1; i <= NTBL; i++) { t = TBL_LIST[i]; if (!(t in done) && (best == "" || pos[t] < pos[best])) best = t }
            CYCLE_NOTE[best] = "外部キーが循環しているため処理順を確認してください"
        }
        done[best] = 1; ORDER[++NORDER] = best
        for (i = 1; i <= NTBL; i++) { t = TBL_LIST[i]; if (((t, best) in EDGE) && !(t in done)) indeg[t]-- }
    }
}

function emit_table(t, ord,    pk, fks, n, k, i, s, f) {
    pk = ""
    if ((t, "PRIMARY") in I_EXISTS) for (i = 1; i <= I_NCOL[t, "PRIMARY"]; i++) pk = pk (i > 1 ? "," : "") I_COL[t, "PRIMARY", i]
    fks = ""
    for (n = 1; n <= T_NFK[t]; n++) {
        k = FK_LIST[t, n]; s = ""
        for (i = 1; i <= FK_NCOL[t, k]; i++) s = s (i > 1 ? "," : "") FK_COL[t, k, i]
        fks = fks (fks == "" ? "" : "; ") "(" s ")→" FK_RTBL[t, k] " [" k "]"
    }
    f[1] = "TABLE"; f[2] = t; f[3] = ord; f[4] = DEFROWS; f[5] = "TRUNCATE"; f[6] = "Y"; f[7] = "RESTORE"
    f[8] = ""; f[9] = "12345"; f[10] = "0"; f[11] = T_ENGINE[t]; f[12] = T_ROWS[t]; f[13] = T_AI[t]
    f[14] = pk; f[15] = fks; f[16] = REFBY[t]; f[17] = CHECKS[t]; f[18] = TRIGGERS[t]
    f[19] = T_COMMENT[t] (CYCLE_NOTE[t] != "" ? " [" CYCLE_NOTE[t] "]" : "")
    print joinf(f, 19)
}

function emit_columns(t,    n, c, f, idx) {
    composite_roles(t)
    for (n = 1; n <= T_NCOL[t]; n++) {
        c = COLS[t, n]
        idx = column_index_info(t, c)
        default_rule(t, c)
        f[1] = "COLUMN"; f[2] = t; f[3] = C_POS[t, c]; f[4] = c; f[5] = C_CT[t, c]
        f[6] = C_NULL[t, c] ? "YES" : "NO"; f[7] = C_KEY[t, c]; f[8] = idx
        f[9] = C_DEFNULL[t, c] ? (C_NULL[t, c] ? "NULL" : "") : C_DEF[t, c]
        f[10] = C_EXTRA[t, c]; f[11] = fk_info(t, c); f[12] = C_COMMENT[t, c]
        f[13] = R_RULE; f[14] = R_P1; f[15] = R_P2; f[16] = R_P3; f[17] = R_NULL; f[18] = R_JM; f[19] = R_NOTE
        print joinf(f, 19)
    }
}

# ---- 複合一意キー: 第1列=繰返し連番 / 第2列=巡回 で一意な組合せを作る ------------------
function composite_roles(t,    n, k, i, c, ok, first) {
    for (n = 0; n <= T_NIDX[t]; n++) {
        # PRIMARY を最優先
        if (n == 0) { if (!((t, "PRIMARY") in I_EXISTS)) continue; k = "PRIMARY" }
        else { k = IDX_LIST[t, n]; if (k == "PRIMARY") continue }
        if (!I_UNIQUE[t, k] || I_FUNC[t, k] || I_NCOL[t, k] < 2) continue
        ok = 1
        for (i = 1; i <= I_NCOL[t, k]; i++) {
            c = I_COL[t, k, i]
            if (C_AUTOINC[t, c] || C_GEN[t, c] || ((t, c) in ROLE)) { ok = 0; break }
            column_index_info(t, c); if (COL_SOLE_UNIQUE) { ok = 0; break }
        }
        if (!ok) continue
        ROLE[t, I_COL[t, k, 1]] = "CK1:" k
        ROLE[t, I_COL[t, k, 2]] = "CK2:" k
    }
}

function is_numeric_kind(k) { return (k == "int" || k == "dec" || k == "float") }

function default_rule(t, c,    k, name, fk, pt, len, role, nv, ev, i, s, w, prec, scale, idig) {
    R_RULE = ""; R_P1 = ""; R_P2 = ""; R_P3 = ""; R_NULL = "0"; R_JM = "N"; R_NOTE = ""
    k = C_KIND[t, c]; name = tolower(c)
    column_index_info(t, c)
    if (COL_IN_PK) R_JM = "Y"
    role = ((t, c) in ROLE) ? ROLE[t, c] : ""

    if (C_GEN[t, c]) { R_RULE = "DEFAULT"; R_NOTE = "生成列のため値は設定できません (DB が自動計算)"; return }
    if (k == "unknown") {
        R_RULE = C_HASDEF[t, c] ? "DEFAULT" : "FIXED"
        R_NOTE = "未対応のデータ型です。値を手動で設定してください"; return
    }
    if (C_AUTOINC[t, c]) {
        R_RULE = "SEQ"; R_P1 = "AUTO"; R_P2 = "1"; R_P3 = "1"
        R_NOTE = "AUTO_INCREMENT: 既存最大値+1 からの連番 (DEFAULT にすると DB が採番)"; return
    }
    if ((t, c) in C_FK) {
        fk = C_FK[t, c]; pt = FK_RTBL[t, fk]
        if (FK_RSCH[t, fk] == DB && pt == t) {
            if (C_NULL[t, c]) { R_RULE = "NULL"; R_NOTE = "自己参照の外部キー: NULL を設定 (必要なら変更)" }
            else { R_RULE = "COPY"; R_P1 = FK_RCOL[t, fk, C_FKPOS[t, c]]; R_NOTE = "自己参照の外部キー: 自分自身を参照 (必要なら変更)" }
            return
        }
        if (FK_RSCH[t, fk] == DB) {
            R_RULE = "REF"; R_P1 = pt "." FK_RCOL[t, fk, C_FKPOS[t, c]]
            R_P3 = (FK_NCOL[t, fk] > 1) ? fk : ""
            if (role ~ /^CK1:/) { R_P2 = "SEQ:" CK_REPEAT; R_NOTE = "外部キー+複合一意キー第1列: 親1件につき " CK_REPEAT " 行 (" fk_info(t, c) ")" }
            else if (role ~ /^CK2:/) { R_P2 = "SEQ"; R_NOTE = "外部キー+複合一意キー第2列: 親の値を順番に使用 (" fk_info(t, c) ")" }
            else { R_P2 = "RANDOM"; R_NOTE = "外部キー: " fk_info(t, c) " の値からランダムに選択" }
            if (FK_NCOL[t, fk] > 1) R_NOTE = R_NOTE " / 複合外部キーは同じグループ名で同じ親行を参照"
            return
        }
        R_NOTE = "他スキーマへの外部キー (" fk_info(t, c) "): 値を手動で確認してください。"
    }
    if (role ~ /^CK1:/) {
        if (is_numeric_kind(k) || k == "char" || k == "year") { R_RULE = "SEQ"; R_P1 = "1"; R_P2 = "1"; R_P3 = CK_REPEAT; R_NOTE = "複合一意キー(" substr(role, 5) ")第1列: 同じ値を " CK_REPEAT " 行ずつ" ; return }
        if (k == "date" || k == "datetime" || k == "timestamp") { R_RULE = "SEQ_DATETIME"; R_P1 = (k == "date") ? "TODAY" : "NOW"; R_P2 = "1d"; R_P3 = CK_REPEAT; R_NOTE = "複合一意キー(" substr(role, 5) ")第1列"; return }
    }
    if (role ~ /^CK2:/) {
        if (is_numeric_kind(k) || k == "char" || k == "year") { R_RULE = "CYCLE"; R_P1 = "1.." CK_REPEAT; R_P2 = "1"; R_NOTE = "複合一意キー(" substr(role, 5) ")第2列: 1～" CK_REPEAT " を巡回"; return }
    }
    if (COL_SOLE_UNIQUE) { unique_default(t, c, k, name); return }
    random_default(t, c, k, name)
    if (role != "") R_NOTE = R_NOTE (R_NOTE == "" ? "" : " / ") "複合一意キー(" substr(role, 5) ")の一意性を確認してください"
    if (CHECK_TEXT[t] != "" && index(CHECK_TEXT[t], "`" c "`") > 0) R_NOTE = R_NOTE (R_NOTE == "" ? "" : " / ") "CHECK制約あり: 値の範囲を確認してください"
}

function unique_default(t, c, k, name,    len, w) {
    R_NOTE = "一意キー: 重複しない値を生成"
    if (is_numeric_kind(k)) { R_RULE = "SEQ"; R_P1 = "AUTO"; R_P2 = "1"; R_P3 = "1"; return }
    if (k == "year" || k == "bit") {
        R_RULE = "UNIQUE_INT"; int_range(t, c); R_P1 = IR_MIN
        R_P2 = (int_cmp(IR_MAX, "9007199254740991") > 0) ? "9007199254740991" : IR_MAX; return
    }
    if (k == "char" || k == "text") {
        len = (k == "char") ? C_CHARMAX[t, c] + 0 : 255
        if (name ~ /(uuid|guid)/ && len >= 36) { R_RULE = "UUID"; R_P1 = "STD"; return }
        if (name ~ /mail/ && len >= 30) { R_RULE = "TEMPLATE"; R_P1 = "user${seq}@example.com"; R_P2 = "1"; R_P3 = "1"; return }
        w = (len < 10) ? len : 10
        R_RULE = "TEMPLATE"; R_P1 = "${seq:" w "}"; R_P2 = "1"; R_P3 = "1"; return
    }
    if (k == "bin" || k == "blob") {
        if (C_DT[t, c] == "binary" && C_CHARMAX[t, c] + 0 == 16) { R_RULE = "UUID"; R_P1 = "BINARY"; return }
        len = (k == "bin") ? C_OCTMAX[t, c] + 0 : 255
        w = (len < 10) ? len : 10
        R_RULE = "TEMPLATE"; R_P1 = "${seq:" w "}"; R_P2 = "1"; R_P3 = "1"; return
    }
    if (k == "date") { R_RULE = "SEQ_DATETIME"; R_P1 = "TODAY"; R_P2 = "1d"; R_P3 = "1"; return }
    if (k == "datetime" || k == "timestamp") { R_RULE = "SEQ_DATETIME"; R_P1 = "NOW"; R_P2 = "1s"; R_P3 = "1"; return }
    random_default(t, c, k, name)
    R_NOTE = "一意キー: この型では一意な値を自動生成できません。値を確認してください"
}

function random_default(t, c, k, name,    len, mn, mx, n, i, ev, s, prec, scale, idig, dt) {
    dt = C_DT[t, c]
    if (k == "int") {
        if (C_CT[t, c] ~ /^tinyint\(1\)/) { R_RULE = "RANDOM_INT"; R_P1 = "0"; R_P2 = "1"; return }
        int_range(t, c)
        R_RULE = "RANDOM_INT"; R_P1 = "0"; R_P2 = (int_cmp(IR_MAX, "999999") < 0) ? IR_MAX : "999999"; return
    }
    if (k == "bit") { int_range(t, c); R_RULE = "RANDOM_INT"; R_P1 = "0"; R_P2 = (int_cmp(IR_MAX, "9007199254740991") > 0) ? "9007199254740991" : IR_MAX; return }
    if (k == "year") { R_RULE = "RANDOM_INT"; R_P1 = "2000"; R_P2 = "2030"; return }
    if (k == "dec" || k == "float") {
        prec = C_PREC[t, c] + 0; scale = C_SCALE[t, c] + 0
        if (k == "float" && C_CT[t, c] !~ /\(/) { R_RULE = "RANDOM_DECIMAL"; R_P1 = "0"; R_P2 = "10000"; R_P3 = "2"; return }
        idig = prec - scale; if (idig > 6) idig = 6
        s = (idig > 0) ? sprintf("%d", pow10(idig) - 1) : "0"
        if (scale > 0) { s = s "."; for (i = 0; i < scale; i++) s = s "9" }
        R_RULE = "RANDOM_DECIMAL"; R_P1 = "0"; R_P2 = s; R_P3 = scale; return
    }
    if (k == "date") { R_RULE = "RANDOM_DATE"; R_P1 = "TODAY-365"; R_P2 = "TODAY"; return }
    if (k == "datetime" || k == "timestamp") { R_RULE = "RANDOM_DATETIME"; R_P1 = "NOW-365d"; R_P2 = "NOW"; R_P3 = C_DTPREC[t, c] + 0; return }
    if (k == "time") { R_RULE = "RANDOM_TIME"; R_P1 = "00:00:00"; R_P2 = "23:59:59"; R_P3 = C_DTPREC[t, c] + 0; return }
    if (k == "char") {
        len = C_CHARMAX[t, c] + 0
        if (name ~ /mail/ && len >= 30) { R_RULE = "TEMPLATE"; R_P1 = "user${seq}@example.com"; R_P2 = "1"; R_P3 = "1"; R_NOTE = "列名からメールアドレス形式と推定"; return }
        if (name ~ /(tel|phone|fax|mobile)/ && len >= 13) { R_RULE = "TEMPLATE"; R_P1 = "0${int:70,90}-${digit:4}-${digit:4}"; R_NOTE = "列名から電話番号形式と推定"; return }
        if (name ~ /(zip|postal|post_code|postcode)/ && len >= 8) { R_RULE = "TEMPLATE"; R_P1 = "${digit:3}-${digit:4}"; R_NOTE = "列名から郵便番号形式と推定"; return }
        if (name ~ /url/ && len >= 36) { R_RULE = "TEMPLATE"; R_P1 = "https://example.com/${alnum:16}"; R_NOTE = "列名から URL 形式と推定"; return }
        if (name ~ /(uuid|guid)/ && len >= 36) { R_RULE = "UUID"; R_P1 = "STD"; return }
        mx = (len < 20) ? len : 20
        mn = (dt == "char") ? mx : ((mx < 5) ? mx : 5)
        R_RULE = "RANDOM_STRING"; R_P1 = mn; R_P2 = mx; R_P3 = "alnum"; return
    }
    if (k == "text") { R_RULE = "RANDOM_STRING"; R_P1 = "10"; R_P2 = "100"; R_P3 = "alnum"; return }
    if (k == "enum" || k == "set") {
        n = enum_values(C_CT[t, c], ev); s = ""
        for (i = 1; i <= n; i++) { gsub(/\\/, "&&", ev[i]); gsub(/\|/, "\\|", ev[i]); s = s (i > 1 ? "|" : "") ev[i] }
        R_RULE = "LIST"; R_P1 = s; return
    }
    if (k == "json") { R_RULE = "FIXED"; R_P1 = "{}"; R_NOTE = "JSON: 必要に応じて値を変更してください"; return }
    if (k == "bin") {
        len = C_OCTMAX[t, c] + 0
        if (dt == "binary") { R_RULE = "RANDOM_BYTES"; R_P1 = len; R_P2 = len; return }
        R_RULE = "RANDOM_BYTES"; R_P1 = "1"; R_P2 = (len < 16) ? len : 16; return
    }
    if (k == "blob") { R_RULE = "RANDOM_BYTES"; R_P1 = "16"; R_P2 = "64"; return }
    if (k == "geo") {
        if (C_NULL[t, c]) { R_RULE = "NULL"; R_NOTE = "空間データ型: 必要なら FIXED で WKT を指定"; return }
        R_RULE = "FIXED"; R_P2 = (C_SRS[t, c] != "" && C_SRS[t, c] != "NULL") ? C_SRS[t, c] : "0"
        if (dt == "linestring") R_P1 = "LINESTRING(0 0,1 1)"
        else if (dt == "polygon") R_P1 = "POLYGON((0 0,1 0,1 1,0 1,0 0))"
        else if (dt == "multipoint") R_P1 = "MULTIPOINT((0 0))"
        else if (dt == "multilinestring") R_P1 = "MULTILINESTRING((0 0,1 1))"
        else if (dt == "multipolygon") R_P1 = "MULTIPOLYGON(((0 0,1 0,1 1,0 1,0 0)))"
        else if (dt ~ /^geo(metry)?collection$/ || dt == "geomcollection") R_P1 = "GEOMETRYCOLLECTION(POINT(0 0))"
        else R_P1 = "POINT(0 0)"
        R_NOTE = "空間データ型: WKT とパラメータ2(SRID)を指定"
        return
    }
    R_RULE = "FIXED"; R_NOTE = "値を手動で設定してください"
}
