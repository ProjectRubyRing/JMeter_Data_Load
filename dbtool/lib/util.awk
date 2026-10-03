# =============================================================================
# util.awk : dbtool 共通 awk 関数
#   - gawk 5.x 専用。必ず LC_ALL=C (バイト単位処理) / TZ=UTC で実行すること。
#   - UTF-8 文字列は自前で文字単位に分解して扱う。
# =============================================================================

function util_init(    i, c) {
    for (i = 0; i < 256; i++) ORD[sprintf("%c", i)] = i
    HEXDIG = "0123456789ABCDEF"
    for (i = 0; i < 256; i++)
        HEXOF[i] = substr(HEXDIG, int(i / 16) + 1, 1) substr(HEXDIG, i % 16 + 1, 1)
    for (i = 0; i < 16; i++) {
        c = substr(HEXDIG, i + 1, 1)
        HEXVAL[c] = i; HEXVAL[tolower(c)] = i
    }
    TWO53 = 9007199254740992      # 2^53 : 生成する整数値の絶対値上限
    TWO52 = 4503599627370496      # 2^52 : 一意化(置換)に使う値域の上限

    # ---- 文字種 -------------------------------------------------------------
    CLS_SRC["digit"]    = "0123456789"
    CLS_SRC["upper"]    = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    CLS_SRC["lower"]    = "abcdefghijklmnopqrstuvwxyz"
    CLS_SRC["alpha"]    = CLS_SRC["upper"] CLS_SRC["lower"]
    CLS_SRC["alnum"]    = CLS_SRC["digit"] CLS_SRC["upper"] CLS_SRC["lower"]
    CLS_SRC["alnumupper"] = CLS_SRC["digit"] CLS_SRC["upper"]      # 大文字小文字を区別しない照合順序向け
    CLS_SRC["hex"]      = "0123456789abcdef"
    CLS_SRC["hexupper"] = "0123456789ABCDEF"
    CLS_SRC["ascii"]    = CLS_SRC["alnum"] "!#$%&()*+-./:;<=>?@[]^_{|}~"
    CLS_SRC["hira"]     = "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもやゆよらりるれろわをんがぎぐげござじずぜぞだぢづでどばびぶべぼぱぴぷぺぽ"
    CLS_SRC["kata"]     = "アイウエオカキクケコサシスセソタチツテトナニヌネノハヒフヘホマミムメモヤユヨラリルレロワヲンガギグゲゴザジズゼゾダヂヅデドバビブベボパピプペポ"
    CLS_SRC["hankana"]  = "ｦｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
    # 小学校1～3年で習う漢字 (すべて JIS X 0208 第1水準)
    CLS_SRC["kanji"]    = "一右雨円王音下火花貝学気九休玉金空月犬見五口校左三山子四糸字耳七車手十出女小上森人水正生青夕石赤千川先早草足村大男竹中虫町天田土二日入年白八百文木本名目立力林六" \
                          "引羽雲園遠何科夏家歌画回会海絵外角楽活間丸岩顔汽記帰弓牛魚京強教近兄形計元言原戸古午後語工公広交光考行高黄合谷国黒今才細作算止市矢姉思紙寺自時室社弱首秋週春書少場色食心新親図数西声星晴切雪船線前組走多太体台地池知茶昼長鳥朝直通弟店点電刀冬当東答頭同道読内南肉馬売買麦半番父風分聞米歩母方北毎妹万明鳴毛門夜野友用曜来里理話" \
                          "悪安暗医委意育員院飲運泳駅央横屋温化荷界開階寒感漢館岸起期客究急級宮球去橋業曲局銀区苦具君係軽血決研県庫湖向幸港号根祭皿仕死使始指歯詩次事持式実写者主守取酒受州拾終習集住重宿所暑助昭消商章勝乗植申身神真深進世整昔全相送想息速族他打対待代第題炭短談着注柱丁帳調追定庭笛鉄転都度投豆島湯登等動童農波配倍箱畑発反坂板皮悲美鼻筆氷表秒病品負部服福物平返勉放味命面問役薬由油有遊予羊洋葉陽様落流旅両緑礼列練路和"
    CLS_SRC["zenkaku"]  = CLS_SRC["hira"] CLS_SRC["kata"] CLS_SRC["kanji"]
    for (c in CLS_SRC) CLS_N[c] = u8split(CLS_SRC[c], CLS_CH, c)
    CLS_JP["hira"] = 1; CLS_JP["kata"] = 1; CLS_JP["hankana"] = 1; CLS_JP["kanji"] = 1; CLS_JP["zenkaku"] = 1
}

function is_class(name) { return (name in CLS_SRC) }

# ---- エスケープ ---------------------------------------------------------------
# 設定/スキーマ TSV のエスケープ: \\ \t \n \r (mysql --batch 出力の \0 も解釈)
function tsv_unescape(s,    out, p, c) {
    if (index(s, "\\") == 0) return s
    out = ""
    while ((p = index(s, "\\")) > 0) {
        out = out substr(s, 1, p - 1)
        c = substr(s, p + 1, 1)
        if (c == "t") out = out "\t"
        else if (c == "n") out = out "\n"
        else if (c == "r") out = out "\r"
        else if (c == "\\") out = out "\\"
        else if (c == "0") out = out ""
        else if (c == "") out = out "\\"
        else out = out "\\" c
        s = substr(s, p + 2)
    }
    return out s
}

function tsv_escape(s) {
    if (s ~ /[\\\t\n\r]/) {
        gsub(/\\/, "&&", s); gsub(/\t/, "\\t", s); gsub(/\n/, "\\n", s); gsub(/\r/, "\\r", s)
    }
    return s
}

# 正規形式 CSV (LOAD DATA ... ESCAPED BY '\\') の文字列フィールド
function csv_quote(s) {
    if (s ~ /[\\"\t\n\r]/) {
        gsub(/\\/, "&&", s); gsub(/"/, "&&", s)
        gsub(/\n/, "\\n", s); gsub(/\r/, "\\r", s); gsub(/\t/, "\\t", s)
    }
    return "\"" s "\""
}

# 正規形式 CSV のフィールド文字列 → 値 (NULL のとき CANON_NULL=1)
function canon_to_plain(f,    out, p, c) {
    CANON_NULL = 0
    if (f == "NULL") { CANON_NULL = 1; return "" }
    if (substr(f, 1, 1) != "\"") return f
    f = substr(f, 2, length(f) - 2)
    gsub(/""/, "\"", f)
    if (index(f, "\\") == 0) return f
    out = ""
    while ((p = index(f, "\\")) > 0) {
        out = out substr(f, 1, p - 1)
        c = substr(f, p + 1, 1)
        if (c == "n") out = out "\n"
        else if (c == "t") out = out "\t"
        else if (c == "r") out = out "\r"
        else if (c == "0") out = out sprintf("%c", 0)
        else if (c == "Z") out = out sprintf("%c", 26)
        else if (c == "b") out = out sprintf("%c", 8)
        else out = out c
        f = substr(f, p + 2)
    }
    return out f
}

# JMeter 用 CSV (RFC 4180) のフィールド
function jm_quote(s) {
    if (s ~ /[",\r\n]/) { gsub(/"/, "&&", s); return "\"" s "\"" }
    return s
}

# SQL 識別子 / 文字列リテラル
function sql_ident(s) { gsub(/`/, "``", s); return "`" s "`" }
function sql_str(s) { gsub(/\\/, "&&", s); gsub(/'/, "''", s); return "'" s "'" }

# ---- UTF-8 -------------------------------------------------------------------
function u8len(s,    t, n) { t = s; n = length(t); return n - gsub(/[\200-\277]/, "", t) }

# s を UTF-8 文字に分解し arr[key, 1..n] に格納 (key 省略時は arr[1..n])
function u8split(s, arr, key,    n, i, L, b, len) {
    n = 0; i = 1; L = length(s)
    while (i <= L) {
        b = ORD[substr(s, i, 1)]
        len = (b < 128) ? 1 : (b < 224) ? 2 : (b < 240) ? 3 : 4
        n++
        if (key == "") arr[n] = substr(s, i, len); else arr[key, n] = substr(s, i, len)
        i += len
    }
    return n
}

function u8cp(ch,    b0) {
    b0 = ORD[substr(ch, 1, 1)]
    if (b0 < 128) return b0
    if (b0 < 224) return (b0 - 192) * 64 + (ORD[substr(ch, 2, 1)] - 128)
    if (b0 < 240) return ((b0 - 224) * 64 + (ORD[substr(ch, 2, 1)] - 128)) * 64 + (ORD[substr(ch, 3, 1)] - 128)
    return (((b0 - 240) * 64 + (ORD[substr(ch, 2, 1)] - 128)) * 64 + (ORD[substr(ch, 3, 1)] - 128)) * 64 + (ORD[substr(ch, 4, 1)] - 128)
}

# 列の文字コード系統
function cs_family(cs) {
    if (cs ~ /^utf8mb4/ || cs == "utf16" || cs == "utf16le" || cs == "utf32" || cs == "gb18030") return "uni4"
    if (cs == "utf8mb3" || cs == "utf8" || cs == "ucs2") return "uni3"
    if (cs == "sjis" || cs == "cp932" || cs == "ujis" || cs == "eucjpms") return "jp"
    if (cs == "latin1") return "latin1"
    if (cs == "ascii") return "ascii"
    if (cs == "binary" || cs == "") return "binary"
    return "other"
}

# 1文字 (コードポイント cp) を文字コード cs で格納したときの最大バイト数
function cs_char_bytes(cs, cp) {
    if (cp < 128) return (cs == "ucs2" || cs ~ /^utf16/) ? 2 : (cs == "utf32") ? 4 : 1
    if (cs ~ /^utf8/ || cs == "binary" || cs == "") return (cp < 2048) ? 2 : (cp < 65536) ? 3 : 4
    if (cs == "ucs2") return 2
    if (cs ~ /^utf16/) return (cp < 65536) ? 2 : 4
    if (cs == "utf32") return 4
    if (cs == "sjis" || cs == "cp932") return (cp >= 65377 && cp <= 65439) ? 1 : 2
    if (cs == "ujis" || cs == "eucjpms") return 3
    if (cs == "latin1" || cs == "ascii" || cs_family(cs) == "other" && cs ~ /^(latin|cp125|cp85|cp86|koi8|greek|hebrew|armscii|geostd|keybcs|macce|macroman|dec8|hp8|swe7|tis620)/) return 1
    return 4
}

# cs で表現できない文字があればその文字を返す (判定できる範囲のみ)
function cs_unrepresentable(s, cs,    fam, n, i, cp, arr) {
    fam = cs_family(cs)
    if (fam == "uni4" || fam == "binary") return ""
    n = u8split(s, arr)
    for (i = 1; i <= n; i++) {
        cp = u8cp(arr[i])
        if (cp < 128) continue
        if (fam == "ascii") return arr[i]
        if (fam == "uni3" || fam == "jp") { if (cp > 65535) return arr[i]; continue }
        if (fam == "latin1") { if (cp > 255 && !(cp in CP1252_EXTRA)) return arr[i]; continue }
    }
    return ""
}

# s を cs で格納した場合のバイト数
function cs_str_bytes(s, cs,    n, i, arr, total) {
    if (cs ~ /^utf8/ || cs == "binary" || cs == "") return length(s)
    n = u8split(s, arr); total = 0
    for (i = 1; i <= n; i++) total += cs_char_bytes(cs, u8cp(arr[i]))
    return total
}

# 文字種 cls の1文字あたり最大バイト数 (cs 格納時)
function cls_max_bytes(cls, cs,    i, m, b) {
    m = 0
    for (i = 1; i <= CLS_N[cls]; i++) { b = cs_char_bytes(cs, u8cp(CLS_CH[cls, i])); if (b > m) m = b }
    return m
}

function hex_of_bytes(s,    i, n, out) {
    out = ""; n = length(s)
    for (i = 1; i <= n; i++) out = out HEXOF[ORD[substr(s, i, 1)]]
    return out
}

# ---- 数値文字列 ---------------------------------------------------------------
function is_int_str(s) { return (s ~ /^[+-]?[0-9]+$/) }
function is_dec_str(s) { return (s ~ /^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$/) }
function is_float_str(s) { return (s ~ /^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$/) }

# 符号と先頭ゼロを正規化した整数文字列 ("-0" は "0")
function norm_int(s,    neg) {
    neg = 0
    if (substr(s, 1, 1) == "+") s = substr(s, 2)
    else if (substr(s, 1, 1) == "-") { neg = 1; s = substr(s, 2) }
    sub(/^0+/, "", s)
    if (s == "") return "0"
    return (neg ? "-" : "") s
}

# 任意桁の整数文字列の比較 (-1/0/1)
function int_cmp(a, b,    na, nb, la, lb) {
    a = norm_int(a); b = norm_int(b)
    na = (substr(a, 1, 1) == "-"); nb = (substr(b, 1, 1) == "-")
    if (na != nb) return na ? -1 : 1
    if (na) { a = substr(a, 2); b = substr(b, 2) }
    la = length(a); lb = length(b)
    if (la != lb) return ((la < lb) != na) ? -1 : 1
    if (a == b) return 0
    return ((a < b) != na) ? -1 : 1
}

# 2^53 以内で厳密に扱える整数文字列か
function int_safe(s) { return is_int_str(s) && int_cmp(s, "9007199254740992") <= 0 && int_cmp(s, "-9007199254740992") >= 0 }

# 10進数文字列の整数部桁数 / 小数部桁数 (先頭/末尾のゼロは除外)
function dec_int_digits(s,    t) {
    t = s; sub(/^[+-]/, "", t); sub(/\..*$/, "", t); sub(/^0+/, "", t)
    return length(t)
}
function dec_frac_digits(s,    t) {
    t = s; if (index(t, ".") == 0) return 0
    sub(/^[^.]*\./, "", t); sub(/0+$/, "", t)
    return length(t)
}

function digits_of(v,    s) { s = sprintf("%d", v < 0 ? -v : v); return length(s) + (v < 0 ? 1 : 0) }

function pow10(n,    r) { r = 1; while (n-- > 0) r *= 10; return r }

# ---- 日付・時刻 ---------------------------------------------------------------
# 日付 "YYYY-MM-DD" (区切りは - または /) → 1970-01-01 からの日数。不正は ""
function parse_date(s,    a, y, m, d, t) {
    if (s !~ /^[0-9][0-9][0-9][0-9][-\/][0-9][0-9]?[-\/][0-9][0-9]?$/) return ""
    split(s, a, /[-\/]/); y = a[1] + 0; m = a[2] + 0; d = a[3] + 0
    if (m < 1 || m > 12 || d < 1 || d > 31) return ""
    t = mktime(sprintf("%04d %02d %02d 00 00 00", y, m, d), 1)
    if (t == -1) return ""
    if (strftime("%Y-%m-%d", t, 1) != sprintf("%04d-%02d-%02d", y, m, d)) return ""
    return int(t / 86400) - ((t < 0 && t % 86400 != 0) ? 1 : 0)
}

# 日時 → 秒 (PDT_FRAC に小数秒の数字列)。日付のみも可。不正は ""
function parse_datetime(s,    dp, tp, d, a, h, mi, se) {
    PDT_FRAC = ""
    if (s ~ /^[0-9][0-9][0-9][0-9][-\/][0-9][0-9]?[-\/][0-9][0-9]?$/) {
        d = parse_date(s); if (d == "") return ""
        return d * 86400
    }
    if (s !~ /^[0-9][0-9][0-9][0-9][-\/][0-9][0-9]?[-\/][0-9][0-9]?[ T][0-9][0-9]?:[0-9][0-9]?(:[0-9][0-9]?(\.[0-9]+)?)?$/) return ""
    dp = s; sub(/[ T].*$/, "", dp)
    tp = s; sub(/^[^ T]*[ T]/, "", tp)
    d = parse_date(dp); if (d == "") return ""
    if (index(tp, ".") > 0) { PDT_FRAC = tp; sub(/^[^.]*\./, "", PDT_FRAC); sub(/\..*$/, "", tp) }
    split(tp, a, ":"); h = a[1] + 0; mi = a[2] + 0; se = (3 in a) ? a[3] + 0 : 0
    if (h > 23 || mi > 59 || se > 59) return ""
    return d * 86400 + h * 3600 + mi * 60 + se
}

# 時刻 "[-]H:MM[:SS[.f]]" → 秒 (符号付き, 小数秒は PDT_FRAC)。不正は ""
function parse_time(s,    neg, a, h, mi, se, t) {
    PDT_FRAC = ""
    if (s !~ /^-?[0-9][0-9]?[0-9]?:[0-9][0-9]?(:[0-9][0-9]?(\.[0-9]+)?)?$/) return ""
    neg = (substr(s, 1, 1) == "-"); if (neg) s = substr(s, 2)
    if (index(s, ".") > 0) { PDT_FRAC = s; sub(/^[^.]*\./, "", PDT_FRAC); sub(/\..*$/, "", s) }
    split(s, a, ":"); h = a[1] + 0; mi = a[2] + 0; se = (3 in a) ? a[3] + 0 : 0
    if (mi > 59 || se > 59) return ""
    t = h * 3600 + mi * 60 + se
    if (t > 3020399) return ""
    return neg ? -t : t
}

# 相対指定: TODAY[±N[d]] / NOW[±N(d|h|m|s)]
#   kind="date" なら日数、それ以外は秒を返す。相対指定でなければ "" (REL_ERR にエラー)
function parse_rel(s, kind,    u, base, rest, sign, n, unit, mult) {
    REL_ERR = ""
    u = toupper(s); gsub(/[ ]/, "", u)
    if (u ~ /^TODAY/) { base = "TODAY"; rest = substr(u, 6) }
    else if (u ~ /^NOW/) { base = "NOW"; rest = substr(u, 4) }
    else return ""
    if (rest == "") { n = 0; unit = (base == "TODAY") ? "D" : "S" }
    else {
        if (rest !~ /^[+-][0-9]+[DHMS]?$/) { REL_ERR = "相対指定の書式が不正です: " s; return "" }
        sign = (substr(rest, 1, 1) == "-") ? -1 : 1
        unit = substr(rest, length(rest), 1)
        if (unit ~ /[0-9]/) {
            if (base == "NOW") { REL_ERR = "NOW の加減算には単位(d/h/m/s)が必要です: " s; return "" }
            unit = "D"; n = substr(rest, 2) + 0
        } else n = substr(rest, 2, length(rest) - 2) + 0
        n = sign * n
    }
    if (base == "TODAY" && unit != "D") { REL_ERR = "TODAY の加減算は日数のみ指定できます: " s; return "" }
    mult = (unit == "D") ? 86400 : (unit == "H") ? 3600 : (unit == "M") ? 60 : 1
    if (BASE_SEC == "") { REL_ERR = "基準日時が未確定です"; return "" }
    if (base == "TODAY") {
        if (kind == "date") return BASE_DAY + n
        return (BASE_DAY + n) * 86400
    }
    if (kind == "date") return int((BASE_SEC + n * mult) / 86400)
    return BASE_SEC + n * mult
}

function set_base(dt,    sec) {
    sec = parse_datetime(dt)
    if (sec == "") return 0
    BASE_SEC = sec; BASE_DAY = int(sec / 86400)
    return 1
}

function fmt_date(day) { return strftime("%Y-%m-%d", day * 86400, 1) }
function fmt_dt(sec) { return strftime("%Y-%m-%d %H:%M:%S", sec, 1) }
function fmt_time(units, fsp,    sign, p, a, s, f, h, m) {
    sign = ""; if (units < 0) { sign = "-"; units = -units }
    p = pow10(fsp); s = int(units / p); f = units - s * p
    h = int(s / 3600); m = int((s % 3600) / 60)
    return sprintf("%s%02d:%02d:%02d", sign, h, m, s % 60) (fsp > 0 ? sprintf(".%0*d", fsp, f) : "")
}

# ---- 値リスト ("|" 区切り, \| \\ でエスケープ) ----------------------------------
function split_list(s, arr,    n, cur, i, L, c) {
    n = 0; cur = ""; L = length(s)
    for (i = 1; i <= L; i++) {
        c = substr(s, i, 1)
        if (c == "\\" && i < L) { i++; cur = cur substr(s, i, 1); continue }
        if (c == "|") { arr[++n] = cur; cur = ""; continue }
        cur = cur c
    }
    arr[++n] = cur
    return n
}

# ---- テンプレート ("${name:args}") ----------------------------------------------
# tpl_parse(テンプレート, キー) → 成功 "" / 失敗 エラーメッセージ
#   TP_N[key]=部品数, TP_T[key,k]=種類(lit/seq/int/cls/list/uuid), TP_A1..A3[key,k]
#   list の値: TP_LN[key,k]=件数, TP_L[key,k,j]
function tpl_parse(t, key,    n, L, i, c, body, j, name, args, a, na, m, lit, lv, nl, q) {
    n = 0; lit = ""; L = length(t); i = 1
    while (i <= L) {
        c = substr(t, i, 1)
        if (c == "$" && substr(t, i + 1, 2) == "${") { lit = lit "${"; i += 3; continue }
        if (c == "$" && substr(t, i + 1, 1) == "{") {
            body = ""; j = i + 2; q = 0
            while (j <= L) {
                c = substr(t, j, 1)
                if (c == "\\" && j < L) { body = body c substr(t, j + 1, 1); j += 2; continue }
                if (c == "}") { q = 1; break }
                body = body c; j++
            }
            if (!q) return "テンプレートの ${ が閉じていません"
            if (lit != "") { n++; TP_T[key, n] = "lit"; TP_A1[key, n] = lit; lit = "" }
            if (index(body, ":") > 0) { name = substr(body, 1, index(body, ":") - 1); args = substr(body, index(body, ":") + 1) }
            else { name = body; args = "" }
            name = tolower(name); n++
            if (name == "seq") {
                TP_T[key, n] = "seq"; TP_A1[key, n] = 0
                if (args != "") { if (args !~ /^[0-9]+$/ || args + 0 > 30) return "${seq:桁数} の桁数が不正です: " args; TP_A1[key, n] = args + 0 }
            } else if (name == "int") {
                na = split(args, a, ",")
                if (na < 2 || na > 3 || !int_safe(a[1]) || !int_safe(a[2]) || a[1] + 0 > a[2] + 0) return "${int:最小,最大[,桁数]} の指定が不正です: " args
                TP_T[key, n] = "int"; TP_A1[key, n] = a[1] + 0; TP_A2[key, n] = a[2] + 0; TP_A3[key, n] = 0
                if (na == 3) { if (a[3] !~ /^[0-9]+$/ || a[3] + 0 > 30) return "${int:...} の桁数が不正です: " args; TP_A3[key, n] = a[3] + 0 }
            } else if (is_class(name)) {
                na = split(args, a, ",")
                if (na == 1 && a[1] ~ /^[0-9]+$/) { a[2] = a[1] }
                else if (!(na == 2 && a[1] ~ /^[0-9]+$/ && a[2] ~ /^[0-9]+$/)) return "${" name ":長さ} または ${" name ":最小,最大} の指定が不正です"
                if (a[1] + 0 > a[2] + 0 || a[2] + 0 > 10000) return "${" name ":...} の長さ指定が不正です: " args
                TP_T[key, n] = "cls"; TP_A1[key, n] = name; TP_A2[key, n] = a[1] + 0; TP_A3[key, n] = a[2] + 0
            } else if (name == "list") {
                nl = split_list(args, lv)
                if (args == "") return "${list:a|b|c} の値がありません"
                TP_T[key, n] = "list"; TP_LN[key, n] = nl
                for (m = 1; m <= nl; m++) TP_L[key, n, m] = lv[m]
            } else if (name == "uuid") {
                TP_T[key, n] = "uuid"
            } else return "テンプレートの不明なプレースホルダ: ${" body "}"
            i = j + 1
            continue
        }
        lit = lit c; i++
    }
    if (lit != "") { n++; TP_T[key, n] = "lit"; TP_A1[key, n] = lit }
    TP_N[key] = n
    return ""
}

BEGIN {
    split("8364 8218 402 8222 8230 8224 8225 710 8240 352 8249 338 381 8216 8217 8220 8221 8226 8211 8212 732 8482 353 8250 339 382 376", _cp1252)
    for (_i in _cp1252) CP1252_EXTRA[_cp1252[_i] + 0] = 1
}
