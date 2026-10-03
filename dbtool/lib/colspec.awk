# =============================================================================
# colspec.awk : エクスポート/ロード用の列指定を作成
#   LC_ALL=C gawk -f util.awk -f schema_lib.awk -f colspec.awk -v MODE=export -v TABLE=t schema.tsv
#     出力: HEADER<TAB>ヘッダー行 / SELECT<TAB>SELECT 式 / ORDER<TAB>ORDER BY 列 / NCOLS<TAB>列数
#           AUTOINC<TAB>AUTO_INCREMENT 値
#   LC_ALL=C gawk -f util.awk -f schema_lib.awk -f colspec.awk -v MODE=load [-v EMPTY_NULL=1] -v TABLE=t schema.tsv [header.txt]
#     header.txt : CSV ヘッダーの列名 (1行1列, tsv_escape 済み, 末尾に "#BOM<TAB>n")。省略時は全列 (生成列以外)
#     EMPTY_NULL : 文字列型 (CHAR/TEXT/SET) 以外の列で空のフィールドを NULL として扱う
#     出力: COLLIST<TAB>列リスト / SETLIST<TAB>SET 句 / NFIELDS<TAB>CSV の列数
#           MISSING<TAB>列名 (CSV にない列) / ERROR<TAB>メッセージ / WARN<TAB>メッセージ
# =============================================================================

BEGIN { FS = "\t"; util_init(); TABLE = ENVIRON["DBT_TABLE"]; NCOLSPEC = split(ENVIRON["DBT_COLS"], COLSPEC, "\n") }
ARGIND == 1 { if (!schema_record()) { print "ERROR\tスキーマ情報の形式が不正です"; exit 2 }; next }
ARGIND == 2 { if ($1 == "#BOM") next; NH++; HDR[NH] = tsv_unescape($0); next }

END {
    t = real_table(TABLE)
    if (t == "") { print "ERROR\tテーブルが存在しません: " TABLE; exit 2 }
    if (MODE == "export") do_export(t)
    else if (MODE == "load") do_load(t)
    else if (MODE == "exprs") do_exprs(t)
    else { print "ERROR\t不明なモード: " MODE; exit 2 }
    exit (NERR > 0) ? 1 : 0
}

# 指定列 (DBT_COLS: 改行区切り) の正規形式 CSV 用 SELECT 式と NULL 除外条件
function do_exprs(t,    i, c, sel, cond) {
    sel = ""; cond = ""
    for (i = 1; i <= NCOLSPEC; i++) {
        if (COLSPEC[i] == "") continue
        c = real_column(t, COLSPEC[i])
        if (c == "") { print "ERROR\t列が存在しません: " t "." COLSPEC[i]; NERR++; continue }
        sel = sel (sel == "" ? "" : ", ") export_expr(t, c)
        cond = cond (cond == "" ? "" : " AND ") sql_ident(c) " IS NOT NULL"
        KIND1 = C_KIND[t, c]
    }
    print "SELECT\t" tsv_escape(sel)
    print "WHERE\t" tsv_escape(cond)
    print "KIND\t" ((NCOLSPEC == 1 || COLSPEC[2] == "") ? KIND1 : "multi")
}

function do_export(t,    n, c, hdr, sel, k, i, ord, cnt) {
    hdr = ""; sel = ""; cnt = 0
    for (n = 1; n <= T_NCOL[t]; n++) {
        c = COLS[t, n]
        if (C_GEN[t, c]) continue
        if (C_KIND[t, c] == "unknown") { print "ERROR\t未対応のデータ型の列があります: " c " (" C_DT[t, c] ")"; NERR++; continue }
        cnt++
        hdr = hdr (cnt > 1 ? "," : "") csv_quote(c)
        sel = sel (cnt > 1 ? ",\n  " : "") export_expr(t, c)
    }
    ord = ""
    if ((t, "PRIMARY") in I_EXISTS) for (i = 1; i <= I_NCOL[t, "PRIMARY"]; i++) ord = ord (i > 1 ? "," : "") sql_ident(I_COL[t, "PRIMARY", i])
    print "HEADER\t" tsv_escape(hdr)
    print "SELECT\t" tsv_escape(sel)
    print "ORDER\t" tsv_escape(ord)
    print "NCOLS\t" cnt
    print "AUTOINC\t" T_AI[t]
}

# load_target に「空フィールド → NULL」変換を加えた版
function load_target_en(t, c, varno,    k, v) {
    k = C_KIND[t, c]
    if (!EMPTY_NULL || k == "char" || k == "text" || k == "set") return load_target(t, c, varno)
    v = "@dbt_v" varno
    if (k == "bit") LOAD_SET = sql_ident(c) "=CAST(NULLIF(" v ",'') AS UNSIGNED)"
    else if (k == "bin" || k == "blob" || k == "geo") LOAD_SET = sql_ident(c) "=UNHEX(NULLIF(" v ",''))"
    else LOAD_SET = sql_ident(c) "=NULLIF(" v ",'')"
    return v
}

function do_load(t,    n, c, i, rc, cl, sl, v, used, nf) {
    cl = ""; sl = ""; nf = 0
    if (NH == 0) {
        for (n = 1; n <= T_NCOL[t]; n++) {
            c = COLS[t, n]
            if (C_GEN[t, c]) continue
            nf++; v = load_target_en(t, c, nf)
            cl = cl (nf > 1 ? "," : "") v
            if (LOAD_SET != "") sl = sl (sl == "" ? "" : ",") LOAD_SET
        }
    } else {
        for (i = 1; i <= NH; i++) {
            nf++
            rc = real_column(t, HDR[i])
            if (rc == "") {
                if (HDR[i] == "\\N" || HDR[i] == "") print "ERROR\tCSV ヘッダーの " i " 列目の列名が空です"
                else print "ERROR\tCSV ヘッダーの列 '" HDR[i] "' はテーブル " t " に存在しません"
                NERR++; continue
            }
            if (rc in used) { print "ERROR\tCSV ヘッダーで列 '" rc "' が重複しています"; NERR++; continue }
            used[rc] = 1
            if (C_GEN[t, rc]) {
                print "WARN\t列 '" rc "' は生成列のため CSV の値を読み飛ばします"
                cl = cl (nf > 1 ? "," : "") "@dbt_skip"; continue
            }
            v = load_target_en(t, rc, nf)
            cl = cl (nf > 1 ? "," : "") v
            if (LOAD_SET != "") sl = sl (sl == "" ? "" : ",") LOAD_SET
        }
        for (n = 1; n <= T_NCOL[t]; n++) {
            c = COLS[t, n]
            if (C_GEN[t, c] || (c in used)) continue
            print "MISSING\t" tsv_escape(c) "\t" (C_HASDEF[t, c] ? "DEFAULT" : "REQUIRED")
            if (!C_HASDEF[t, c]) { print "ERROR\t列 '" c "' (NOT NULL かつデフォルト値なし) が CSV にありません"; NERR++ }
        }
    }
    print "COLLIST\t" tsv_escape(cl)
    print "SETLIST\t" tsv_escape(sl)
    print "NFIELDS\t" nf
}
