# =============================================================================
# export_filter.awk : エクスポート時の mysql 出力からデータ行と終端情報を分離
#   mysql に次の順で実行させた出力を受け取る:
#       SELECT <CSV 1行> FROM ...;   SHOW COUNT(*) WARNINGS;   SHOW WARNINGS LIMIT 10;
#   データ行の後ろに「警告件数」1行と警告メッセージ(最大10行)が続く。
#   データ行 (先頭に HEADER を付与) を標準出力へ、件数と警告を STATUS ファイルへ出力。
#   終端情報が見つからない (途中で切断等) 場合は終了コード 3、警告ありは 4。
#   DBT_HEADER=... DBT_STATUS=<file> LC_ALL=C gawk -f export_filter.awk
# =============================================================================

BEGIN { HEADER = ENVIRON["DBT_HEADER"]; STATUS = ENVIRON["DBT_STATUS"]; K = 12; n = 0; if (HEADER != "") print HEADER }
{
    if (n >= K) print buf[(n - K) % K]
    buf[n % K] = $0; n++
}
END {
    lo = (n > K) ? n - K : 0
    found = -1
    for (j = 0; j <= 10 && n - 1 - j >= lo; j++) {
        line = buf[(n - 1 - j) % K]
        if (line !~ /^[0-9]+$/) continue
        cnt = line + 0
        if ((cnt < 10 ? cnt : 10) != j) continue
        ok = 1
        for (t = 1; t <= j; t++) if (buf[(n - 1 - j + t) % K] !~ /^(Warning|Note|Error)\t/) ok = 0
        if (ok) { found = n - 1 - j; break }
    }
    if (found < 0) { print "TRAILER_NOT_FOUND" > STATUS; exit 3 }
    for (i = lo; i < found; i++) print buf[i % K]
    printf "ROWS\t%d\nWARNINGS\t%d\n", found, cnt > STATUS
    for (t = found + 1; t < n; t++) print "MSG\t" buf[t % K] > STATUS
    close(STATUS)
    exit (cnt > 0) ? 4 : 0
}
