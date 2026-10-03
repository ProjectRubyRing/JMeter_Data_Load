# Excel 側の結合テスト: dbtool.sh schema で作った .xlsm を開き、自動展開・編集・設定ファイル出力・再取込を検証する
param(
    [Parameter(Mandatory = $true)][string]$Xlsm,
    [Parameter(Mandatory = $true)][string]$Tsv,
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$OutConf
)
$ErrorActionPreference = 'Stop'
$failed = 0
function Check([bool]$cond, [string]$msg) {
    if ($cond) { Write-Host "  OK   $msg" } else { Write-Host "  NG   $msg"; $script:failed++ }
}
function Find-ColumnRow($ws, [string]$table, [string]$column) {
    $last = $ws.Cells.Item($ws.Rows.Count, 3).End(-4162).Row   # xlUp
    for ($r = 3; $r -le $last; $r++) {
        if ($ws.Cells.Item($r, 1).Text -eq $table -and $ws.Cells.Item($r, 3).Text -eq $column) { return $r }
    }
    throw "列が見つかりません: $table.$column"
}
function Find-TableRow($ws, [string]$table) {
    $last = $ws.Cells.Item($ws.Rows.Count, 2).End(-4162).Row
    for ($r = 3; $r -le $last; $r++) { if ($ws.Cells.Item($r, 2).Text -eq $table) { return $r } }
    throw "テーブルが見つかりません: $table"
}
function Set-Col($ws, [string]$t, [string]$c, [string]$rule, [string]$p1, [string]$p2, [string]$p3, [double]$nullr, [string]$jm) {
    $r = Find-ColumnRow $ws $t $c
    $ws.Cells.Item($r, 12).Value2 = $rule
    $ws.Cells.Item($r, 13).Value2 = $p1
    $ws.Cells.Item($r, 14).Value2 = $p2
    $ws.Cells.Item($r, 15).Value2 = $p3
    $ws.Cells.Item($r, 16).Value2 = $nullr
    $ws.Cells.Item($r, 17).Value2 = $jm
}

$excel = New-Object -ComObject Excel.Application
$excel.Visible = $false
$excel.DisplayAlerts = $false
try {
    Write-Host "=== 1. schema で作成した xlsm を開く (Workbook_Open で自動展開) ==="
    $wb = $excel.Workbooks.Open($Xlsm)
    $wsT = $wb.Worksheets.Item('テーブル設定')
    $wsC = $wb.Worksheets.Item('列設定')
    $wsG = $wb.Worksheets.Item('共通設定')
    $nT = $wsT.Cells.Item($wsT.Rows.Count, 2).End(-4162).Row - 2
    $nC = $wsC.Cells.Item($wsC.Rows.Count, 3).End(-4162).Row - 2
    $tsvLines = Get-Content -Encoding UTF8 $Tsv
    $expT = @($tsvLines | Where-Object { $_ -like "TABLE`t*" }).Count
    $expC = @($tsvLines | Where-Object { $_ -like "COLUMN`t*" }).Count
    Check ($nT -eq $expT) "テーブル設定の行数 $nT = TSV の TABLE $expT"
    Check ($nC -eq $expC) "列設定の行数 $nC = TSV の COLUMN $expC"
    Check ($wsG.Cells.Item(4, 2).Text -eq 'perf') "共通設定 database = perf ($($wsG.Cells.Item(4, 2).Text))"
    $r = Find-ColumnRow $wsC 'order_items' 'order_id'
    Check ($wsC.Cells.Item($r, 12).Text -eq 'REF' -and $wsC.Cells.Item($r, 13).Text -eq 'orders.order_id' -and $wsC.Cells.Item($r, 14).Text -eq 'SEQ:5') "order_items.order_id = REF orders.order_id SEQ:5"
    Check ($wsC.Cells.Item($r, 18).Text -like 'P1:*') "パラメータの意味 (数式) が表示される: $($wsC.Cells.Item($r, 18).Text)"
    $r = Find-ColumnRow $wsC 'customers' 'email'
    Check ($wsC.Cells.Item($r, 13).Text -eq 'user${seq}@example.com') "customers.email テンプレート: $($wsC.Cells.Item($r, 13).Text)"
    $r = Find-ColumnRow $wsC 'order_items' 'line_no'
    Check ($wsC.Cells.Item($r, 13).Text -eq '1..5') "order_items.line_no CYCLE 1..5 (文字列のまま): $($wsC.Cells.Item($r, 13).Text)"
    $btn = $wsG.Buttons('btn_ExportConfig')
    Check ($btn.OnAction -like '*ExportConfig') "ボタンのマクロ: $($btn.OnAction)"

    Write-Host "=== 2. 入力エラーの検出 ==="
    $tr = Find-TableRow $wsT 'shops'
    $wsT.Cells.Item($tr, 4).Value2 = 50
    $wsT.Cells.Item($tr, 5).Value2 = 'WRONG'
    $n = $excel.Run("'" + $wb.Name + "'!ExportConfigTo", $OutConf + '.ng', $true)
    Check ($n -ge 1) "不正な事前処理で出力が中止される (エラー $n 件)"
    Check (-not (Test-Path ($OutConf + '.ng'))) "エラー時はファイルを出力しない"
    Check ($wsT.Cells.Item($tr, 5).Interior.Color -eq 13551615) "エラーのセルが赤色になる"
    $wsT.Cells.Item($tr, 5).Value2 = 'TRUNCATE'

    Write-Host "=== 3. ユーザーの編集を模擬して設定ファイルを出力 ==="
    $rows = @{ categories = 20; customers = 1000; products = 300; orders = 2000; order_items = 5000; roles = 20; user_roles = 1000; employees = 100; shops = 50; shop_sales = 700; legacy = 500 }
    foreach ($t in $rows.Keys) { $wsT.Cells.Item((Find-TableRow $wsT $t), 4).Value2 = $rows[$t] }
    $wsT.Cells.Item((Find-TableRow $wsT 'customers'), 10).Value2 = 100
    Set-Col $wsC 'customers' 'name' 'RANDOM_STRING' '2' '8' 'zenkaku' 0 'N'
    Set-Col $wsC 'customers' 'status' 'LIST' 'active|suspended|closed' '80|15|5' '' 0 'Y'
    Set-Col $wsC 'customers' 'email' 'TEMPLATE' 'user${seq:6}@example.com' '1' '1' 0 'Y'
    Set-Col $wsC 'customers' 'birthday' 'RANDOM_DATE' '1950-01-01' '2005-12-31' '' 10 'N'
    Set-Col $wsC 'products' 'name' 'TEMPLATE' '商品_${hira:3}_${seq:5}' '1' '1' 0 'N'
    Set-Col $wsC 'products' 'price' 'RANDOM_DECIMAL' '1' '9999.99' '2' 0 'N'
    Set-Col $wsC 'products' 'location' 'FIXED' 'POINT(35.681 139.767)' '4326' '' 0 'N'
    Set-Col $wsC 'orders' 'status' 'LIST' 'new|paid|shipped' '50|30|20' '' 0 'N'
    Set-Col $wsC 'orders' 'ordered_at' 'RANDOM_DATETIME' '2026-01-01 00:00:00' 'TODAY' '' 0 'N'
    Set-Col $wsC 'order_items' 'qty' 'RANDOM_INT' '1' '10' '' 0 'N'
    Set-Col $wsC 'legacy' 'code_ci' 'UNIQUE_STRING' '10' 'alnum' 'L-' 0 'Y'
    Set-Col $wsC 'legacy' 'sj' 'RANDOM_STRING' '2' '5' 'hankana' 0 'N'
    # Excel が日付に変換してしまう入力 (日付型のセル値) も正しく出力されること
    $r = Find-ColumnRow $wsC 'shop_sales' 'sold_on'
    $wsC.Cells.Item($r, 12).Value2 = 'SEQ_DATETIME'
    $wsC.Cells.Item($r, 13).NumberFormat = 'yyyy/m/d'
    $wsC.Cells.Item($r, 13).Value2 = 46023          # 2026-01-01 のシリアル値 (日付として入力された状態)
    $wsC.Cells.Item($r, 14).Value2 = '1d'
    $wsC.Cells.Item($r, 15).Value2 = '7'
    # 共通設定
    $wsG.Cells.Item(5, 2).Value2 = '300'
    $wsG.Cells.Item(6, 2).Value2 = '3'
    $wsG.Cells.Item(8, 2).Value2 = '+09:00'
    $wsG.Cells.Item(9, 2).Value2 = '2026-10-01 12:00:00'
    $n = $excel.Run("'" + $wb.Name + "'!ExportConfigTo", $OutConf, $true)
    Check ($n -eq 0) "設定ファイル出力 (エラー $n 件)"
    $bytes = [System.IO.File]::ReadAllBytes($OutConf)
    Check (-not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB)) "BOM なし"
    Check (-not ([System.Text.Encoding]::UTF8.GetString($bytes).Contains("`r"))) "改行は LF のみ"
    $conf = [System.Text.Encoding]::UTF8.GetString($bytes) -split "`n"
    Check ($conf[0] -eq "#DBTOOL-DATAGEN-CONFIG`t1") "1行目のマジック"
    $l = $conf | Where-Object { $_ -like "COLUMN`tshop_sales`tsold_on`t*" }
    Check ($l -like "*SEQ_DATETIME`t2026-01-01`t1d`t7*") "日付型のセル値は YYYY-MM-DD で出力: $l"
    $l = $conf | Where-Object { $_ -like "GLOBAL`ttime_zone`t*" }
    Check ($l -eq "GLOBAL`ttime_zone`t+09:00") "タイムゾーンが文字列のまま: $l"
    $l = $conf | Where-Object { $_ -like "TABLE`tcustomers`t*" }
    Check ($l -eq "TABLE`tcustomers`tY`t1000`t20`tTRUNCATE`tY`tRESTORE`t`t12345`t100") "TABLE 行: $l"

    Write-Host "=== 4. 保存して開き直す (再展開されず設定が残る) ==="
    $saved = [System.IO.Path]::ChangeExtension($OutConf, '.edited.xlsm')
    $wb.SaveAs($saved, 52)
    $wb.Close($false)
    $wb = $excel.Workbooks.Open($saved)
    $wsC = $wb.Worksheets.Item('列設定')
    $r = Find-ColumnRow $wsC 'customers' 'name'
    Check ($wsC.Cells.Item($r, 15).Text -eq 'zenkaku') "開き直しても編集内容が残る"
    $wb.Close($false)

    Write-Host "=== 5. 空のテンプレートに TSV を取込み → 再取込で設定を引き継ぐ ==="
    $wb = $excel.Workbooks.Open($Template)
    $ok = $excel.Run("'" + $wb.Name + "'!ImportSchemaFrom", $Tsv, $true)
    Check ($ok) "ImportSchemaFrom 成功"
    $wsC = $wb.Worksheets.Item('列設定')
    $nC2 = $wsC.Cells.Item($wsC.Rows.Count, 3).End(-4162).Row - 2
    Check ($nC2 -eq $expC) "取込後の列数 $nC2"
    Set-Col $wsC 'customers' 'kana' 'RANDOM_STRING' '3' '10' 'kata' 20 'N'
    $ok = $excel.Run("'" + $wb.Name + "'!ImportSchemaFrom", $Tsv, $true)
    $r = Find-ColumnRow $wsC 'customers' 'kana'
    Check ($wsC.Cells.Item($r, 15).Text -eq 'kata' -and $wsC.Cells.Item($r, 16).Text -eq '20') "再取込でも入力済みの設定を引き継ぐ"
    $wb.Close($false)
}
catch {
    Write-Host ("  例外: " + $_.Exception.Message + " (行 " + $_.InvocationInfo.ScriptLineNumber + ": " + $_.InvocationInfo.Line.Trim() + ")")
    $failed++
}
finally {
    foreach ($w in @($excel.Workbooks)) { try { $w.Close($false) } catch { } }
    try { $excel.Quit() } catch { }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
}
Write-Host ""
if ($failed -eq 0) { Write-Host "Excel テスト: すべて OK" } else { Write-Host "Excel テスト: NG $failed 件"; exit 1 }
