# =============================================================================
# gen.awk : テストデータ生成エンジン
#   DBT_OUTF=<出力CSV> [DBT_JOUTF=<JMeter出力>] LC_ALL=C TZ=UTC gawk -f util.awk -f gen.awk \
#       -v START=<0基点の開始行> -v COUNT=<件数> -v CHUNK=<チャンク番号> <plan file>
#
#   plan file (TSV, 値は tsv_escape 済み):
#     T  table rows_total seed jmeter_rows header jm_header
#     C  idx name out rule nullrate jm a1 a2 a3 a4 a5
#     V  idx k value cumweight            (FIXED/LIST/CYCLE の値)
#     G  group mode repeat src count start step file
#   out: n=そのまま s=文字列(引用符付き) b=バイト列→16進 h=16進そのまま
#
#   生成方式ごとの引数 (a1..a5):
#     SEQ             開始, 増分, 繰返し
#     TEMPLATE        テンプレート, 連番開始, 連番増分
#     RANDOM_INT      最小, 最大
#     RANDOM_DECIMAL  最小(10^scale倍), 最大(10^scale倍), scale
#     UNIQUE_INT      最小, 値域件数
#     RANDOM_STRING   最小長, 最大長, 文字種
#     UNIQUE_STRING   全体長, 文字種, 接頭辞, 一意部の桁数
#     UUID            形式(STD/UPPER/NOHYPHEN/BINARY)
#     LIST / FIXED    (V 行)
#     CYCLE           (V 行), 繰返し(a2)
#     CYCLE_RANGE     開始, 件数, 繰返し, 向き(+1/-1)
#     RANDOM_DATE     最小日, 最大日, 出力(date/dt)
#     RANDOM_DATETIME 開始秒, 幅(単位=10^-fsp秒, W時は終了秒), fsp, 開始端数, フラグ(W=広範囲 D=日付出力)
#     RANDOM_TIME     最小(単位), 最大(単位), fsp
#     SEQ_DATETIME    開始, 増分, 繰返し, 出力(date=日単位 / dt=秒単位)
#     RANDOM_BYTES    最小バイト, 最大バイト
#     REF             グループ, 成分番号
#     COPY            コピー元の列番号
# =============================================================================

BEGIN { FS = "\t"; util_init(); OUTF = ENVIRON["DBT_OUTF"]; JOUTF = ENVIRON["DBT_JOUTF"] }

$1 == "T" {
    TABLE = tsv_unescape($2); ROWS = $3 + 0; SEED = $4 + 0; JMROWS = $5 + 0
    HEADER = tsv_unescape($6); JMHEADER = tsv_unescape($7)
    next
}
$1 == "C" {
    c = $2 + 0; if (c > NC) NC = c
    CNAME[c] = tsv_unescape($3); OUT[c] = $4; RULE[c] = $5; NULLR[c] = $6 + 0; JM[c] = ($7 == "Y")
    A1[c] = tsv_unescape($8); A2[c] = tsv_unescape($9); A3[c] = tsv_unescape($10)
    A4[c] = tsv_unescape($11); A5[c] = tsv_unescape($12)
    next
}
$1 == "V" {
    c = $2 + 0; k = $3 + 0
    VAL[c, k] = tsv_unescape($4); VCUM[c, k] = $5 + 0
    if (k > VN[c]) VN[c] = k
    next
}
$1 == "G" {
    g = tsv_unescape($2); NG++; GNAME[NG] = g
    GMODE[g] = $3; GREP[g] = $4 + 0; GSRC[g] = $5; GCOUNT[g] = $6 + 0
    GSTART[g] = $7 + 0; GSTEP[g] = $8 + 0; GFILE[g] = tsv_unescape($9)
    if (GREP[g] < 1) GREP[g] = 1
    next
}
{ printf "gen.awk: 不明な計画行です: %s\n", $0 > "/dev/stderr"; ERR = 1; exit 2 }

END {
    if (ERR) exit 2
    if (TABLE == "" || NC == 0) { print "gen.awk: 生成計画が空です" > "/dev/stderr"; exit 2 }
    prepare_columns()
    load_ref_groups()
    generate()
}

# ---- 前処理 -------------------------------------------------------------------
function prepare_columns(    c, cls, n, p, pw, k, r, msg) {
    for (cls in CLS_N) {
        n = CLS_N[cls]; p = 0; pw = 1
        if (n < 2) continue
        while (pw * n <= TWO52) { pw *= n; p++ }
        CLS_PER[cls] = p; CLS_POW[cls] = pw
    }
    for (c = 1; c <= NC; c++) {
        N1[c] = A1[c] + 0; N2[c] = A2[c] + 0; N3[c] = A3[c] + 0; N4[c] = A4[c] + 0
        r = RULE[c]
        if ((r == "RANDOM_STRING" && !(A3[c] in CLS_N)) || (r == "UNIQUE_STRING" && !(A2[c] in CLS_N))) {
            printf "gen.awk: 不明な文字種です (%s)\n", CNAME[c] > "/dev/stderr"; exit 2
        }
        if (r == "SEQ" && N3[c] < 1) N3[c] = 1
        if (r == "TEMPLATE") {
            msg = tpl_parse(A1[c], c)
            if (msg != "") { printf "gen.awk: %s (%s)\n", msg, CNAME[c] > "/dev/stderr"; exit 2 }
        }
        if (r == "RANDOM_INT" || r == "RANDOM_DECIMAL" || r == "RANDOM_DATE" || r == "RANDOM_BYTES") SPAN[c] = N2[c] - N1[c] + 1
        if (r == "RANDOM_STRING" || r == "RANDOM_BYTES") SPAN[c] = N2[c] - N1[c] + 1
        if (r == "RANDOM_DECIMAL") { P10[c] = pow10(N3[c]) }
        if (r == "RANDOM_DATETIME" || r == "RANDOM_TIME") P10[c] = pow10(N3[c])
        if (r == "UNIQUE_INT") perm_setup(c, N2[c])            # A2 = 値域の件数
        if (r == "UNIQUE_STRING") perm_setup(c, pow_int(CLS_N[A2[c]], N4[c]))   # A4 = 一意部の桁数
        if (r == "UUID") perm_setup(c, 281474976710656)         # 2^48
        if (r == "CYCLE" && N2[c] < 1) N2[c] = 1
        if (r == "CYCLE_RANGE" && N3[c] < 1) N3[c] = 1
        if (r == "LIST" || r == "CYCLE" || r == "FIXED") {
            for (k = 1; k <= VN[c]; k++) VCAN[c, k] = fmt_out(c, VAL[c, k])
            LTOTAL[c] = VCUM[c, VN[c]]
        }
        if (r == "COPY") { SRC[c] = N1[c] }
    }
}

function pow_int(b, e,    r) { r = 1; while (e-- > 0) r *= b; return r }

# Feistel 置換の準備: 値域 [0, n) の全単射を作る
function perm_setup(c, n,    h, M, k, x) {
    if (n < 1 || n > TWO52 * 4) { printf "gen.awk: 一意値の値域が不正です (%s: %s)\n", CNAME[c], n > "/dev/stderr"; exit 2 }
    PN[c] = n; h = 1
    while (pow_int(2, 2 * h) < n) h++
    M = pow_int(2, h); PM[c] = M
    x = (SEED % 999983 + 999983) % 999983
    for (k = 1; k <= 4; k++) {
        x = (x * 7919 + c * 104729 + k * 1299709 + 12345) % 2147483647
        PK[c, k] = x % M
        PA[c, k] = (x * 31 + 17) % M
    }
}

function feistel(x, c,    M, L, R, t, k) {
    M = PM[c]; L = int(x / M); R = x - L * M
    for (k = 1; k <= 4; k++) { t = R; R = xor(L, (R * PK[c, k] + PA[c, k]) % M); L = t }
    return L * M + R
}

function perm(x, c,    y) {
    y = feistel(x, c)
    while (y >= PN[c]) y = feistel(y, c)
    return y
}

function load_ref_groups(    gi, g, n, line, msg) {
    for (gi = 1; gi <= NG; gi++) {
        g = GNAME[gi]
        if (GCOUNT[g] < 1) { printf "gen.awk: 参照キーの件数が 0 です (グループ %s)\n", g > "/dev/stderr"; exit 2 }
        if (GSRC[g] == "TPL") {
            msg = tpl_parse(GFILE[g], "G" SUBSEP g)
            if (msg != "") { printf "gen.awk: 参照先テンプレートが不正です: %s\n", msg > "/dev/stderr"; exit 2 }
            continue
        }
        if (GSRC[g] == "ARITH") continue
        if (GSRC[g] != "FILE") { printf "gen.awk: 未解決の参照キーがあります (グループ %s, 種別 %s)\n", g, GSRC[g] > "/dev/stderr"; exit 2 }
        n = 0
        while ((getline line < GFILE[g]) > 0) GK[g, ++n] = line
        close(GFILE[g])
        if (n != GCOUNT[g] || n == 0) {
            printf "gen.awk: 参照キーファイルの件数が一致しません (%s: 期待 %d 件, 実際 %d 件)\n", GFILE[g], GCOUNT[g], n > "/dev/stderr"
            exit 2
        }
    }
}

# ---- 値の生成 -----------------------------------------------------------------
function rand_str(cls, len,    s, n, per, M, k, r, j, d) {
    s = ""; n = CLS_N[cls]; per = CLS_PER[cls]; M = CLS_POW[cls]
    while (len > 0) {
        k = (len < per) ? len : per
        r = int(rand() * M)
        for (j = 0; j < k; j++) { d = r % n; r = (r - d) / n; s = s CLS_CH[cls, d + 1] }
        len -= k
    }
    return s
}

function encode_base(x, cls, width,    s, n, d) {
    s = ""; n = CLS_N[cls]
    while (width-- > 0) { d = x % n; x = (x - d) / n; s = CLS_CH[cls, d + 1] s }
    return s
}

function rand_uuid(    v) {
    return rand_str("hex", 8) "-" rand_str("hex", 4) "-4" rand_str("hex", 3) "-" substr("89ab", int(rand() * 4) + 1, 1) rand_str("hex", 3) "-" rand_str("hex", 12)
}

# 参照先 TEMPLATE (固定文字列と ${seq} のみ) の値を連番値から計算
function tpl_seq_value(key, v,    s, k, w) {
    s = ""
    for (k = 1; k <= TP_N[key]; k++) {
        if (TP_T[key, k] == "lit") s = s TP_A1[key, k]
        else { w = TP_A1[key, k]; s = s (w > 0 ? sprintf("%0*d", w, v) : sprintf("%d", v)) }
    }
    return s
}

function tpl_gen(c, i,    s, k, t, v, w) {
    s = ""
    for (k = 1; k <= TP_N[c]; k++) {
        t = TP_T[c, k]
        if (t == "lit") s = s TP_A1[c, k]
        else if (t == "seq") {
            v = N2[c] + i * N3[c]; w = TP_A1[c, k]
            s = s (w > 0 ? sprintf("%0*d", w, v) : sprintf("%d", v))
        } else if (t == "int") {
            v = TP_A1[c, k] + int(rand() * (TP_A2[c, k] - TP_A1[c, k] + 1)); w = TP_A3[c, k]
            s = s (w > 0 ? sprintf("%0*d", w, v) : sprintf("%d", v))
        } else if (t == "cls") s = s rand_str(TP_A1[c, k], TP_A2[c, k] + int(rand() * (TP_A3[c, k] - TP_A2[c, k] + 1)))
        else if (t == "list") s = s TP_L[c, k, int(rand() * TP_LN[c, k]) + 1]
        else if (t == "uuid") s = s rand_uuid()
    }
    return s
}

function pick_weighted(c,    r, k, n) {
    n = VN[c]
    if (LTOTAL[c] <= 0) return int(rand() * n) + 1
    r = rand() * LTOTAL[c]
    for (k = 1; k < n; k++) if (r < VCUM[c, k]) return k
    return n
}

# 生値 → 正規形式 CSV のフィールド
function fmt_out(c, v,    o) {
    o = OUT[c]
    if (o == "s") return csv_quote(v)
    if (o == "b") return hex_of_bytes(v)
    return v
}

# JMeter 用の値 (16進表記を含む)
function jm_value(c) {
    if (ISN[c]) return ""
    if (OUT[c] == "b" && !HASCAN[c]) return hex_of_bytes(V[c])
    return V[c]
}

function gen_value(c, i,    r, u, x, s, k, sec, d, f, sign, p, ip, g) {
    r = RULE[c]
    if (r == "SEQ") { V[c] = sprintf("%d", N1[c] + int(i / N3[c]) * N2[c]); return }
    if (r == "RANDOM_INT") { V[c] = sprintf("%d", N1[c] + int(rand() * SPAN[c])); return }
    if (r == "RANDOM_STRING") { V[c] = rand_str(A3[c], N1[c] + int(rand() * SPAN[c])); return }
    if (r == "TEMPLATE") { V[c] = tpl_gen(c, i); return }
    if (r == "LIST") { k = pick_weighted(c); V[c] = VAL[c, k]; CANV[c] = VCAN[c, k]; HASCAN[c] = 1; return }
    if (r == "FIXED") { V[c] = VAL[c, 1]; CANV[c] = VCAN[c, 1]; HASCAN[c] = 1; return }
    if (r == "REF") {
        g = A1[c]
        if (GSRC[g] == "ARITH") { V[c] = sprintf("%d", GSTART[g] + GIDX[g] * GSTEP[g]); return }
        if (GSRC[g] == "TPL") { V[c] = tpl_seq_value("G" SUBSEP g, GSTART[g] + GIDX[g] * GSTEP[g]); return }
        CANV[c] = (N2[c] <= 1 && !GMULTI[g]) ? GLINE[g] : GCOMP[g, N2[c]]
        HASCAN[c] = 1; V[c] = canon_to_plain(CANV[c])
        if (CANON_NULL) ISN[c] = 1
        return
    }
    if (r == "RANDOM_DECIMAL") {
        u = N1[c] + int(rand() * SPAN[c])
        if (N3[c] == 0) { V[c] = sprintf("%d", u); return }
        sign = ""; if (u < 0) { sign = "-"; u = -u }
        p = P10[c]; ip = int(u / p)
        V[c] = sprintf("%s%d.%0*d", sign, ip, N3[c], u - ip * p)
        return
    }
    if (r == "RANDOM_DATETIME") {
        p = P10[c]
        if (index(A5[c], "W") > 0) { sec = N1[c] + int(rand() * (N2[c] - N1[c])); f = int(rand() * p) }
        else { u = N4[c] + int(rand() * (N2[c] + 1)); sec = N1[c] + int(u / p); f = u % p }
        if (index(A5[c], "D") > 0) V[c] = strftime("%Y-%m-%d", sec, 1)
        else V[c] = strftime("%Y-%m-%d %H:%M:%S", sec, 1) (N3[c] > 0 ? sprintf(".%0*d", N3[c], f) : "")
        return
    }
    if (r == "RANDOM_DATE") {
        d = N1[c] + int(rand() * SPAN[c])
        V[c] = strftime("%Y-%m-%d", d * 86400, 1) (A3[c] == "dt" ? " 00:00:00" : "")
        return
    }
    if (r == "RANDOM_TIME") { V[c] = fmt_time(N1[c] + int(rand() * (N2[c] - N1[c] + 1)), N3[c]); return }
    if (r == "SEQ_DATETIME") {
        x = N1[c] + int(i / N3[c]) * N2[c]
        if (A4[c] == "date") V[c] = strftime("%Y-%m-%d", x * 86400, 1)
        else V[c] = strftime("%Y-%m-%d %H:%M:%S", x, 1)
        return
    }
    if (r == "UNIQUE_INT") { V[c] = sprintf("%d", N1[c] + perm(i, c)); return }
    if (r == "UNIQUE_STRING") {
        s = encode_base(perm(i, c), A2[c], N4[c])
        if (N1[c] > N4[c]) s = rand_str(A2[c], N1[c] - N4[c]) s
        V[c] = A3[c] s
        return
    }
    if (r == "UUID") {
        x = perm(i, c)
        s = rand_str("hex", 8) "-" rand_str("hex", 4) "-4" rand_str("hex", 3) "-" substr("89ab", int(rand() * 4) + 1, 1) rand_str("hex", 3) "-" sprintf("%012x", x)
        if (A1[c] == "UPPER") s = toupper(s)
        else if (A1[c] == "NOHYPHEN") gsub(/-/, "", s)
        else if (A1[c] == "BINARY") { gsub(/-/, "", s); s = toupper(s) }
        V[c] = s
        return
    }
    if (r == "CYCLE") { k = int(i / N2[c]) % VN[c] + 1; V[c] = VAL[c, k]; CANV[c] = VCAN[c, k]; HASCAN[c] = 1; return }
    if (r == "CYCLE_RANGE") { V[c] = sprintf("%d", N1[c] + (int(i / N3[c]) % N2[c]) * N4[c]); return }
    if (r == "RANDOM_BYTES") { V[c] = rand_str("hexupper", 2 * (N1[c] + int(rand() * SPAN[c]))); return }
    if (r == "NULL") { ISN[c] = 1; return }
    printf "gen.awk: 未対応の生成方式です: %s (%s)\n", r, CNAME[c] > "/dev/stderr"
    exit 2
}

# ---- メインループ -------------------------------------------------------------
function generate(    r, i, c, gi, g, idx, line, jl, f, jstride, jlimit, n, k, tmp, end) {
    srand((SEED % 2147483647) + CHUNK * 7919 + 1)
    for (gi = 1; gi <= NG; gi++) { g = GNAME[gi]; GMULTI[g] = 0 }
    for (c = 1; c <= NC; c++) if (RULE[c] == "REF" && N2[c] > 1) GMULTI[A1[c]] = 1

    jlimit = 0
    if (JOUTF != "") {
        if (JMROWS <= 0 || JMROWS >= ROWS) { jstride = 1; jlimit = ROWS }
        else { jstride = int((ROWS + JMROWS - 1) / JMROWS); jlimit = JMROWS }
    }
    print HEADER > OUTF
    end = START + COUNT
    for (i = START; i < end; i++) {
        for (gi = 1; gi <= NG; gi++) {
            g = GNAME[gi]
            idx = (GMODE[g] == "RANDOM") ? int(rand() * GCOUNT[g]) : (int(i / GREP[g]) % GCOUNT[g])
            GIDX[g] = idx
            if (GSRC[g] == "FILE") {
                GLINE[g] = GK[g, idx + 1]
                if (GMULTI[g]) { n = split(GLINE[g], tmp, "\t"); for (k = 1; k <= n; k++) GCOMP[g, k] = tmp[k] }
            }
        }
        for (c = 1; c <= NC; c++) {
            HASCAN[c] = 0
            if (RULE[c] == "COPY") continue
            if (NULLR[c] > 0 && rand() * 100 < NULLR[c]) { ISN[c] = 1; continue }
            ISN[c] = 0
            gen_value(c, i)
        }
        for (c = 1; c <= NC; c++) {
            if (RULE[c] != "COPY") continue
            ISN[c] = ISN[SRC[c]]; V[c] = V[SRC[c]]
            if (HASCAN[SRC[c]] && OUT[c] == OUT[SRC[c]]) { CANV[c] = CANV[SRC[c]]; HASCAN[c] = 1 }
        }
        line = ""
        for (c = 1; c <= NC; c++) {
            if (ISN[c]) f = "NULL"
            else if (HASCAN[c]) f = CANV[c]
            else f = fmt_out(c, V[c])
            line = (c == 1) ? f : line "," f
        }
        print line > OUTF
        if (jlimit > 0 && i % jstride == 0 && int(i / jstride) < jlimit) {
            jl = ""; k = 0
            for (c = 1; c <= NC; c++) {
                if (!JM[c]) continue
                f = jm_quote(jm_value(c))
                jl = (k++ == 0) ? f : jl "," f
            }
            print jl > JOUTF
        }
    }
    close(OUTF)
    if (JOUTF != "") close(JOUTF)
}
