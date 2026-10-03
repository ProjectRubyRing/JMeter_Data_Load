# =============================================================================
# schema_lib.awk : information_schema 抽出結果 (fetch_schema の出力) の読込と型情報
#   レコード (TAB 区切り, 値は mysql --batch のエスケープ形式):
#     T table engine table_rows auto_increment collation comment table_type
#     C table pos name data_type column_type nullable default_is_null default key extra
#       char_max octet_max num_prec num_scale dt_prec charset collation gen_expr srs_id comment
#     I table index non_unique seq column sub_part expression index_type
#     F table constraint pos column ref_schema ref_table ref_column update_rule delete_rule
#     R ref_table child_schema child_table constraint
#     K table constraint check_clause enforced
#     G table trigger timing event
# =============================================================================

function schema_record(    t, c, n, i, k, cn) {
    if ($1 == "T") {
        t = tsv_unescape($2)
        if (!(t in TBL)) { TBL[t] = 1; NTBL++; TBL_LIST[NTBL] = t; TBL_LC[tolower(t)] = t }
        T_ENGINE[t] = $3; T_ROWS[t] = $4; T_AI[t] = $5; T_COLL[t] = $6
        T_COMMENT[t] = tsv_unescape($7); T_TYPE[t] = $8
        return 1
    }
    if ($1 == "C") {
        t = tsv_unescape($2); c = tsv_unescape($4)
        n = ++T_NCOL[t]; COLS[t, n] = c; C_IDX[t, c] = n; C_LC[t, tolower(c)] = c
        C_POS[t, c] = $3 + 0; C_DT[t, c] = tolower($5); C_CT[t, c] = tsv_unescape($6)
        C_NULL[t, c] = ($7 == "YES"); C_DEFNULL[t, c] = ($8 == "1"); C_DEF[t, c] = tsv_unescape($9)
        C_KEY[t, c] = $10; C_EXTRA[t, c] = tsv_unescape($11)
        C_CHARMAX[t, c] = $12; C_OCTMAX[t, c] = $13; C_PREC[t, c] = $14; C_SCALE[t, c] = $15
        C_DTPREC[t, c] = $16; C_CS[t, c] = $17; C_COLL[t, c] = $18
        C_GENEXPR[t, c] = tsv_unescape($19); C_SRS[t, c] = $20; C_COMMENT[t, c] = tsv_unescape($21)
        C_KIND[t, c] = type_kind(C_DT[t, c])
        C_GEN[t, c] = (C_EXTRA[t, c] ~ /(VIRTUAL|STORED) GENERATED/) ? 1 : 0
        C_AUTOINC[t, c] = (C_EXTRA[t, c] ~ /auto_increment/) ? 1 : 0
        C_UNSIGNED[t, c] = (C_CT[t, c] ~ /unsigned/) ? 1 : 0
        C_HASDEF[t, c] = (!C_DEFNULL[t, c] || C_NULL[t, c] || C_AUTOINC[t, c] || C_GEN[t, c]) ? 1 : 0
        return 1
    }
    if ($1 == "I") {
        t = tsv_unescape($2); k = tsv_unescape($3)
        if (!((t, k) in I_EXISTS)) {
            I_EXISTS[t, k] = 1; n = ++T_NIDX[t]; IDX_LIST[t, n] = k
            I_UNIQUE[t, k] = ($4 == "0"); I_TYPE[t, k] = $9; I_FUNC[t, k] = 0; I_PREFIX[t, k] = 0
        }
        i = $5 + 0; cn = tsv_unescape($6)
        if (i > I_NCOL[t, k]) I_NCOL[t, k] = i
        I_COL[t, k, i] = cn
        if (cn == "") I_FUNC[t, k] = 1
        if ($7 != "" && I_TYPE[t, k] != "SPATIAL") I_PREFIX[t, k] = 1
        return 1
    }
    if ($1 == "F") {
        t = tsv_unescape($2); k = tsv_unescape($3)
        if (!((t, k) in FK_EXISTS)) { FK_EXISTS[t, k] = 1; n = ++T_NFK[t]; FK_LIST[t, n] = k }
        i = $4 + 0; cn = tsv_unescape($5)
        if (i > FK_NCOL[t, k]) FK_NCOL[t, k] = i
        FK_COL[t, k, i] = cn; FK_RSCH[t, k] = tsv_unescape($6); FK_RTBL[t, k] = tsv_unescape($7)
        FK_RCOL[t, k, i] = tsv_unescape($8); FK_UPD[t, k] = $9; FK_DEL[t, k] = $10
        if (!((t, cn) in C_FK)) { C_FK[t, cn] = k; C_FKPOS[t, cn] = i }
        return 1
    }
    if ($1 == "R") {
        t = tsv_unescape($2)
        REFBY[t] = REFBY[t] (REFBY[t] == "" ? "" : ", ") tsv_unescape($3) "." tsv_unescape($4) "(" tsv_unescape($5) ")"
        REFBY_N[t]++
        REFBY_T[t, REFBY_N[t]] = tsv_unescape($3) SUBSEP tsv_unescape($4)
        return 1
    }
    if ($1 == "K") {
        t = tsv_unescape($2)
        CHECKS[t] = CHECKS[t] (CHECKS[t] == "" ? "" : "; ") tsv_unescape($3) ": " tsv_unescape($4) ($5 == "NO" ? " (NOT ENFORCED)" : "")
        CHECK_TEXT[t] = CHECK_TEXT[t] " " tsv_unescape($4)
        return 1
    }
    if ($1 == "G") {
        t = tsv_unescape($2)
        TRIGGERS[t] = TRIGGERS[t] (TRIGGERS[t] == "" ? "" : ", ") tsv_unescape($3) " (" $4 " " $5 ")"
        return 1
    }
    return 0
}

# DB 上の実テーブル名 (完全一致→大文字小文字無視)
function real_table(name) {
    if (name in TBL) return name
    if (tolower(name) in TBL_LC) return TBL_LC[tolower(name)]
    return ""
}

function real_column(t, name) {
    if ((t, name) in C_IDX) return name
    if ((t, tolower(name)) in C_LC) return C_LC[t, tolower(name)]
    return ""
}

# ---- 型分類 -------------------------------------------------------------------
function type_kind(dt) {
    if (dt ~ /^(tinyint|smallint|mediumint|int|integer|bigint)$/) return "int"
    if (dt == "decimal" || dt == "numeric") return "dec"
    if (dt == "float" || dt == "double" || dt == "real") return "float"
    if (dt == "bit") return "bit"
    if (dt == "year") return "year"
    if (dt == "date") return "date"
    if (dt == "datetime") return "datetime"
    if (dt == "timestamp") return "timestamp"
    if (dt == "time") return "time"
    if (dt == "char" || dt == "varchar") return "char"
    if (dt ~ /^(tiny|medium|long)?text$/) return "text"
    if (dt == "binary" || dt == "varbinary") return "bin"
    if (dt ~ /^(tiny|medium|long)?blob$/) return "blob"
    if (dt == "enum") return "enum"
    if (dt == "set") return "set"
    if (dt == "json") return "json"
    if (dt ~ /^(geometry|point|linestring|polygon|multipoint|multilinestring|multipolygon|geomcollection|geometrycollection)$/) return "geo"
    return "unknown"
}

# 正規形式 CSV での出力種別 (n/s/h)
function kind_out(k) {
    if (k == "char" || k == "text" || k == "enum" || k == "set" || k == "json") return "s"
    if (k == "bin" || k == "blob" || k == "geo") return "h"
    return "n"
}

# エクスポート用 SELECT 式 (1列分)
#   FLOAT は文字列化すると有効6桁に丸められるため DOUBLE に変換して出力する
#   (FLOAT の往復に必要な有効9桁は必ず残る)。DOUBLE は列の値をそのまま出力する
#   (CAST(... AS DOUBLE) の文字列化は約22文字に切り詰められ精度が落ちることがあるため)。
function export_expr(t, c,    k, q) {
    k = C_KIND[t, c]; q = sql_ident(c)
    if (k == "float" && C_DT[t, c] == "float") return "IFNULL(CAST(" q " AS DOUBLE),'NULL')"
    if (k == "bit") return "IFNULL(CAST(" q " AS UNSIGNED),'NULL')"
    if (k == "bin" || k == "blob" || k == "geo") return "IFNULL(HEX(" q "),'NULL')"
    if (k == "char" || k == "text" || k == "enum" || k == "set" || k == "json")
        return "IFNULL(CONCAT('\"',REPLACE(CONVERT(" q " USING utf8mb4),'\"','\"\"'),'\"'),'NULL')"
    return "IFNULL(" q ",'NULL')"
}

# LOAD DATA の列指定: 変数経由が必要なら SET 句を LOAD_SET に返す
function load_target(t, c, varno,    k, v) {
    k = C_KIND[t, c]; LOAD_SET = ""
    if (k == "bit") { v = "@dbt_v" varno; LOAD_SET = sql_ident(c) "=CAST(" v " AS UNSIGNED)"; return v }
    if (k == "bin" || k == "blob" || k == "geo") { v = "@dbt_v" varno; LOAD_SET = sql_ident(c) "=UNHEX(" v ")"; return v }
    return sql_ident(c)
}

# 整数型の範囲 (文字列) を IR_MIN / IR_MAX に設定
function int_range(t, c,    dt, u) {
    dt = C_DT[t, c]; u = C_UNSIGNED[t, c]
    if (C_KIND[t, c] == "year") { IR_MIN = "1901"; IR_MAX = "2155"; return }
    if (C_KIND[t, c] == "bit") {
        IR_MIN = "0"
        IR_MAX = (C_PREC[t, c] + 0 <= 53) ? sprintf("%d", pow_2(C_PREC[t, c] + 0) - 1) : BIT_MAX[C_PREC[t, c] + 0]
        return
    }
    if (dt == "tinyint")   { IR_MIN = u ? "0" : "-128";        IR_MAX = u ? "255" : "127"; return }
    if (dt == "smallint")  { IR_MIN = u ? "0" : "-32768";      IR_MAX = u ? "65535" : "32767"; return }
    if (dt == "mediumint") { IR_MIN = u ? "0" : "-8388608";    IR_MAX = u ? "16777215" : "8388607"; return }
    if (dt == "int" || dt == "integer") { IR_MIN = u ? "0" : "-2147483648"; IR_MAX = u ? "4294967295" : "2147483647"; return }
    IR_MIN = u ? "0" : "-9223372036854775808"; IR_MAX = u ? "18446744073709551615" : "9223372036854775807"
}

function pow_2(n,    r) { r = 1; while (n-- > 0) r *= 2; return r }

BEGIN {
    # BIT(54)～BIT(64) の最大値 (2^n - 1) : double では厳密に表せないため文字列で保持
    BIT_MAX[54] = "18014398509481983";   BIT_MAX[55] = "36028797018963967"
    BIT_MAX[56] = "72057594037927935";   BIT_MAX[57] = "144115188075855871"
    BIT_MAX[58] = "288230376151711743";  BIT_MAX[59] = "576460752303423487"
    BIT_MAX[60] = "1152921504606846975"; BIT_MAX[61] = "2305843009213693951"
    BIT_MAX[62] = "4611686018427387903"; BIT_MAX[63] = "9223372036854775807"
    BIT_MAX[64] = "18446744073709551615"
}

# DECIMAL / FLOAT(M,D) の整数部桁数上限 (FLOAT/DOUBLE で精度未指定なら -1)
function dec_int_limit(t, c) {
    if (C_KIND[t, c] == "dec") return C_PREC[t, c] - C_SCALE[t, c]
    if (C_KIND[t, c] == "float" && C_CT[t, c] ~ /\(/) return C_PREC[t, c] - C_SCALE[t, c]
    return -1
}

# ENUM / SET の要素を arr[1..n] に取り出す (COLUMN_TYPE を解析)
function enum_values(ct, arr,    n, i, L, ch, cur, inq) {
    n = 0; i = index(ct, "(") + 1; L = length(ct); cur = ""; inq = 0
    for (; i <= L; i++) {
        ch = substr(ct, i, 1)
        if (!inq) { if (ch == "'") { inq = 1; cur = "" } ; continue }
        if (ch == "\\") {
            i++; ch = substr(ct, i, 1)
            if (ch == "n") cur = cur "\n"; else if (ch == "r") cur = cur "\r"; else if (ch == "0") cur = cur ""; else cur = cur ch
            continue
        }
        if (ch == "'") {
            if (substr(ct, i + 1, 1) == "'") { cur = cur "'"; i++; continue }
            arr[++n] = cur; inq = 0; continue
        }
        cur = cur ch
    }
    return n
}

# 列が属する一意インデックスの説明 (PK/UK)。単独一意なら COL_SOLE_UNIQUE=1
function column_index_info(t, c,    n, k, i, s, role, sole) {
    s = ""; COL_SOLE_UNIQUE = 0; COL_FIRST_UNIQUE = 0; COL_IN_PK = 0
    for (n = 1; n <= T_NIDX[t]; n++) {
        k = IDX_LIST[t, n]
        for (i = 1; i <= I_NCOL[t, k]; i++) {
            if (I_COL[t, k, i] != c) continue
            role = (k == "PRIMARY") ? "PK" : (I_UNIQUE[t, k] ? "UK" : (I_TYPE[t, k] == "SPATIAL" ? "SPATIAL" : (I_TYPE[t, k] == "FULLTEXT" ? "FULLTEXT" : "IDX")))
            s = s (s == "" ? "" : ", ") role (k == "PRIMARY" ? "" : ":" k) (I_NCOL[t, k] > 1 ? "(" i "/" I_NCOL[t, k] ")" : "") (I_PREFIX[t, k] ? "[前方一致]" : "")
            if (k == "PRIMARY") COL_IN_PK = 1
            if (I_UNIQUE[t, k] && !I_FUNC[t, k]) {
                if (I_NCOL[t, k] == 1) COL_SOLE_UNIQUE = 1
                if (i == 1) COL_FIRST_UNIQUE = 1
            }
        }
    }
    return s
}

function fk_info(t, c,    k, i, s) {
    if (!((t, c) in C_FK)) return ""
    k = C_FK[t, c]; s = ""
    for (i = 1; i <= FK_NCOL[t, k]; i++) s = s (i > 1 ? "," : "") FK_RCOL[t, k, i]
    return FK_RTBL[t, k] "(" s ") [" k "]"
}
