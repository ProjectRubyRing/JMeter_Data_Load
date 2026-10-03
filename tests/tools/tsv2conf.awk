# テスト用: schema の TSV (#DBTOOL-SCHEMA) を、Excel の「設定ファイル出力」と同じ形式に変換する
#   gawk -f tsv2conf.awk -v ROWS=1000 -v RPF=300 -v PAR=2 schema.tsv > config.conf
BEGIN { FS = OFS = "\t" }
NR == 1 { if ($1 != "#DBTOOL-SCHEMA") { print "not a schema tsv" > "/dev/stderr"; exit 2 }; next }
$1 == "INFO" && $2 == "database" { db = $3 }
$1 == "TABLE" {
    nt++; T[nt] = $0
}
$1 == "COLUMN" { nc++; C[nc] = $0 }
END {
    print "#DBTOOL-DATAGEN-CONFIG", "1"
    print "# テスト用に tsv2conf.awk で作成"
    print "GLOBAL", "database", db
    print "GLOBAL", "rows_per_file", (RPF != "" ? RPF : 100000)
    print "GLOBAL", "parallel", (PAR != "" ? PAR : 1)
    print "GLOBAL", "fk_checks", "ON"
    print "GLOBAL", "time_zone", "+09:00"
    print "GLOBAL", "base_datetime", "2026-10-01 12:00:00"
    print "GLOBAL", "on_warning", "ROLLBACK"
    for (i = 1; i <= nt; i++) {
        split(T[i], f, "\t")
        # TABLE name order rows before backup cleanup where seed jmrows ...
        print "TABLE", f[2], "Y", (ROWS != "" ? ROWS : f[4]), f[3], f[5], f[6], f[7], f[8], f[9], f[10]
    }
    for (i = 1; i <= nc; i++) {
        split(C[i], f, "\t")
        # COLUMN table pos name type nullable key idx default extra fk comment rule p1 p2 p3 null jm note
        print "COLUMN", f[2], f[4], f[5], f[13], f[14], f[15], f[16], f[17], f[18]
    }
}
