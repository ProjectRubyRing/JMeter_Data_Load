# テスト用: 設定ファイルの一部を書き換える (Excel で編集したことを模擬)
#   gawk -f patchconf.awk patch.tsv config.conf > new.conf
#   patch.tsv:  T<TAB>table<TAB>field_no<TAB>value      (TABLE 行のフィールド番号, 1=TABLE)
#               C<TAB>table<TAB>column<TAB>rule<TAB>p1<TAB>p2<TAB>p3<TAB>null<TAB>jm
#               G<TAB>key<TAB>value
BEGIN { FS = OFS = "\t" }
FNR == NR {
    if ($1 == "T") TP[$2, $3] = $4
    else if ($1 == "C") { CP[$2, $3] = 1; CR[$2, $3] = $4; C1[$2, $3] = $5; C2[$2, $3] = $6; C3[$2, $3] = $7; CN[$2, $3] = $8; CJ[$2, $3] = $9 }
    else if ($1 == "G") GP[$2] = $3
    next
}
$1 == "GLOBAL" && ($2 in GP) { $3 = GP[$2] }
$1 == "TABLE" { for (k = 1; k <= 11; k++) if (($2, k) in TP) $k = TP[$2, k] }
$1 == "COLUMN" && (($2, $3) in CP) { $5 = CR[$2, $3]; $6 = C1[$2, $3]; $7 = C2[$2, $3]; $8 = C3[$2, $3]; $9 = CN[$2, $3]; $10 = CJ[$2, $3] }
{ print }
