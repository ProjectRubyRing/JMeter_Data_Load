# =============================================================================
# csv.awk : CSV の解析 (MySQL の LOAD DATA と同じ規則で区切りを判定)
#   LC_ALL=C gawk -f util.awk -f csv.awk -v MODE=<mode> -v DIALECT=mysql|rfc4180 \
#       -v CRLF=0|1 -v HAS_HEADER=0|1 [その他] file...
#
#   MODE=header  : 先頭レコードの各フィールド値を1行ずつ (tsv_escape 済み) 出力
#   MODE=scan    : レコード数を数え、フィールド数 (-v NF_EXPECT) を検査
#                  出力: "RECORDS\t<件数>" / エラーは "BADREC\t<レコード番号>\t<行番号>\t<フィールド数>"
#   MODE=split   : CHUNK_ROWS 件ずつ $DBT_OUT_PREFIX-000001.csv ... に分割 (ヘッダーを各ファイルに付与)
#                  出力: "CHUNK\t<ファイル>\t<件数>" / "RECORDS\t<件数>"
#   MODE=extract : 正規形式 CSV (1レコード1行) から COLS="3,5" の列を TAB 区切りで出力
#                  (各ファイルの1行目はヘッダーとして読み飛ばす。NULL を含む組は除外)
#
#   DIALECT=mysql   : ESCAPED BY '\\' (バックスラッシュでエスケープ, \N は NULL)
#   DIALECT=rfc4180 : ESCAPED BY ''   (エスケープなし, "" は " )
#   いずれも FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'。
#   囲まれていない NULL は NULL として扱う (MySQL と同じ)。
# =============================================================================

BEGIN {
    util_init()
    OUT_PREFIX = ENVIRON["DBT_OUT_PREFIX"]
    ESC = (DIALECT == "mysql")
    MAXBAD = 10
    if (MODE == "extract") {
        FPAT = "([^,]*)|(\"([^\"]|\"\")*\")"
        NSEL = split(COLS, SEL, ",")
    }
    REC = 0; INREC = 0; PENDING = ""
}

MODE == "extract" {
    if (FNR == 1) next
    out = ""
    for (i = 1; i <= NSEL; i++) {
        f = $(SEL[i] + 0)
        if (f == "NULL") next
        out = (i == 1) ? f : out "\t" f
    }
    print out
    next
}

{
    line = $0
    if (NR == 1 && substr(line, 1, 3) == "\357\273\277") { line = substr(line, 4); HAD_BOM = 1 }
    if (!INREC) { RECSTART = NR; RECTEXT = ""; NFLD = 0; FSTATE = 0; FVAL = ""; NVALS = 0 }
    RECTEXT = INREC ? RECTEXT "\n" $0 : (NR == 1 && HAD_BOM ? line : $0)
    if (tokenize(line)) {
        INREC = 0
        handle_record()
    } else INREC = 1
}

END {
    if (MODE == "extract") exit 0
    if (INREC) { printf "UNTERMINATED\t%d\n", RECSTART; if (MODE == "split" && CHUNKF != "") close(CHUNKF); exit 3 }
    if (MODE == "split" && CHUNKF != "") { close(CHUNKF); printf "CHUNK\t%s\t%d\n", CHUNKF, CHUNKN }
    if (MODE != "header") printf "RECORDS\t%d\n", REC - (HAS_HEADER && REC > 0 ? 1 : 0)
    if (MODE == "header" && REC == 0) exit 3
    exit (BADN > 0) ? 4 : 0
}

# 1物理行を処理。レコードが完結したら 1 を返す。
#   FSTATE: 0=フィールド開始 1=囲みなし 2=囲みあり
function tokenize(line,    L, pos, c, lastcr, p, q, e, seg, n, P, i) {
    L = length(line)
    lastcr = (CRLF && substr(line, L, 1) == "\r")
    if (lastcr) L--
    # 高速経路: 引用符・エスケープを含まない1行完結のレコード
    if (FSTATE == 0 && NFLD == 0 && (!CRLF || lastcr) && index(line, "\"") == 0 && (!ESC || index(line, "\\") == 0)) {
        n = split(substr(line, 1, L), P, ",")
        if (n == 0) { n = 1; P[1] = "" }
        for (i = 1; i <= n; i++) { FVAL = P[i]; FENC = 0; end_field() }
        return 1
    }
    pos = 1
    while (1) {
        if (FSTATE == 0) {
            if (pos <= L && substr(line, pos, 1) == "\"") { FSTATE = 2; FENC = 1; pos++ }
            else { FSTATE = 1; FENC = 0 }
            FVAL = ""
        }
        if (FSTATE == 1) {
            # 区切り(,) またはエスケープを探す
            seg = substr(line, pos, L - pos + 1)
            p = index(seg, ","); e = ESC ? index(seg, "\\") : 0
            if (e > 0 && (p == 0 || e < p)) {
                FVAL = FVAL substr(seg, 1, e - 1)
                # 行末のエスケープ: 行区切りそのものがエスケープされたデータ
                if (pos + e - 1 == L) { FVAL = FVAL "\\" (lastcr ? "\r" : "") "\n"; return 0 }
                FVAL = FVAL "\\" substr(seg, e + 1, 1); pos += e + 1; continue
            }
            if (p > 0) { FVAL = FVAL substr(seg, 1, p - 1); end_field(); pos += p; FSTATE = 0; continue }
            FVAL = FVAL seg
            if (CRLF && !lastcr) { FVAL = FVAL "\n"; return 0 }     # 単独 LF はデータ
            end_field(); FSTATE = 0; return 1
        }
        # FSTATE == 2 : 囲みあり
        seg = substr(line, pos, L - pos + 1)
        q = index(seg, "\""); e = ESC ? index(seg, "\\") : 0
        if (e > 0 && (q == 0 || e < q)) {
            FVAL = FVAL substr(seg, 1, e - 1)
            if (pos + e - 1 == L) { FVAL = FVAL "\\" (lastcr ? "\r" : "") "\n"; return 0 }
            FVAL = FVAL "\\" substr(seg, e + 1, 1); pos += e + 1; continue
        }
        if (q == 0) { FVAL = FVAL seg (lastcr ? "\r" : "") "\n"; return 0 }   # 囲み内の改行はデータ
        FVAL = FVAL substr(seg, 1, q - 1); pos += q
        c = (pos <= L) ? substr(line, pos, 1) : ""
        if (c == "\"") { FVAL = FVAL "\""; pos++; continue }               # "" → "
        if (c == ",") { end_field(); pos++; FSTATE = 0; continue }
        if (pos > L) {
            if (CRLF && !lastcr) { FVAL = FVAL "\"\n"; return 0 }
            end_field(); FSTATE = 0; return 1
        }
        FVAL = FVAL "\""                                                    # 単独の " はデータ
    }
}

function end_field(    v) {
    NFLD++
    if (MODE != "header") return
    v = FVAL
    if (!FENC && (v == "NULL" || (ESC && v == "\\N"))) { VALS[++NVALS] = "\\N"; return }
    VALS[++NVALS] = ESC ? mysql_unescape(v) : v
}

function mysql_unescape(s,    out, p, c) {
    if (index(s, "\\") == 0) return s
    out = ""
    while ((p = index(s, "\\")) > 0) {
        out = out substr(s, 1, p - 1); c = substr(s, p + 1, 1)
        if (c == "n") out = out "\n"; else if (c == "t") out = out "\t"; else if (c == "r") out = out "\r"
        else if (c == "0") out = out sprintf("%c", 0); else if (c == "Z") out = out sprintf("%c", 26)
        else if (c == "b") out = out sprintf("%c", 8); else out = out c
        s = substr(s, p + 2)
    }
    return out s
}

function handle_record(    i, f) {
    REC++
    if (MODE == "header") {
        for (i = 1; i <= NVALS; i++) print tsv_escape(VALS[i])
        printf "#BOM\t%d\n", HAD_BOM ? 1 : 0
        exit 0
    }
    if (HAS_HEADER && REC == 1) {
        HDRTEXT = RECTEXT
        if (NF_EXPECT == "") NF_EXPECT = NFLD
        return
    }
    if (NF_EXPECT != "" && NFLD != NF_EXPECT + 0) {
        BADN++
        if (BADN <= MAXBAD) printf "BADREC\t%d\t%d\t%d\n", REC - (HAS_HEADER ? 1 : 0), RECSTART, NFLD
    }
    if (MODE == "split") {
        if (CHUNKF == "" || CHUNKN >= CHUNK_ROWS + 0) {
            if (CHUNKF != "") { close(CHUNKF); printf "CHUNK\t%s\t%d\n", CHUNKF, CHUNKN }
            NCHUNK++; CHUNKF = sprintf("%s-%06d.csv", OUT_PREFIX, NCHUNK); CHUNKN = 0
            if (HAS_HEADER) printf "%s\n", HDRTEXT > CHUNKF
            else printf "" > CHUNKF
        }
        printf "%s\n", RECTEXT > CHUNKF
        CHUNKN++
    }
}
