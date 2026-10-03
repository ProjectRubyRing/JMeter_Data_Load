<#
.SYNOPSIS
  VBA ソース (excel\vba) から設定用ブック DataGenConfig.xlsm を作成します。

.DESCRIPTION
  Excel (COM) で新しいブックを作り、VBA モジュールを組み込んでシートを初期化し、
  マクロ有効ブック (.xlsm) として保存します。
  VBA を組み込むために Excel の「VBA プロジェクト オブジェクト モデルへのアクセスを信頼する」
  (HKCU の AccessVBOM) を一時的に有効にし、終了時に必ず元の状態に戻します。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\build_xlsm.ps1
#>
param(
    [string]$Output = (Join-Path $PSScriptRoot 'DataGenConfig.xlsm'),
    [string]$CopyTo = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dbtool\templates\DataGenConfig.xlsm')
)
$ErrorActionPreference = 'Stop'

$vbaDir = Join-Path $PSScriptRoot 'vba'
$modulePath = Join-Path $vbaDir 'modDataGen.bas'
$thisWbPath = Join-Path $vbaDir 'ThisWorkbook.cls'

function Read-VbaSource([string]$path) {
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    # Attribute 行は AddFromString では使えないため除去し、改行を CRLF に統一
    $lines = $text -split "`r?`n" | Where-Object { $_ -notmatch '^\s*Attribute\s+VB_' }
    return ($lines -join "`r`n")
}

# ---- AccessVBOM を一時的に有効化 -------------------------------------------------
$officeVersions = @('16.0')
$saved = @{}
foreach ($v in $officeVersions) {
    $key = "HKCU:\Software\Microsoft\Office\$v\Excel\Security"
    $existed = Test-Path $key
    $old = $null
    if ($existed) { $old = (Get-ItemProperty -Path $key -Name AccessVBOM -ErrorAction SilentlyContinue).AccessVBOM }
    $saved[$v] = @{ Key = $key; KeyExisted = $existed; Old = $old }
    if (-not $existed) { New-Item -Path $key -Force | Out-Null }
    Set-ItemProperty -Path $key -Name AccessVBOM -Value 1 -Type DWord
}

$excel = $null
$wb = $null
try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $wb = $excel.Workbooks.Add()

    $vbp = $wb.VBProject
    $module = $vbp.VBComponents.Add(1)          # vbext_ct_StdModule
    $module.Name = 'modDataGen'
    $cm = $module.CodeModule
    if ($cm.CountOfLines -gt 0) { $cm.DeleteLines(1, $cm.CountOfLines) }
    $cm.AddFromString((Read-VbaSource $modulePath))

    $thisWb = $vbp.VBComponents.Item('ThisWorkbook')
    $cm2 = $thisWb.CodeModule
    if ($cm2.CountOfLines -gt 0) { $cm2.DeleteLines(1, $cm2.CountOfLines) }
    $cm2.AddFromString((Read-VbaSource $thisWbPath))

    # シートの初期化 (VBA の InitTemplate を実行。コンパイルエラーがあればここで失敗する)
    $excel.Run("'" + $wb.Name + "'!InitTemplate")

    if (Test-Path $Output) { Remove-Item $Output -Force }
    $wb.SaveAs($Output, 52)                     # xlOpenXMLWorkbookMacroEnabled
    $wb.Close($false)
    $wb = $null
    Write-Host "作成しました: $Output"

    if ($CopyTo) {
        $dir = Split-Path $CopyTo -Parent
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item $Output $CopyTo -Force
        Write-Host "コピーしました: $CopyTo"
    }
}
finally {
    if ($wb) { try { $wb.Close($false) } catch { } }
    if ($excel) {
        try { $excel.Quit() } catch { }
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    # AccessVBOM を元に戻す
    foreach ($v in $saved.Keys) {
        $s = $saved[$v]
        if ($null -eq $s.Old) {
            Remove-ItemProperty -Path $s.Key -Name AccessVBOM -ErrorAction SilentlyContinue
        } else {
            Set-ItemProperty -Path $s.Key -Name AccessVBOM -Value $s.Old -Type DWord
        }
        if (-not $s.KeyExisted) {
            $remaining = (Get-Item $s.Key).Property
            if (-not $remaining) { Remove-Item -Path $s.Key -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Host "Excel の AccessVBOM 設定を元に戻しました"
}
