#!/bin/bash
# =============================================================================
# dbtool 回帰テスト (RHEL 9 コンテナ内で実行。tests/docker/run_in_rhel.sh 経由)
#   使い方: cd dbtool && REG_TMP=/tmp/reg REG_CONF=xx.conf bash ../tests/regression.sh
#   前提: MySQL 8.4 に tests/sql/01_schema.sql / 02_seed.sql を root で投入済み
#         /xfer に Excel で出力した設定ファイル perf_excel.conf (任意)
# =============================================================================
set -uo pipefail
T=${REG_TMP:-/tmp/dbtool_regression_$$}          # 作業用ディレクトリ
REG_CONF=${REG_CONF:-/xfer/perf_excel.conf}       # Excel で出力した設定ファイル (なければ 4 を省略)
mkdir -p "$T"
M=(mysql --defaults-file=conf/client.cnf -N)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS  $*"; }
ng()   { FAIL=$((FAIL + 1)); echo "  FAIL  $*"; }
chk()  { if eval "$1"; then ok "$2"; else ng "$2"; fi; }
q()    { "${M[@]}" -e "$1" 2>/dev/null; }
TABLES="all_types,categories,customers,employees,legacy,order_items,orders,products,roles,shop_sales,shops,user_roles"
cs()   { q "CHECKSUM TABLE $(echo "$TABLES" | sed 's/[^,]*/perf.&/g')"; q "SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='perf' AND AUTO_INCREMENT IS NOT NULL ORDER BY 1" ; }
run()  { ./dbtool.sh -q "$@" >/tmp/out.txt 2>&1; }

echo "== 1. export → import (全データ型の往復)"
cs >/tmp/cs0.txt
run export -d perf -t "$TABLES" -o $T/e1; chk '[[ $? == 0 && -f $T/e1/manifest.tsv ]]' "export"
run import -i $T/e1 -y; chk '[[ $? == 0 ]]' "import"
cs >/tmp/cs1.txt; chk 'diff -q /tmp/cs0.txt /tmp/cs1.txt >/dev/null' "CHECKSUM と AUTO_INCREMENT が一致"
run export -d perf -t 'all_types,legacy' --gzip -o $T/e2; chk '[[ $? == 0 ]]' "export --gzip"
q "TRUNCATE perf.all_types; TRUNCATE perf.legacy" >/dev/null
run import -i $T/e2 --append -y; chk '[[ $? == 0 ]]' "import --append (gzip)"
cs >/tmp/cs2.txt; chk 'diff -q /tmp/cs0.txt /tmp/cs2.txt >/dev/null' "append 後も一致"
run import -i $T/e2 --append -y; chk '[[ $? != 0 ]] && grep -q "ロールバック" /tmp/out.txt' "重複する append はロールバックされ失敗する"
cs >/tmp/cs3.txt; chk 'diff -q /tmp/cs0.txt /tmp/cs3.txt >/dev/null' "失敗した append でデータは変わらない"
sed -i 's/^\(TABLE\tall_types\t[^\t]*\t[^\t]*\t[^\t]*\t\)[0-9a-f]\{4\}/\1ffff/' $T/e2/manifest.tsv
run import -i $T/e2 -y; chk '[[ $? != 0 ]] && grep -q "チェックサム" /tmp/out.txt' "改ざんされたバックアップを拒否"

echo "== 2. dump → restore"
run dump -d perf -o $T/bk; chk '[[ $? == 0 ]] && grep -q FLOAT /tmp/out.txt' "dump (FLOAT の警告あり)"
f=$(ls $T/bk/perf_*.sql.gz)
run restore -f "$f" -d perf_restore --strip-definer -y; chk '[[ $? == 0 ]]' "restore --strip-definer"
a=$(q "CHECKSUM TABLE perf.orders, perf.customers" | awk '{print $2}' | tr '\n' ' ')
b=$(q "CHECKSUM TABLE perf_restore.orders, perf_restore.customers" | awk '{print $2}' | tr '\n' ' ')
chk '[[ $a == "$b" ]]' "restore 先の CHECKSUM が一致"
chk '[[ $(q "SELECT COUNT(*) FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=\"perf_restore\"") == 1 ]]' "トリガーも復元"
(set +o pipefail; gzip -dc "$f" | head -n 50 | gzip -c >$T/broken.sql.gz)
run restore -f $T/broken.sql.gz -d perf_restore -y; chk '[[ $? != 0 ]] && grep -q "最後まで" /tmp/out.txt' "途中で切れたダンプを拒否"

echo "== 3. load"
q "DROP TABLE IF EXISTS perf.ld; CREATE TABLE perf.ld (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, memo TEXT, price DECIMAL(10,2), dt DATETIME, flag TINYINT(1) NOT NULL DEFAULT 0, bin VARBINARY(8), up TIMESTAMP NULL)"
printf '\xEF\xBB\xBF"name","id","memo","price","dt","flag","bin"\r\n"山田, 太郎",1,"複数行\r\nの ""メモ""",1234.50,2026-10-01 10:00:00,1,0A0B\r\n佐藤,2,NULL,,2026-10-02 11:00:00,0,\r\n"NULL",3,"",0.01,,1,FF\r\n' >$T/rfc.csv
run load -d perf -t ld -f $T/rfc.csv --format rfc4180 -y; chk '[[ $? == 0 ]]' "RFC4180 (BOM/CRLF/改行/空欄=NULL)"
chk '[[ $(q "SELECT CONCAT_WS(\"|\", name, IFNULL(HEX(memo),\"N\"), IFNULL(price,\"N\"), IFNULL(dt,\"N\"), IFNULL(HEX(bin),\"N\")) FROM perf.ld ORDER BY id" | tr "\n" ";") == "山田, 太郎|E8A487E695B0E8A18C0D0AE381AE2022E383A1E383A222|1234.50|2026-10-01 10:00:00|0A0B;佐藤|N|N|2026-10-02 11:00:00|N;NULL||0.01|N|FF;" ]]' "RFC4180 の値 (NULL と文字列 NULL の区別, 空欄→NULL)"
python3 -c "open('$T/sjis.csv','wb').write('id,name,memo\r\n10,髙橋①,ﾃｽﾄ\r\n11,渡邊～,ー\r\n'.encode('cp932'))"
run load -d perf -t ld -f $T/sjis.csv --format rfc4180 --encoding cp932 -y; chk '[[ $? == 0 ]]' "Shift_JIS (cp932) のロード"
chk '[[ $(q "SELECT GROUP_CONCAT(name ORDER BY id) FROM perf.ld WHERE id IN (10,11)") == "髙橋①,渡邊～" ]]' "cp932 の文字が正しく変換される"
printf '名前,id\r\nx,12\r\n' | python3 -c "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read().decode('utf-8').encode('cp932'))" >$T/sjis2.csv
q "ALTER TABLE perf.ld ADD COLUMN \`名前\` VARCHAR(20) NULL"
run load -d perf -t ld -f $T/sjis2.csv --format rfc4180 --encoding cp932 -y
chk 'grep -q "name.*NOT NULL" /tmp/out.txt && ! grep -q "存在しません" /tmp/out.txt' "cp932 の日本語ヘッダー名を列に対応付け (name 不足のみ検出)"
printf '20,"no\\theader",NULL,9.99,2026-01-01 00:00:00,0,FFFF,2026-01-01 09:00:00\n' >$T/nh.csv
run load -d perf -t ld -f $T/nh.csv --no-header -y; chk '[[ $? != 0 ]] && grep -q "列数" /tmp/out.txt' "ヘッダーなし: 列数の違いを検出 (列追加後)"
q "ALTER TABLE perf.ld DROP COLUMN \`名前\`"
run load -d perf -t ld -f $T/nh.csv --no-header -y; chk '[[ $? == 0 ]]' "ヘッダーなし (mysql 形式)"
{ echo '"id","name","price"'; seq 1001 21000 | awk '{printf "%d,\"n%d\",%d.%02d\n", $1, $1, $1 % 1000, $1 % 100}'; } | gzip -c >$T/big.csv.gz
run load -d perf -t ld -f $T/big.csv.gz --chunk-rows 5000 -P 3 -y; chk '[[ $? == 0 ]]' "gzip 2万件を分割並列ロード"
chk '[[ $(q "SELECT CONCAT(COUNT(*), \"/\", SUM(price)) FROM perf.ld WHERE id > 1000") == "20000/9999900.00" ]]' "件数と合計値"
printf 'id,name\n40,a\n1,dup\n41,b\n' >$T/dup.csv
run load -d perf -t ld -f $T/dup.csv --format rfc4180 -y; chk '[[ $? != 0 ]]' "主キー重複でロールバック"
chk '[[ $(q "SELECT COUNT(*) FROM perf.ld WHERE id IN (40,41)") == 0 ]]' "重複時はファイル全体が取り消される"
printf 'id,name\n30,a\n31,b,extra\n' >$T/bad.csv
run load -d perf -t ld -f $T/bad.csv --format rfc4180 -y; chk '[[ $? != 0 ]] && grep -q "ファイル 3 行目" /tmp/out.txt' "列数不正を行番号付きで検出"
run delete -d perf -t ld --where "id > 15000" --batch-rows 1000 -y; chk '[[ $(q "SELECT COUNT(*) FROM perf.ld WHERE id > 15000") == 0 ]]' "条件付き分割 DELETE"
run truncate -d perf -t ld -y; chk '[[ $(q "SELECT COUNT(*) FROM perf.ld") == 0 ]]' "TRUNCATE"

echo "== 4. Excel で作成した設定ファイル → validate / prepare / cleanup"
if [[ -f $REG_CONF ]]; then
  cs >/tmp/cs4.txt
  run validate -c "$REG_CONF"; chk '[[ $? == 0 ]]' "validate"
  run prepare -c "$REG_CONF" -y --run-id reg1; chk '[[ $? == 0 ]]' "prepare"
  chk '[[ $(q "SELECT COUNT(*) FROM perf.order_items") == 5000 && $(q "SELECT COUNT(*) FROM perf.orders o LEFT JOIN perf.customers c ON c.id=o.customer_id WHERE c.id IS NULL") == 0 ]]' "件数と外部キー整合性"
  chk '[[ -s work/runs/reg1/jmeter/customers.csv && $(wc -l < work/runs/reg1/jmeter/customers.csv) == 101 ]]' "JMeter 用 CSV (100 件抽出)"
  run cleanup -y; chk '[[ $? == 0 ]]' "cleanup"
  cs >/tmp/cs5.txt; chk 'diff -q /tmp/cs4.txt /tmp/cs5.txt >/dev/null' "cleanup で全テーブルが元通り"
fi

echo ""
echo "結果: PASS $PASS / FAIL $FAIL"
((FAIL == 0))
