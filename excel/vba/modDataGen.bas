Attribute VB_Name = "modDataGen"
'==============================================================================
' modDataGen : dbtool テストデータ生成設定ブック (DataGenConfig.xlsm)
'   - スキーマ情報 (_schema シート / スキーマ TSV) から「テーブル設定」「列設定」を作成
'   - 入力チェック
'   - 設定ファイル (.conf : UTF-8 BOMなし / 改行LF / TAB区切り) の出力
'==============================================================================
Option Explicit

Public Const TOOL_VERSION As String = "1.0.0"
Public Const SH_USAGE As String = "使い方"
Public Const SH_GLOBAL As String = "共通設定"
Public Const SH_TABLES As String = "テーブル設定"
Public Const SH_COLUMNS As String = "列設定"
Public Const SH_RULES As String = "生成方式一覧"
Public Const SH_SCHEMA As String = "_schema"

Private Const MAGIC_SCHEMA As String = "#DBTOOL-SCHEMA"
Private Const MAGIC_CONFIG As String = "#DBTOOL-DATAGEN-CONFIG"
Private Const STAMP_NAME As String = "DBT_SCHEMA_STAMP"
Private Const FIRST_ROW As Long = 3

' テーブル設定の列
Private Const T_EN As Long = 1, T_NAME As Long = 2, T_ORDER As Long = 3, T_ROWS As Long = 4
Private Const T_BEFORE As Long = 5, T_BACKUP As Long = 6, T_CLEAN As Long = 7, T_WHERE As Long = 8
Private Const T_SEED As Long = 9, T_JMROWS As Long = 10, T_ESTROWS As Long = 11, T_AI As Long = 12
Private Const T_PK As Long = 13, T_FK As Long = 14, T_REFBY As Long = 15, T_CHECK As Long = 16
Private Const T_TRIG As Long = 17, T_ENGINE As Long = 18, T_COMMENT As Long = 19, T_LAST As Long = 19

' 列設定の列
Private Const C_TABLE As Long = 1, C_POS As Long = 2, C_NAME As Long = 3, C_TYPE As Long = 4
Private Const C_NULL As Long = 5, C_KEY As Long = 6, C_IDX As Long = 7, C_DEF As Long = 8
Private Const C_EXTRA As Long = 9, C_FK As Long = 10, C_COMMENT As Long = 11, C_RULE As Long = 12
Private Const C_P1 As Long = 13, C_P2 As Long = 14, C_P3 As Long = 15, C_NULLR As Long = 16
Private Const C_JM As Long = 17, C_HELP As Long = 18, C_NOTE As Long = 19, C_LAST As Long = 19

' 共通設定 (A=項目 B=設定値 C=キー D=説明)
Private Const G_FIRST As Long = 4

Private Const RULE_NAMES As String = "SEQ,TEMPLATE,RANDOM_INT,RANDOM_DECIMAL,UNIQUE_INT,RANDOM_STRING,UNIQUE_STRING,UUID,LIST,CYCLE,RANDOM_DATE,RANDOM_DATETIME,RANDOM_TIME,SEQ_DATETIME,REF,RANDOM_BYTES,FIXED,COPY,NULL,DEFAULT"

' 色
Private Function ColorHeader() As Long
    ColorHeader = RGB(31, 78, 121)
End Function
Private Function ColorReadOnly() As Long
    ColorReadOnly = RGB(242, 242, 242)
End Function
Private Function ColorEdit() As Long
    ColorEdit = RGB(255, 242, 204)
End Function
Private Function ColorError() As Long
    ColorError = RGB(255, 199, 206)
End Function
Private Function ColorTitle() As Long
    ColorTitle = RGB(221, 235, 247)
End Function

'==============================================================================
' ボタン用マクロ
'==============================================================================

' [設定ファイル出力]
Public Sub ExportConfig()
    Dim defName As String, path As Variant, n As Long
    defName = Trim$(GlobalValue("#output_file"))
    If defName = "" Then
        defName = Trim$(GlobalValue("database"))
        If defName = "" Then defName = "datagen"
        defName = defName & "_datagen.conf"
    End If
    If ThisWorkbook.Path <> "" Then defName = ThisWorkbook.Path & Application.PathSeparator & defName
    path = Application.GetSaveAsFilename(InitialFileName:=defName, FileFilter:="設定ファイル (*.conf),*.conf,すべてのファイル (*.*),*.*", Title:="設定ファイルの出力先")
    If VarType(path) = vbBoolean Then Exit Sub
    n = ExportConfigTo(CStr(path), False)
End Sub

' [入力チェック]
Public Sub CheckInput()
    Dim errs As Collection
    Set errs = New Collection
    ValidateAll errs
    If errs.Count = 0 Then
        MsgBox "入力チェック OK です。" & vbLf & vbLf & "※ 値の範囲やデータ型との整合性などの詳細なチェックは、サーバーで" & vbLf & "   dbtool.sh validate -c <設定ファイル> を実行して確認してください。", vbInformation, "入力チェック"
    Else
        ShowErrors errs, "入力チェック"
    End If
End Sub

' [スキーマ取込] (dbtool.sh schema --tsv-only で作成した TSV を読み込む)
Public Sub ImportSchemaFile()
    Dim path As Variant
    path = Application.GetOpenFilename(FileFilter:="スキーマ情報 (*.tsv),*.tsv,すべてのファイル (*.*),*.*", Title:="スキーマ情報 (TSV) の選択")
    If VarType(path) = vbBoolean Then Exit Sub
    ImportSchemaFrom CStr(path), False
End Sub

' [シートを再作成] (_schema シートの内容から作り直す。入力済みの設定は引き継ぐ)
Public Sub RebuildSheets()
    If Not HasSchema() Then
        MsgBox "スキーマ情報がありません。[スキーマ取込] で TSV を読み込んでください。", vbExclamation
        Exit Sub
    End If
    If MsgBox("スキーマ情報からテーブル設定・列設定シートを作り直します。" & vbLf & "入力済みの設定は (データ型が同じ列は) 引き継ぎます。よろしいですか？", vbOKCancel + vbQuestion) <> vbOK Then Exit Sub
    BuildFromSchemaSheet True, False
End Sub

'==============================================================================
' ブックを開いたときの自動展開
'==============================================================================
Public Sub AutoBuildOnOpen()
    If Not HasSchema() Then Exit Sub
    If SchemaStamp() = CurrentStamp() Then Exit Sub
    BuildFromSchemaSheet True, False
End Sub

Private Function HasSchema() As Boolean
    Dim ws As Worksheet
    Set ws = GetSheet(SH_SCHEMA)
    If ws Is Nothing Then Exit Function
    HasSchema = (CStr(ws.Cells(1, 1).Value) = MAGIC_SCHEMA)
End Function

Private Function SchemaStamp() As String
    Dim ws As Worksheet, r As Long, lastRow As Long, db As String, ts As String
    Set ws = GetSheet(SH_SCHEMA)
    lastRow = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    For r = 1 To lastRow
        If CStr(ws.Cells(r, 1).Value) = "INFO" Then
            If CStr(ws.Cells(r, 2).Value) = "database" Then db = CStr(ws.Cells(r, 3).Value)
            If CStr(ws.Cells(r, 2).Value) = "generated_at" Then ts = CStr(ws.Cells(r, 3).Value)
        ElseIf CStr(ws.Cells(r, 1).Value) = "TABLE" Then
            Exit For
        End If
    Next r
    SchemaStamp = db & "|" & ts
End Function

Private Function CurrentStamp() As String
    On Error Resume Next
    CurrentStamp = Mid$(ThisWorkbook.Names(STAMP_NAME).RefersTo, 3)
    If Len(CurrentStamp) > 0 Then CurrentStamp = Left$(CurrentStamp, Len(CurrentStamp) - 1)
End Function

Private Sub SetStamp(ByVal v As String)
    On Error Resume Next
    ThisWorkbook.Names(STAMP_NAME).Delete
    On Error GoTo 0
    ThisWorkbook.Names.Add Name:=STAMP_NAME, RefersTo:="=""" & Replace(v, """", """""") & """", Visible:=False
End Sub

'==============================================================================
' スキーマ TSV の取込
'==============================================================================
Public Function ImportSchemaFrom(ByVal path As String, Optional ByVal silent As Boolean = True) As Boolean
    Dim text As String, lines() As String, i As Long, n As Long, f() As String, j As Long
    Dim data() As Variant, maxCols As Long, ws As Worksheet
    text = ReadUtf8(path)
    text = Replace(text, vbCr, "")
    lines = Split(text, vbLf)
    n = UBound(lines) + 1
    Do While n > 0
        If lines(n - 1) <> "" Then Exit Do
        n = n - 1
    Loop
    If n = 0 Then GoTo BadFile
    If Left$(lines(0), Len(MAGIC_SCHEMA) + 1) <> MAGIC_SCHEMA & vbTab Then GoTo BadFile
    maxCols = 1
    For i = 0 To n - 1
        j = UBound(Split(lines(i), vbTab)) + 1
        If j > maxCols Then maxCols = j
    Next i
    ReDim data(1 To n, 1 To maxCols)
    For i = 0 To n - 1
        f = Split(lines(i), vbTab)
        For j = 0 To UBound(f)
            data(i + 1, j + 1) = TsvUnescape(f(j))
        Next j
    Next i
    Set ws = GetSheet(SH_SCHEMA)
    ws.Cells.Clear
    ws.Range(ws.Cells(1, 1), ws.Cells(n, maxCols)).NumberFormat = "@"
    ws.Range(ws.Cells(1, 1), ws.Cells(n, maxCols)).Value = data
    BuildFromSchemaSheet True, silent
    ImportSchemaFrom = True
    Exit Function
BadFile:
    If Not silent Then MsgBox "スキーマ情報の TSV ではありません (1行目が " & MAGIC_SCHEMA & " ではありません):" & vbLf & path, vbExclamation
End Function

'==============================================================================
' _schema シートからテーブル設定・列設定を作成
'==============================================================================
Public Sub BuildFromSchemaSheet(Optional ByVal keepSettings As Boolean = True, Optional ByVal silent As Boolean = True)
    Dim src As Variant, ws As Worksheet, lastRow As Long, lastCol As Long, r As Long
    Dim info As Object, oldT As Object, oldC As Object
    Dim nT As Long, nC As Long, tData() As Variant, cData() As Variant, k As String, v As Variant
    Dim prevCalc As Long, prevEvents As Boolean, prevUpdate As Boolean, changedTypes As Long

    Set ws = GetSheet(SH_SCHEMA)
    If ws Is Nothing Then Err.Raise vbObjectError + 1, , "シート " & SH_SCHEMA & " がありません"
    lastRow = ws.Cells(ws.Rows.Count, 1).End(xlUp).Row
    lastCol = 19
    If lastRow < 2 Then Err.Raise vbObjectError + 2, , "スキーマ情報が空です"
    src = ws.Range(ws.Cells(1, 1), ws.Cells(lastRow, lastCol)).Value
    If CStr(src(1, 1)) <> MAGIC_SCHEMA Then Err.Raise vbObjectError + 3, , "スキーマ情報の形式が不正です"

    prevUpdate = Application.ScreenUpdating: prevEvents = Application.EnableEvents
    prevCalc = Application.Calculation
    Application.ScreenUpdating = False: Application.EnableEvents = False
    Application.Calculation = xlCalculationManual
    On Error GoTo Fail

    Set info = CreateObject("Scripting.Dictionary")
    For r = 1 To lastRow
        Select Case CStr(src(r, 1))
            Case "INFO": info(CStr(src(r, 2))) = CStr(src(r, 3))
            Case "TABLE": nT = nT + 1
            Case "COLUMN": nC = nC + 1
        End Select
    Next r
    If nT = 0 Then Err.Raise vbObjectError + 4, , "スキーマ情報にテーブルがありません"

    Set oldT = CreateObject("Scripting.Dictionary")
    Set oldC = CreateObject("Scripting.Dictionary")
    If keepSettings Then CaptureSettings oldT, oldC

    ' ---- テーブル設定 ----
    ReDim tData(1 To nT, 1 To T_LAST)
    Dim i As Long: i = 0
    For r = 1 To lastRow
        If CStr(src(r, 1)) = "TABLE" Then
            i = i + 1
            k = CStr(src(r, 2))
            tData(i, T_NAME) = k
            If oldT.Exists(k) Then
                v = oldT(k)
                tData(i, T_EN) = v(0): tData(i, T_ORDER) = v(1): tData(i, T_ROWS) = v(2): tData(i, T_BEFORE) = v(3)
                tData(i, T_BACKUP) = v(4): tData(i, T_CLEAN) = v(5): tData(i, T_WHERE) = v(6): tData(i, T_SEED) = v(7): tData(i, T_JMROWS) = v(8)
            Else
                tData(i, T_EN) = "Y": tData(i, T_ORDER) = ToNum(src(r, 3)): tData(i, T_ROWS) = ToNum(src(r, 4))
                tData(i, T_BEFORE) = CStr(src(r, 5)): tData(i, T_BACKUP) = CStr(src(r, 6)): tData(i, T_CLEAN) = CStr(src(r, 7))
                tData(i, T_WHERE) = CStr(src(r, 8)): tData(i, T_SEED) = ToNum(src(r, 9)): tData(i, T_JMROWS) = ToNum(src(r, 10))
            End If
            tData(i, T_ENGINE) = CStr(src(r, 11)): tData(i, T_ESTROWS) = ToNum(src(r, 12)): tData(i, T_AI) = ToNum(src(r, 13))
            tData(i, T_PK) = CStr(src(r, 14)): tData(i, T_FK) = CStr(src(r, 15)): tData(i, T_REFBY) = CStr(src(r, 16))
            tData(i, T_CHECK) = CStr(src(r, 17)): tData(i, T_TRIG) = CStr(src(r, 18)): tData(i, T_COMMENT) = CStr(src(r, 19))
        End If
    Next r

    ' ---- 列設定 ----
    ReDim cData(1 To IIf(nC = 0, 1, nC), 1 To C_LAST)
    i = 0
    For r = 1 To lastRow
        If CStr(src(r, 1)) = "COLUMN" Then
            i = i + 1
            cData(i, C_TABLE) = CStr(src(r, 2)): cData(i, C_POS) = ToNum(src(r, 3)): cData(i, C_NAME) = CStr(src(r, 4))
            cData(i, C_TYPE) = CStr(src(r, 5)): cData(i, C_NULL) = CStr(src(r, 6)): cData(i, C_KEY) = CStr(src(r, 7))
            cData(i, C_IDX) = CStr(src(r, 8)): cData(i, C_DEF) = CStr(src(r, 9)): cData(i, C_EXTRA) = CStr(src(r, 10))
            cData(i, C_FK) = CStr(src(r, 11)): cData(i, C_COMMENT) = CStr(src(r, 12)): cData(i, C_NOTE) = CStr(src(r, 19))
            k = CStr(src(r, 2)) & vbTab & CStr(src(r, 4))
            If oldC.Exists(k) Then v = oldC(k) Else v = Empty
            If Not IsEmpty(v) Then
                If CStr(v(0)) = CStr(src(r, 5)) Then
                    cData(i, C_RULE) = v(1): cData(i, C_P1) = v(2): cData(i, C_P2) = v(3): cData(i, C_P3) = v(4): cData(i, C_NULLR) = v(5): cData(i, C_JM) = v(6)
                Else
                    v = Empty
                    changedTypes = changedTypes + 1
                    cData(i, C_NOTE) = "【データ型が変更されたため初期値に戻しました】" & cData(i, C_NOTE)
                End If
            End If
            If IsEmpty(v) Then
                cData(i, C_RULE) = CStr(src(r, 13)): cData(i, C_P1) = CStr(src(r, 14)): cData(i, C_P2) = CStr(src(r, 15))
                cData(i, C_P3) = CStr(src(r, 16)): cData(i, C_NULLR) = ToNum(src(r, 17)): cData(i, C_JM) = CStr(src(r, 18))
            End If
        End If
    Next r

    WriteTablesSheet tData, nT
    WriteColumnsSheet cData, nC
    WriteGlobalSheet info, keepSettings
    SetStamp SchemaStamp()

    Application.Calculation = prevCalc
    Application.EnableEvents = prevEvents: Application.ScreenUpdating = prevUpdate
    GetSheet(SH_TABLES).Activate
    If Not silent And Application.Visible Then
        MsgBox "スキーマ情報を展開しました。" & vbLf & vbLf & _
               "データベース: " & info("database") & vbLf & _
               "テーブル: " & nT & " / 列: " & nC & vbLf & _
               "取得日時: " & info("generated_at") & _
               IIf(changedTypes > 0, vbLf & vbLf & "※ データ型が変更された列が " & changedTypes & " 件あり、その列の設定は初期値に戻しました。", ""), vbInformation, "スキーマ情報の展開"
    End If
    Exit Sub
Fail:
    Application.Calculation = prevCalc
    Application.EnableEvents = prevEvents: Application.ScreenUpdating = prevUpdate
    Err.Raise Err.Number, , Err.Description
End Sub

' 既存の入力値を退避 (テーブル名 / テーブル名+列名 をキーに)
Private Sub CaptureSettings(ByVal oldT As Object, ByVal oldC As Object)
    Dim ws As Worksheet, lastRow As Long, r As Long, a As Variant
    Set ws = GetSheet(SH_TABLES)
    lastRow = ws.Cells(ws.Rows.Count, T_NAME).End(xlUp).Row
    If lastRow >= FIRST_ROW Then
        a = ws.Range(ws.Cells(FIRST_ROW, 1), ws.Cells(lastRow, T_LAST)).Value
        For r = 1 To UBound(a, 1)
            If CStr(a(r, T_NAME)) <> "" Then
                oldT(CStr(a(r, T_NAME))) = Array(a(r, T_EN), a(r, T_ORDER), a(r, T_ROWS), a(r, T_BEFORE), a(r, T_BACKUP), a(r, T_CLEAN), a(r, T_WHERE), a(r, T_SEED), a(r, T_JMROWS))
            End If
        Next r
    End If
    Set ws = GetSheet(SH_COLUMNS)
    lastRow = ws.Cells(ws.Rows.Count, C_NAME).End(xlUp).Row
    If lastRow >= FIRST_ROW Then
        a = ws.Range(ws.Cells(FIRST_ROW, 1), ws.Cells(lastRow, C_LAST)).Value
        For r = 1 To UBound(a, 1)
            If CStr(a(r, C_NAME)) <> "" Then
                oldC(CStr(a(r, C_TABLE)) & vbTab & CStr(a(r, C_NAME))) = Array(a(r, C_TYPE), a(r, C_RULE), a(r, C_P1), a(r, C_P2), a(r, C_P3), a(r, C_NULLR), a(r, C_JM))
            End If
        Next r
    End If
End Sub

Private Sub WriteTablesSheet(ByRef tData() As Variant, ByVal nT As Long)
    Dim ws As Worksheet, lastRow As Long, rng As Range
    Set ws = GetSheet(SH_TABLES)
    ClearData ws, T_LAST
    Set rng = ws.Range(ws.Cells(FIRST_ROW, 1), ws.Cells(FIRST_ROW + nT - 1, T_LAST))
    rng.NumberFormat = "@"
    ws.Range(ws.Cells(FIRST_ROW, T_ORDER), ws.Cells(FIRST_ROW + nT - 1, T_ROWS)).NumberFormat = "#,##0"
    ws.Range(ws.Cells(FIRST_ROW, T_SEED), ws.Cells(FIRST_ROW + nT - 1, T_SEED)).NumberFormat = "0"
    ws.Range(ws.Cells(FIRST_ROW, T_JMROWS), ws.Cells(FIRST_ROW + nT - 1, T_AI)).NumberFormat = "#,##0"
    rng.Value = tData
    FormatDataArea ws, nT, T_LAST, Array(T_EN, T_ORDER, T_ROWS, T_BEFORE, T_BACKUP, T_CLEAN, T_WHERE, T_SEED, T_JMROWS)
    AddListValidation ws.Range(ws.Cells(FIRST_ROW, T_EN), ws.Cells(FIRST_ROW + nT - 1, T_EN)), "Y,N"
    AddListValidation ws.Range(ws.Cells(FIRST_ROW, T_BACKUP), ws.Cells(FIRST_ROW + nT - 1, T_BACKUP)), "Y,N"
    AddListValidation ws.Range(ws.Cells(FIRST_ROW, T_BEFORE), ws.Cells(FIRST_ROW + nT - 1, T_BEFORE)), "NONE,TRUNCATE,DELETE"
    AddListValidation ws.Range(ws.Cells(FIRST_ROW, T_CLEAN), ws.Cells(FIRST_ROW + nT - 1, T_CLEAN)), "RESTORE,DELETE_GENERATED,DELETE_WHERE,TRUNCATE,NONE"
    AddWholeValidation ws.Range(ws.Cells(FIRST_ROW, T_ORDER), ws.Cells(FIRST_ROW + nT - 1, T_ORDER)), -999999, 999999
    AddWholeValidation ws.Range(ws.Cells(FIRST_ROW, T_ROWS), ws.Cells(FIRST_ROW + nT - 1, T_ROWS)), 0, 2000000000
    AddWholeValidation ws.Range(ws.Cells(FIRST_ROW, T_SEED), ws.Cells(FIRST_ROW + nT - 1, T_SEED)), 0, 2147483647
    AddWholeValidation ws.Range(ws.Cells(FIRST_ROW, T_JMROWS), ws.Cells(FIRST_ROW + nT - 1, T_JMROWS)), 0, 2000000000
    ws.Range(ws.Cells(FIRST_ROW, T_PK), ws.Cells(FIRST_ROW + nT - 1, T_COMMENT)).WrapText = False
End Sub

Private Sub WriteColumnsSheet(ByRef cData() As Variant, ByVal nC As Long)
    Dim ws As Worksheet, rng As Range, r As Long, prevT As String
    Set ws = GetSheet(SH_COLUMNS)
    ClearData ws, C_LAST
    If nC = 0 Then Exit Sub
    Set rng = ws.Range(ws.Cells(FIRST_ROW, 1), ws.Cells(FIRST_ROW + nC - 1, C_LAST))
    rng.NumberFormat = "@"
    ws.Range(ws.Cells(FIRST_ROW, C_POS), ws.Cells(FIRST_ROW + nC - 1, C_POS)).NumberFormat = "0"
    ws.Range(ws.Cells(FIRST_ROW, C_NULLR), ws.Cells(FIRST_ROW + nC - 1, C_NULLR)).NumberFormat = "General"
    rng.Value = cData
    ws.Range(ws.Cells(FIRST_ROW, C_HELP), ws.Cells(FIRST_ROW + nC - 1, C_HELP)).NumberFormat = "General"
    ws.Range(ws.Cells(FIRST_ROW, C_HELP), ws.Cells(FIRST_ROW + nC - 1, C_HELP)).FormulaR1C1 = _
        "=IFERROR(VLOOKUP(RC" & C_RULE & ",'" & SH_RULES & "'!C1:C9,9,FALSE),"""")"
    FormatDataArea ws, nC, C_LAST, Array(C_RULE, C_P1, C_P2, C_P3, C_NULLR, C_JM)
    AddFormulaListValidation ws.Range(ws.Cells(FIRST_ROW, C_RULE), ws.Cells(FIRST_ROW + nC - 1, C_RULE)), "=RuleList"
    AddListValidation ws.Range(ws.Cells(FIRST_ROW, C_JM), ws.Cells(FIRST_ROW + nC - 1, C_JM)), "Y,N"
    With ws.Range(ws.Cells(FIRST_ROW, C_NULLR), ws.Cells(FIRST_ROW + nC - 1, C_NULLR)).Validation
        .Delete
        .Add Type:=xlValidateDecimal, AlertStyle:=xlValidAlertStop, Operator:=xlBetween, Formula1:="0", Formula2:="100"
        .ErrorMessage = "0～100 の数値を入力してください"
    End With
    ' テーブルの区切りに罫線
    prevT = ""
    For r = FIRST_ROW To FIRST_ROW + nC - 1
        If CStr(ws.Cells(r, C_TABLE).Value) <> prevT Then
            If r > FIRST_ROW Then
                With ws.Range(ws.Cells(r, 1), ws.Cells(r, C_LAST)).Borders(xlEdgeTop)
                    .LineStyle = xlContinuous: .Weight = xlMedium: .Color = RGB(31, 78, 121)
                End With
            End If
            prevT = CStr(ws.Cells(r, C_TABLE).Value)
        End If
    Next r
End Sub

Private Sub WriteGlobalSheet(ByVal info As Object, ByVal keepSettings As Boolean)
    Dim ws As Worksheet, items As Variant, i As Long, r As Long, key As String, cur As String
    Set ws = GetSheet(SH_GLOBAL)
    items = GlobalItems()
    For i = 0 To UBound(items)
        r = G_FIRST + i
        key = items(i)(0)
        cur = CellText(ws.Cells(r, 2).Value)
        If key = "database" Then
            ws.Cells(r, 2).Value = info("database")
        ElseIf (Not keepSettings) Or cur = "" Then
            ws.Cells(r, 2).Value = items(i)(2)
        End If
    Next i
    r = G_FIRST + UBound(items) + 3
    ws.Cells(r, 2).Value = info("generated_at")
    ws.Cells(r + 1, 2).Value = info("server_host") & " (MySQL " & info("server_version") & ")"
    ws.Cells(r + 2, 2).Value = info("tool_version")
End Sub

'==============================================================================
' 入力チェック
'==============================================================================
Private Sub ValidateAll(ByVal errs As Collection)
    Dim ws As Worksheet, items As Variant, i As Long, r As Long, key As String, v As String, lastRow As Long
    Dim tabs As Object, t As String, a As Variant, rules As Object, rn As Variant

    ' 共通設定
    Set ws = GetSheet(SH_GLOBAL)
    items = GlobalItems()
    For i = 0 To UBound(items)
        r = G_FIRST + i: key = items(i)(0)
        ws.Cells(r, 2).Interior.Color = ColorEdit()
        If key = "database" Then ws.Cells(r, 2).Interior.Color = ColorReadOnly()
        v = Trim$(CellText(ws.Cells(r, 2).Value))
        Select Case key
            Case "database": If v = "" Then AddErr errs, ws.Cells(r, 2), "共通設定: データベース名が空です"
            Case "rows_per_file": If Not IsIntIn(v, 1, 100000000#) Then AddErr errs, ws.Cells(r, 2), "共通設定: ファイル分割件数は 1～100000000 の整数です"
            Case "parallel": If Not IsIntIn(v, 1, 32) Then AddErr errs, ws.Cells(r, 2), "共通設定: 並列数は 1～32 の整数です"
            Case "fk_checks": If v <> "ON" And v <> "OFF" Then AddErr errs, ws.Cells(r, 2), "共通設定: 外部キー検査は ON / OFF です"
            Case "on_warning": If v <> "ROLLBACK" And v <> "CONTINUE" Then AddErr errs, ws.Cells(r, 2), "共通設定: 警告時の動作は ROLLBACK / CONTINUE です"
            Case "time_zone"
                If v <> "" And Not (v Like "[+-]#:##" Or v Like "[+-]##:##" Or v Like "[A-Za-z]*/*" Or UCase$(v) = "UTC" Or UCase$(v) = "SYSTEM") Then AddErr errs, ws.Cells(r, 2), "共通設定: タイムゾーンの書式が不正です (例: +09:00, Asia/Tokyo)"
            Case "base_datetime"
                If v <> "" And Not (v Like "####-##-## ##:##:##" Or v Like "####-##-##") Then AddErr errs, ws.Cells(r, 2), "共通設定: 基準日時は YYYY-MM-DD HH:MM:SS で入力してください"
        End Select
    Next i

    ' テーブル設定
    Set ws = GetSheet(SH_TABLES)
    Set tabs = CreateObject("Scripting.Dictionary")
    lastRow = ws.Cells(ws.Rows.Count, T_NAME).End(xlUp).Row
    For r = FIRST_ROW To lastRow
        t = CellText(ws.Cells(r, T_NAME).Value)
        If t <> "" Then
            ResetEditColors ws, r, Array(T_EN, T_ORDER, T_ROWS, T_BEFORE, T_BACKUP, T_CLEAN, T_WHERE, T_SEED, T_JMROWS)
            If tabs.Exists(t) Then AddErr errs, ws.Cells(r, T_NAME), "テーブル設定 " & r & " 行目: テーブル " & t & " が重複しています"
            tabs(t) = UCase$(Trim$(CellText(ws.Cells(r, T_EN).Value)))
            If tabs(t) <> "Y" And tabs(t) <> "N" Then AddErr errs, ws.Cells(r, T_EN), t & ": 対象は Y / N です"
            If tabs(t) = "Y" Then
                If Not IsIntIn(CellText(ws.Cells(r, T_ORDER).Value), -999999, 999999) Then AddErr errs, ws.Cells(r, T_ORDER), t & ": 処理順は整数です"
                If Not IsIntIn(CellText(ws.Cells(r, T_ROWS).Value), 0, 10000000000#) Then AddErr errs, ws.Cells(r, T_ROWS), t & ": 生成件数は 0 以上の整数です"
                v = UCase$(Trim$(CellText(ws.Cells(r, T_BEFORE).Value)))
                If v <> "NONE" And v <> "TRUNCATE" And v <> "DELETE" Then AddErr errs, ws.Cells(r, T_BEFORE), t & ": 事前処理は NONE / TRUNCATE / DELETE です"
                v = UCase$(Trim$(CellText(ws.Cells(r, T_BACKUP).Value)))
                If v <> "Y" And v <> "N" Then AddErr errs, ws.Cells(r, T_BACKUP), t & ": 事前バックアップは Y / N です"
                key = UCase$(Trim$(CellText(ws.Cells(r, T_CLEAN).Value)))
                If InStr(",RESTORE,DELETE_GENERATED,DELETE_WHERE,TRUNCATE,NONE,", "," & key & ",") = 0 Then AddErr errs, ws.Cells(r, T_CLEAN), t & ": 後片付けの値が不正です"
                If key = "RESTORE" And v <> "Y" Then AddErr errs, ws.Cells(r, T_CLEAN), t & ": 後片付け RESTORE には 事前バックアップ=Y が必要です"
                If key = "DELETE_WHERE" And Trim$(CellText(ws.Cells(r, T_WHERE).Value)) = "" Then AddErr errs, ws.Cells(r, T_WHERE), t & ": DELETE_WHERE には後片付け条件 (WHERE) が必要です"
                If InStr(CellText(ws.Cells(r, T_WHERE).Value), ";") > 0 Then AddErr errs, ws.Cells(r, T_WHERE), t & ": 後片付け条件にセミコロンは使用できません"
                v = Trim$(CellText(ws.Cells(r, T_SEED).Value))
                If v <> "" And Not IsIntIn(v, 0, 2147483647) Then AddErr errs, ws.Cells(r, T_SEED), t & ": 乱数シードは 0～2147483647 の整数です"
                v = Trim$(CellText(ws.Cells(r, T_JMROWS).Value))
                If v <> "" And Not IsIntIn(v, 0, 10000000000#) Then AddErr errs, ws.Cells(r, T_JMROWS), t & ": JMeter出力件数は 0 以上の整数です"
            End If
        End If
    Next r
    If tabs.Count = 0 Then errs.Add "テーブル設定にテーブルがありません"

    ' 列設定
    Set rules = CreateObject("Scripting.Dictionary")
    For Each rn In Split(RULE_NAMES, ","): rules(rn) = True: Next rn
    Set ws = GetSheet(SH_COLUMNS)
    lastRow = ws.Cells(ws.Rows.Count, C_NAME).End(xlUp).Row
    For r = FIRST_ROW To lastRow
        t = CellText(ws.Cells(r, C_TABLE).Value)
        If CellText(ws.Cells(r, C_NAME).Value) <> "" Then
            ResetEditColors ws, r, Array(C_RULE, C_P1, C_P2, C_P3, C_NULLR, C_JM)
            If tabs.Exists(t) Then
                If tabs(t) = "Y" Then
                    key = t & "." & CellText(ws.Cells(r, C_NAME).Value)
                    v = UCase$(Trim$(CellText(ws.Cells(r, C_RULE).Value)))
                    If v = "" Then
                        AddErr errs, ws.Cells(r, C_RULE), key & ": 生成方式が未入力です"
                    ElseIf Not rules.Exists(v) Then
                        AddErr errs, ws.Cells(r, C_RULE), key & ": 生成方式 " & v & " は使用できません"
                    End If
                    a = Trim$(CellText(ws.Cells(r, C_NULLR).Value))
                    If a <> "" Then
                        If Not IsNumeric(a) Then
                            AddErr errs, ws.Cells(r, C_NULLR), key & ": NULL率は 0～100 の数値です"
                        ElseIf CDbl(a) < 0 Or CDbl(a) > 100 Then
                            AddErr errs, ws.Cells(r, C_NULLR), key & ": NULL率は 0～100 の数値です"
                        ElseIf CDbl(a) > 0 And CellText(ws.Cells(r, C_NULL).Value) = "NO" Then
                            AddErr errs, ws.Cells(r, C_NULLR), key & ": NOT NULL 列に NULL率は指定できません"
                        End If
                    End If
                    If v = "NULL" And CellText(ws.Cells(r, C_NULL).Value) = "NO" Then AddErr errs, ws.Cells(r, C_RULE), key & ": NOT NULL 列に NULL は指定できません"
                    a = UCase$(Trim$(CellText(ws.Cells(r, C_JM).Value)))
                    If a <> "" And a <> "Y" And a <> "N" Then AddErr errs, ws.Cells(r, C_JM), key & ": JMeter出力は Y / N です"
                    If (v = "REF" Or v = "TEMPLATE" Or v = "LIST" Or v = "CYCLE" Or v = "COPY" Or v = "SEQ_DATETIME") And CellText(ws.Cells(r, C_P1).Value) = "" Then
                        AddErr errs, ws.Cells(r, C_P1), key & ": 生成方式 " & v & " にはパラメータ1 が必要です"
                    End If
                    If (v = "RANDOM_INT" Or v = "UNIQUE_INT" Or v = "RANDOM_DECIMAL" Or v = "RANDOM_BYTES") Then
                        If Trim$(CellText(ws.Cells(r, C_P1).Value)) = "" Or Trim$(CellText(ws.Cells(r, C_P2).Value)) = "" Then
                            AddErr errs, ws.Cells(r, C_P1), key & ": 生成方式 " & v & " には最小値 (パラメータ1) と最大値 (パラメータ2) が必要です"
                        End If
                    End If
                End If
            End If
        End If
    Next r
End Sub

Private Sub ResetEditColors(ByVal ws As Worksheet, ByVal r As Long, ByVal cols As Variant)
    Dim c As Variant
    For Each c In cols
        ws.Cells(r, c).Interior.Color = ColorEdit()
    Next c
End Sub

Private Sub AddErr(ByVal errs As Collection, ByVal cell As Range, ByVal msg As String)
    cell.Interior.Color = ColorError()
    errs.Add msg
End Sub

Private Sub ShowErrors(ByVal errs As Collection, ByVal title As String)
    Dim s As String, i As Long
    For i = 1 To errs.Count
        If i > 20 Then s = s & vbLf & "... ほか " & (errs.Count - 20) & " 件": Exit For
        s = s & vbLf & "・" & errs(i)
    Next i
    MsgBox "入力エラーが " & errs.Count & " 件あります (赤色のセル)。" & vbLf & s, vbExclamation, title
End Sub

'==============================================================================
' 設定ファイルの出力
'==============================================================================
' 戻り値: 入力エラーの件数 (0 なら出力成功)
Public Function ExportConfigTo(ByVal path As String, Optional ByVal silent As Boolean = True) As Long
    Dim errs As Collection, lines() As String, n As Long, ws As Worksheet, items As Variant, i As Long
    Dim r As Long, lastRow As Long, tabs As Object, t As String, nT As Long, nC As Long, s As String
    Set errs = New Collection
    ValidateAll errs
    If errs.Count > 0 Then
        If Not silent Then ShowErrors errs, "設定ファイル出力"
        ExportConfigTo = errs.Count
        Exit Function
    End If
    ReDim lines(0 To 99)
    AddLine lines, n, MAGIC_CONFIG & vbTab & "1"
    AddLine lines, n, "# dbtool テストデータ生成設定 (" & ThisWorkbook.Name & " で作成, 作成日時 " & Format$(Now, "yyyy-mm-dd hh:nn:ss") & ")"
    AddLine lines, n, "# スキーマ取得日時: " & GetSheet(SH_GLOBAL).Cells(G_FIRST + UBound(GlobalItems()) + 3, 2).Value
    AddLine lines, n, "# 形式: UTF-8 (BOMなし) / 改行 LF / TAB 区切り。値の \ TAB 改行 は \\ \t \n でエスケープ"
    AddLine lines, n, "# GLOBAL<TAB>キー<TAB>値"
    AddLine lines, n, "# TABLE<TAB>テーブル<TAB>対象<TAB>生成件数<TAB>処理順<TAB>事前処理<TAB>事前バックアップ<TAB>後片付け<TAB>後片付け条件<TAB>乱数シード<TAB>JMeter出力件数"
    AddLine lines, n, "# COLUMN<TAB>テーブル<TAB>列<TAB>データ型<TAB>生成方式<TAB>パラメータ1<TAB>パラメータ2<TAB>パラメータ3<TAB>NULL率<TAB>JMeter出力"
    Set ws = GetSheet(SH_GLOBAL)
    items = GlobalItems()
    For i = 0 To UBound(items)
        If Left$(items(i)(0), 1) <> "#" Then
            AddLine lines, n, "GLOBAL" & vbTab & items(i)(0) & vbTab & TsvEscape(Trim$(CellText(ws.Cells(G_FIRST + i, 2).Value)))
        End If
    Next i
    Set tabs = CreateObject("Scripting.Dictionary")
    Set ws = GetSheet(SH_TABLES)
    lastRow = ws.Cells(ws.Rows.Count, T_NAME).End(xlUp).Row
    For r = FIRST_ROW To lastRow
        t = CellText(ws.Cells(r, T_NAME).Value)
        If t <> "" Then
            tabs(t) = True: nT = nT + 1
            AddLine lines, n, "TABLE" & vbTab & TsvEscape(t) & vbTab & UpVal(ws.Cells(r, T_EN)) & vbTab & TxtVal(ws.Cells(r, T_ROWS)) & vbTab & TxtVal(ws.Cells(r, T_ORDER)) & vbTab & _
                UpVal(ws.Cells(r, T_BEFORE)) & vbTab & UpVal(ws.Cells(r, T_BACKUP)) & vbTab & UpVal(ws.Cells(r, T_CLEAN)) & vbTab & _
                TsvEscape(Trim$(CellText(ws.Cells(r, T_WHERE).Value))) & vbTab & TxtVal(ws.Cells(r, T_SEED)) & vbTab & TxtVal(ws.Cells(r, T_JMROWS))
        End If
    Next r
    Set ws = GetSheet(SH_COLUMNS)
    lastRow = ws.Cells(ws.Rows.Count, C_NAME).End(xlUp).Row
    For r = FIRST_ROW To lastRow
        t = CellText(ws.Cells(r, C_TABLE).Value)
        If CellText(ws.Cells(r, C_NAME).Value) <> "" And tabs.Exists(t) Then
            nC = nC + 1
            AddLine lines, n, "COLUMN" & vbTab & TsvEscape(t) & vbTab & TsvEscape(CellText(ws.Cells(r, C_NAME).Value)) & vbTab & _
                TsvEscape(CellText(ws.Cells(r, C_TYPE).Value)) & vbTab & UpVal(ws.Cells(r, C_RULE)) & vbTab & _
                TsvEscape(CellText(ws.Cells(r, C_P1).Value)) & vbTab & TsvEscape(CellText(ws.Cells(r, C_P2).Value)) & vbTab & _
                TsvEscape(CellText(ws.Cells(r, C_P3).Value)) & vbTab & TxtVal(ws.Cells(r, C_NULLR)) & vbTab & UpVal(ws.Cells(r, C_JM))
        End If
    Next r
    ReDim Preserve lines(0 To n - 1)
    s = Join(lines, vbLf) & vbLf
    WriteUtf8NoBom path, s
    If Not silent Then
        MsgBox "設定ファイルを出力しました。" & vbLf & vbLf & path & vbLf & vbLf & "テーブル " & nT & " / 列 " & nC & vbLf & vbLf & _
               "サーバーにコピーして次を実行してください:" & vbLf & "  dbtool.sh validate -c <設定ファイル>" & vbLf & "  dbtool.sh prepare -c <設定ファイル>", vbInformation, "設定ファイル出力"
    End If
    ExportConfigTo = 0
End Function

Private Sub AddLine(ByRef lines() As String, ByRef n As Long, ByVal s As String)
    If n > UBound(lines) Then ReDim Preserve lines(0 To UBound(lines) * 2 + 1)
    lines(n) = s
    n = n + 1
End Sub

' 大文字・前後空白除去
Private Function UpVal(ByVal c As Range) As String
    UpVal = TsvEscape(UCase$(Trim$(CellText(c.Value))))
End Function

' 数値などの値 (前後空白除去)
Private Function TxtVal(ByVal c As Range) As String
    TxtVal = TsvEscape(Trim$(CellText(c.Value)))
End Function

'==============================================================================
' テンプレートの初期化 (build_xlsm.ps1 から1回だけ実行)
'==============================================================================
Public Sub InitTemplate()
    Dim names As Variant, i As Long, ws As Worksheet
    names = Array(SH_USAGE, SH_GLOBAL, SH_TABLES, SH_COLUMNS, SH_RULES, SH_SCHEMA)
    Application.DisplayAlerts = False
    Do While ThisWorkbook.Worksheets.Count < UBound(names) + 1
        ThisWorkbook.Worksheets.Add After:=ThisWorkbook.Worksheets(ThisWorkbook.Worksheets.Count)
    Loop
    For i = 0 To UBound(names)
        ThisWorkbook.Worksheets(i + 1).Name = names(i)
    Next i
    Application.DisplayAlerts = True
    For Each ws In ThisWorkbook.Worksheets
        ws.Cells.Font.Name = "Meiryo UI"
        ws.Cells.Font.Size = 10
        ActiveWindowZoom ws
    Next ws
    InitRulesSheet
    InitGlobalSheet
    InitTablesSheet
    InitColumnsSheet
    InitUsageSheet
    With GetSheet(SH_SCHEMA)
        .Cells.NumberFormat = "@"
        .Visible = xlSheetHidden
    End With
    GetSheet(SH_USAGE).Activate
End Sub

Private Sub ActiveWindowZoom(ByVal ws As Worksheet)
    ws.Activate
    ActiveWindow.Zoom = 90
    ActiveWindow.DisplayGridlines = True
End Sub

Private Function GlobalItems() As Variant
    GlobalItems = Array( _
        Array("database", "データベース名", "", "対象のデータベース名 (スキーマ取得時の値。変更不可)"), _
        Array("rows_per_file", "ファイル分割件数", "100000", "生成する CSV を何件ごとのファイルに分けるか。1 ファイルを 1 トランザクションでロードします (目安: 5万～50万)"), _
        Array("parallel", "並列数", "2", "生成とロードを同時に行うファイル数 (1～32)。Aurora の ACU と相談して設定します"), _
        Array("fk_checks", "外部キー検査", "ON", "ON: ロード時に外部キーを検査 (参照先がない値はエラー) / OFF: 検査しない (高速)"), _
        Array("time_zone", "タイムゾーン", "", "ロード時のタイムゾーン (例: +09:00, Asia/Tokyo)。TIMESTAMP 列と NOW/TODAY の解釈に使用。空欄はサーバーの既定"), _
        Array("base_datetime", "基準日時", "", "NOW / TODAY の基準日時 (YYYY-MM-DD HH:MM:SS)。指定すると毎回同じデータになります。空欄は実行時の DB の現在日時"), _
        Array("on_warning", "警告時の動作", "ROLLBACK", "ROLLBACK: 警告や件数不一致が出たファイルをロールバックして中止 / CONTINUE: 警告があってもコミット"), _
        Array("#output_file", "出力ファイル名", "", "[設定ファイル出力] の既定のファイル名 (空欄は <データベース名>_datagen.conf)。設定ファイルには出力されません"))
End Function

Public Function GlobalValue(ByVal key As String) As String
    Dim items As Variant, i As Long
    items = GlobalItems()
    For i = 0 To UBound(items)
        If items(i)(0) = key Then GlobalValue = CellText(GetSheet(SH_GLOBAL).Cells(G_FIRST + i, 2).Value): Exit Function
    Next i
End Function

Private Sub InitGlobalSheet()
    Dim ws As Worksheet, items As Variant, i As Long, r As Long
    Set ws = GetSheet(SH_GLOBAL)
    ws.Cells.Clear
    TitleRow ws, "共通設定", 4
    ws.Range("A3:D3").Value = Array("項目", "設定値", "キー", "説明")
    HeaderStyle ws.Range("A3:D3")
    items = GlobalItems()
    For i = 0 To UBound(items)
        r = G_FIRST + i
        ws.Cells(r, 1).Value = items(i)(1)
        ws.Cells(r, 2).NumberFormat = "@"
        ws.Cells(r, 2).Value = items(i)(2)
        ws.Cells(r, 3).Value = items(i)(0)
        ws.Cells(r, 4).Value = items(i)(3)
        ws.Cells(r, 2).Interior.Color = ColorEdit()
        ws.Range(ws.Cells(r, 1), ws.Cells(r, 1)).Interior.Color = ColorReadOnly()
        ws.Range(ws.Cells(r, 3), ws.Cells(r, 4)).Interior.Color = ColorReadOnly()
        If items(i)(0) = "fk_checks" Then AddListValidation ws.Cells(r, 2), "ON,OFF"
        If items(i)(0) = "on_warning" Then AddListValidation ws.Cells(r, 2), "ROLLBACK,CONTINUE"
        If items(i)(0) = "database" Then ws.Cells(r, 2).Interior.Color = ColorReadOnly()
    Next i
    r = G_FIRST + UBound(items) + 2
    ws.Cells(r, 1).Value = "スキーマ情報"
    ws.Cells(r, 1).Font.Bold = True
    ws.Cells(r + 1, 1).Value = "取得日時"
    ws.Cells(r + 2, 1).Value = "取得元サーバー"
    ws.Cells(r + 3, 1).Value = "dbtool バージョン"
    ws.Range(ws.Cells(r + 1, 1), ws.Cells(r + 3, 2)).Interior.Color = ColorReadOnly()
    ws.Range(ws.Cells(r + 1, 2), ws.Cells(r + 3, 2)).NumberFormat = "@"
    ws.Range(ws.Cells(G_FIRST, 1), ws.Cells(G_FIRST + UBound(items), 4)).Borders.LineStyle = xlContinuous
    ws.Range(ws.Cells(r + 1, 1), ws.Cells(r + 3, 2)).Borders.LineStyle = xlContinuous
    ws.Columns(1).ColumnWidth = 18
    ws.Columns(2).ColumnWidth = 26
    ws.Columns(3).ColumnWidth = 14
    ws.Columns(4).ColumnWidth = 110
    ws.Columns(3).Font.Color = RGB(128, 128, 128)
    ' ボタン
    AddButton ws, ws.Range("F4"), 150, 32, "設定ファイル出力", "ExportConfig"
    AddButton ws, ws.Range("F7"), 150, 26, "入力チェック", "CheckInput"
    AddButton ws, ws.Range("F9"), 150, 26, "スキーマ取込 (TSV)", "ImportSchemaFile"
    AddButton ws, ws.Range("F11"), 150, 26, "シートを再作成", "RebuildSheets"
End Sub

Private Sub InitTablesSheet()
    Dim ws As Worksheet
    Set ws = GetSheet(SH_TABLES)
    ws.Cells.Clear
    TitleRow ws, "テーブル設定  (黄色: 入力 / 灰色: 参照のみ。処理順の小さいテーブルから生成・ロードし、後片付けは逆順)", T_LAST
    ws.Range(ws.Cells(2, 1), ws.Cells(2, T_LAST)).Value = Array("対象", "テーブル名", "処理順", "生成件数", "事前処理", "事前バックアップ", "後片付け", "後片付け条件 (WHERE)", "乱数シード", "JMeter出力件数", _
        "現在件数(概算)", "AUTO_INCREMENT", "主キー", "外部キー (参照先)", "このテーブルを参照する外部キー", "CHECK 制約", "トリガー", "エンジン", "テーブルコメント")
    HeaderStyle ws.Range(ws.Cells(2, 1), ws.Cells(2, T_LAST))
    SetWidths ws, Array(6, 24, 7, 12, 11, 9, 19, 30, 10, 11, 12, 12, 18, 40, 40, 30, 24, 9, 30)
    HeaderNotes ws, Array( _
        "Y: 処理する / N: 処理しない", "", "小さい順に処理 (外部キーの親を先に)", "生成する行数 (0 は生成しない)", _
        "NONE: そのまま追加" & vbLf & "TRUNCATE: 全削除してから投入" & vbLf & "DELETE: DELETE で全削除してから投入", _
        "Y: prepare の最初に CSV でバックアップ (RESTORE に必須)", _
        "RESTORE: 全削除→バックアップを復元" & vbLf & "DELETE_GENERATED: 生成した行 (連番の範囲) を削除" & vbLf & "DELETE_WHERE: 条件に一致する行を削除" & vbLf & "TRUNCATE: 全削除" & vbLf & "NONE: 何もしない", _
        "DELETE_WHERE のときの WHERE 句 (例: note = 'JMTEST')", "同じシード・同じ件数なら同じデータを生成", "JMeter 用 CSV に出力する件数 (0 は全件。指定時は全体から均等に抽出)")
    FreezeAt ws, 3, 3
    ws.Range(ws.Cells(2, 1), ws.Cells(2, T_LAST)).AutoFilter
End Sub

Private Sub InitColumnsSheet()
    Dim ws As Worksheet
    Set ws = GetSheet(SH_COLUMNS)
    ws.Cells.Clear
    TitleRow ws, "列設定  (黄色: 入力 / 灰色: 参照のみ。生成方式とパラメータの意味は「生成方式一覧」シートを参照)", C_LAST
    ws.Range(ws.Cells(2, 1), ws.Cells(2, C_LAST)).Value = Array("テーブル名", "No", "列名", "データ型", "NULL", "キー", "インデックス", "デフォルト", "Extra", "外部キー参照先", "列コメント", _
        "生成方式", "パラメータ1", "パラメータ2", "パラメータ3", "NULL率(%)", "JMeter出力", "パラメータの意味", "自動判定メモ")
    HeaderStyle ws.Range(ws.Cells(2, 1), ws.Cells(2, C_LAST))
    SetWidths ws, Array(18, 5, 20, 22, 6, 6, 18, 16, 16, 24, 18, 17, 26, 16, 12, 9, 9, 48, 50)
    HeaderNotes ws, Array("", "", "", "", "YES: NULL 可", "PRI: 主キー / UNI: 一意 / MUL: インデックス", "", "", "", "", "", _
        "値の生成方法 (一覧から選択)", "生成方式ごとの意味は右の「パラメータの意味」を参照", "", "", "NULL にする割合 (NULL 可の列のみ)", "Y: JMeter 用 CSV に出力")
    FreezeAt ws, 3, 4
    ws.Range(ws.Cells(2, 1), ws.Cells(2, C_LAST)).AutoFilter
End Sub

Private Sub InitRulesSheet()
    Dim ws As Worksheet, r As Long
    Set ws = GetSheet(SH_RULES)
    ws.Cells.Clear
    TitleRow ws, "生成方式一覧", 9
    ws.Range("A2:I2").Value = Array("生成方式", "内容", "パラメータ1", "パラメータ2", "パラメータ3", "一意性", "使える型", "例", "パラメータの意味 (列設定に表示)")
    HeaderStyle ws.Range("A2:I2")
    r = 3
    AddRule ws, r, "SEQ", "連番 (開始値 + (行番号÷繰返し)×増分)", "開始値 (数値 / AUTO=既存の最大値+1)", "増分 (既定 1)", "繰返し回数 (既定 1)", "繰返し=1 なら一意", "数値, 文字列, バイナリ", "AUTO / 1 / 1"
    AddRule ws, r, "TEMPLATE", "書式文字列。${...} を値に置換", "テンプレート (下表参照)", "${seq} の開始値 (既定 1)", "${seq} の増分 (既定 1)", "${seq} を含み他が固定長なら一意", "文字列, JSON, バイナリ", "user${seq:6}@example.com"
    AddRule ws, r, "RANDOM_INT", "範囲内のランダムな整数", "最小値", "最大値", "", "×", "数値, 文字列, YEAR, BIT", "1 / 100"
    AddRule ws, r, "RANDOM_DECIMAL", "範囲内のランダムな小数", "最小値", "最大値", "小数桁数 (既定: 列の小数桁数)", "×", "DECIMAL, FLOAT, DOUBLE, 文字列", "0.01 / 9999.99 / 2"
    AddRule ws, r, "UNIQUE_INT", "範囲内で重複しないランダムな整数", "最小値", "最大値 (値域 ≧ 生成件数)", "", "○", "数値, 文字列, YEAR, BIT", "100000 / 999999"
    AddRule ws, r, "RANDOM_STRING", "ランダムな文字列", "最小長", "最大長", "文字種 (下表, 既定 alnum)", "×", "文字列, バイナリ", "5 / 20 / alnum"
    AddRule ws, r, "UNIQUE_STRING", "重複しないランダムな文字列", "長さ (接頭辞を除く)", "文字種 (digit/upper/lower/alpha/alnum/hex/hexupper)", "接頭辞", "○", "文字列, バイナリ", "10 / alnum / C-"
    AddRule ws, r, "UUID", "UUID (v4 形式, 実行内で一意)", "形式 STD / UPPER / NOHYPHEN (バイナリ列は16バイト)", "", "", "○", "CHAR(36)以上, BINARY(16)", "STD"
    AddRule ws, r, "LIST", "値リストからランダムに選択", "値リスト (| 区切り, 1..100 で範囲)", "重み (| 区切り, 省略時は均等)", "", "×", "すべて (空間型以外)", "active|suspended / 80|20"
    AddRule ws, r, "CYCLE", "値リストを順番に繰返し", "値リスト (| 区切り, 1..100 で範囲)", "各値の繰返し回数 (既定 1)", "", "条件付き", "すべて (空間型以外)", "A|B|C / 1"
    AddRule ws, r, "RANDOM_DATE", "範囲内のランダムな日付", "開始日 (既定 TODAY-365)", "終了日 (既定 TODAY)", "", "×", "DATE, DATETIME, TIMESTAMP, 文字列", "2025-01-01 / TODAY"
    AddRule ws, r, "RANDOM_DATETIME", "範囲内のランダムな日時", "開始日時 (既定 NOW-365d)", "終了日時 (既定 NOW)", "小数秒の桁数 (既定: 列の精度)", "×", "DATETIME, TIMESTAMP, DATE, 文字列", "NOW-30d / NOW"
    AddRule ws, r, "RANDOM_TIME", "範囲内のランダムな時刻", "開始 (既定 00:00:00)", "終了 (既定 23:59:59)", "小数秒の桁数", "×", "TIME, 文字列", "09:00:00 / 18:00:00"
    AddRule ws, r, "SEQ_DATETIME", "日付・日時の連番", "開始日時 (日付 / 日時 / NOW / TODAY)", "増分 (1d / 12h / 30m / 10s)", "繰返し回数 (既定 1)", "繰返し=1 なら一意", "DATE, DATETIME, TIMESTAMP, 文字列", "2026-01-01 00:00:00 / 1h"
    AddRule ws, r, "REF", "他テーブル (外部キーの親) の値を使用", "参照先 テーブル.列", "選択方法 RANDOM / SEQ (順番) / SEQ:n (1値をn行ずつ)", "グループ名 (複合外部キーで同じ親行を使う列に同じ名前)", "×", "すべて", "customers.id / RANDOM"
    AddRule ws, r, "RANDOM_BYTES", "ランダムなバイナリ", "最小バイト数", "最大バイト数", "", "×", "BINARY, VARBINARY, BLOB", "16 / 64"
    AddRule ws, r, "FIXED", "固定値 (空欄は空文字)", "値 (バイナリは 0x16進 も可, BIT は b'0101' も可, 空間型は WKT)", "空間型のみ: SRID", "", "×", "すべて", "JMTEST / POINT(139.7 35.6)"
    AddRule ws, r, "COPY", "同じ行の他の列と同じ値", "コピー元の列名", "", "", "コピー元と同じ", "すべて", "email"
    AddRule ws, r, "NULL", "常に NULL", "", "", "", "-", "NULL 可の列", ""
    AddRule ws, r, "DEFAULT", "値を設定せず DB の既定値 / AUTO_INCREMENT を使用", "", "", "", "-", "デフォルト値のある列, 生成列", ""
    ThisWorkbook.Names.Add Name:="RuleList", RefersTo:="='" & SH_RULES & "'!$A$3:$A$" & (r - 1)
    ws.Range(ws.Cells(3, 1), ws.Cells(r - 1, 9)).Borders.LineStyle = xlContinuous
    ws.Range(ws.Cells(3, 1), ws.Cells(r - 1, 1)).Font.Bold = True

    r = r + 1
    ws.Cells(r, 1).Value = "相対日時の指定方法": ws.Cells(r, 1).Font.Bold = True: r = r + 1
    AddPlain ws, r, "TODAY", "基準日の 0 時。TODAY-30 / TODAY+7 のように日数で加減"
    AddPlain ws, r, "NOW", "基準日時。NOW-30d / NOW-12h / NOW-15m / NOW-60s のように単位 (d/h/m/s) 付きで加減"
    AddPlain ws, r, "基準日時", "共通設定の「基準日時」。空欄の場合は実行時の DB の現在日時 (共通設定のタイムゾーン)"

    r = r + 1
    ws.Cells(r, 1).Value = "文字種": ws.Cells(r, 1).Font.Bold = True: r = r + 1
    AddPlain ws, r, "digit", "0-9"
    AddPlain ws, r, "upper / lower / alpha", "A-Z / a-z / A-Za-z"
    AddPlain ws, r, "alnum", "0-9A-Za-z (大文字小文字を区別しない照合順序の一意列では 0-9A-Z に自動変更)"
    AddPlain ws, r, "hex / hexupper", "0-9a-f / 0-9A-F"
    AddPlain ws, r, "ascii", "英数字と記号 (!#$%&()*+-./:;<=>?@[]^_{|}~)"
    AddPlain ws, r, "hira / kata / hankana", "ひらがな / カタカナ / 半角カナ"
    AddPlain ws, r, "kanji / zenkaku", "常用漢字の一部 / ひらがな・カタカナ・漢字の混在"

    r = r + 1
    ws.Cells(r, 1).Value = "テンプレートのプレースホルダ (TEMPLATE)": ws.Cells(r, 1).Font.Bold = True: r = r + 1
    AddPlain ws, r, "${seq}  ${seq:8}", "連番 (パラメータ2=開始値, パラメータ3=増分)。:8 は 8 桁ゼロ埋め"
    AddPlain ws, r, "${int:1,100}  ${int:1,100,3}", "範囲内のランダムな整数 (3 桁ゼロ埋め)"
    AddPlain ws, r, "${alnum:8}  ${hira:2,5}", "文字種の文字を 8 文字 / 2～5 文字 (文字種は上表)"
    AddPlain ws, r, "${list:東京|大阪|名古屋}", "リストからランダムに選択 (値の | } \ は \ でエスケープ)"
    AddPlain ws, r, "${uuid}", "ランダムな UUID"
    AddPlain ws, r, "$${", "文字列 ${ そのもの"
    ws.Columns("A").ColumnWidth = 26: ws.Columns("B").ColumnWidth = 44: ws.Columns("C").ColumnWidth = 40
    ws.Columns("D").ColumnWidth = 36: ws.Columns("E").ColumnWidth = 32: ws.Columns("F").ColumnWidth = 18
    ws.Columns("G").ColumnWidth = 30: ws.Columns("H").ColumnWidth = 26: ws.Columns("I").ColumnWidth = 60
    FreezeAt ws, 3, 2
End Sub

Private Sub AddRule(ByVal ws As Worksheet, ByRef r As Long, ParamArray v() As Variant)
    Dim i As Long, help As String
    For i = 0 To UBound(v)
        ws.Cells(r, i + 1).NumberFormat = "@"
        ws.Cells(r, i + 1).Value = v(i)
    Next i
    If v(2) <> "" Then help = "P1: " & v(2)
    If v(3) <> "" Then help = help & " / P2: " & v(3)
    If v(4) <> "" Then help = help & " / P3: " & v(4)
    If help = "" Then help = "(パラメータなし)"
    ws.Cells(r, 9).Value = help
    r = r + 1
End Sub

Private Sub AddPlain(ByVal ws As Worksheet, ByRef r As Long, ByVal a As String, ByVal b As String)
    ws.Cells(r, 1).NumberFormat = "@": ws.Cells(r, 1).Value = a
    ws.Cells(r, 2).Value = b
    ws.Range(ws.Cells(r, 2), ws.Cells(r, 6)).Merge
    r = r + 1
End Sub

Private Sub InitUsageSheet()
    Dim ws As Worksheet, r As Long, t As Variant
    Set ws = GetSheet(SH_USAGE)
    ws.Cells.Clear
    TitleRow ws, "dbtool テストデータ生成設定ブック (DataGenConfig.xlsm) - 使い方", 2
    r = 3
    For Each t In Array( _
        "■ 全体の流れ", _
        "1. サーバー (RHEL) で  dbtool.sh schema -d <DB> -t <テーブル>  を実行すると、このブックにスキーマ情報を入れた .xlsm が作成されます。", _
        "2. Windows にコピーして開き、[コンテンツの有効化] でマクロを有効にすると、「テーブル設定」「列設定」シートが自動で作成されます。", _
        "   (自動で作成されない場合は「共通設定」シートの [シートを再作成] を押してください)", _
        "3. 「テーブル設定」で生成件数・処理順・事前処理・後片付けを、「列設定」で各列の生成方式とパラメータを設定します。", _
        "   黄色のセルが入力欄、灰色のセルは参照のみです。生成方式の意味は「生成方式一覧」シートを参照してください。", _
        "4. 「共通設定」シートの [設定ファイル出力] を押して、設定ファイル (.conf) を保存します。", _
        "5. 設定ファイルをサーバーにコピーし、次のコマンドを実行します。", _
        "     dbtool.sh validate -c <設定ファイル>    … 設定の検証 (DB の定義・データと照合)", _
        "     dbtool.sh prepare  -c <設定ファイル>    … バックアップ → 事前処理 → データ生成・ロード (JMeter 用 CSV も出力)", _
        "     (JMeter で性能テストを実施)", _
        "     dbtool.sh cleanup                        … 後片付け (設定に従い元の状態に戻す)", _
        "", _
        "■ スキーマ (テーブル定義) が変わったとき", _
        "  サーバーで  dbtool.sh schema ... --tsv-only  を実行して TSV を作成し、[スキーマ取込 (TSV)] で読み込みます。", _
        "  入力済みの設定は、テーブル名・列名・データ型が同じものは引き継がれます。", _
        "", _
        "■ 注意", _
        "  ・インターネットやメールから取得したファイルはマクロがブロックされる場合があります。", _
        "    その場合はファイルのプロパティで [許可する] にチェックを入れてから開いてください。", _
        "  ・入力チェックはこのブックでは基本的な項目のみ行います。値の範囲・データ型との整合性・一意性・外部キーなどの", _
        "    詳細な検証は dbtool.sh validate で行われます。", _
        "  ・設定ファイルは UTF-8 (BOM なし)・改行 LF・TAB 区切りのテキストです。")
        ws.Cells(r, 1).Value = t
        If Left$(t, 1) = "■" Then ws.Cells(r, 1).Font.Bold = True
        r = r + 1
    Next t
    ws.Columns("A").ColumnWidth = 140
End Sub

'==============================================================================
' 書式・部品
'==============================================================================
Private Sub TitleRow(ByVal ws As Worksheet, ByVal title As String, ByVal lastCol As Long)
    ws.Rows(1).RowHeight = 34
    ws.Cells(1, 1).Value = title
    With ws.Range(ws.Cells(1, 1), ws.Cells(1, lastCol))
        .Interior.Color = ColorTitle()
        .Font.Bold = True
        .Font.Size = 12
        .VerticalAlignment = xlCenter
    End With
End Sub

Private Sub HeaderStyle(ByVal rng As Range)
    With rng
        .Interior.Color = ColorHeader()
        .Font.Color = RGB(255, 255, 255)
        .Font.Bold = True
        .WrapText = True
        .VerticalAlignment = xlCenter
        .HorizontalAlignment = xlCenter
        .Borders.LineStyle = xlContinuous
        .Borders.Color = RGB(255, 255, 255)
    End With
    rng.Rows(1).RowHeight = 32
End Sub

Private Sub HeaderNotes(ByVal ws As Worksheet, ByVal notes As Variant)
    Dim i As Long
    For i = 0 To UBound(notes)
        If notes(i) <> "" Then
            If Not ws.Cells(2, i + 1).Comment Is Nothing Then ws.Cells(2, i + 1).Comment.Delete
            ws.Cells(2, i + 1).AddComment CStr(notes(i))
            ws.Cells(2, i + 1).Comment.Shape.Width = 260
            ws.Cells(2, i + 1).Comment.Shape.Height = 80
        End If
    Next i
End Sub

Private Sub SetWidths(ByVal ws As Worksheet, ByVal w As Variant)
    Dim i As Long
    For i = 0 To UBound(w)
        ws.Columns(i + 1).ColumnWidth = w(i)
    Next i
End Sub

Private Sub FreezeAt(ByVal ws As Worksheet, ByVal row As Long, ByVal col As Long)
    ws.Activate
    ActiveWindow.FreezePanes = False
    ActiveWindow.SplitColumn = 0: ActiveWindow.SplitRow = 0
    ws.Cells(row, col).Select
    ActiveWindow.FreezePanes = True
    ws.Cells(row, 1).Select
End Sub

Private Sub ClearData(ByVal ws As Worksheet, ByVal lastCol As Long)
    Dim lastRow As Long
    lastRow = ws.UsedRange.Row + ws.UsedRange.Rows.Count - 1
    If lastRow >= FIRST_ROW Then
        With ws.Range(ws.Cells(FIRST_ROW, 1), ws.Cells(lastRow, lastCol))
            .Validation.Delete
            .Clear
        End With
    End If
End Sub

Private Sub FormatDataArea(ByVal ws As Worksheet, ByVal n As Long, ByVal lastCol As Long, ByVal editCols As Variant)
    Dim c As Variant, rng As Range
    If n = 0 Then Exit Sub
    Set rng = ws.Range(ws.Cells(FIRST_ROW, 1), ws.Cells(FIRST_ROW + n - 1, lastCol))
    rng.Interior.Color = ColorReadOnly()
    rng.Borders.LineStyle = xlContinuous
    rng.Borders.Color = RGB(191, 191, 191)
    rng.VerticalAlignment = xlTop
    For Each c In editCols
        ws.Range(ws.Cells(FIRST_ROW, c), ws.Cells(FIRST_ROW + n - 1, c)).Interior.Color = ColorEdit()
    Next c
End Sub

Private Sub AddListValidation(ByVal rng As Range, ByVal list As String)
    With rng.Validation
        .Delete
        .Add Type:=xlValidateList, AlertStyle:=xlValidAlertStop, Operator:=xlBetween, Formula1:=list
        .IgnoreBlank = True
        .InCellDropdown = True
        .ErrorMessage = "一覧から選択してください: " & list
    End With
End Sub

Private Sub AddFormulaListValidation(ByVal rng As Range, ByVal formula As String)
    With rng.Validation
        .Delete
        .Add Type:=xlValidateList, AlertStyle:=xlValidAlertStop, Operator:=xlBetween, Formula1:=formula
        .IgnoreBlank = True
        .InCellDropdown = True
        .ErrorMessage = "「生成方式一覧」シートの生成方式から選択してください"
    End With
End Sub

Private Sub AddWholeValidation(ByVal rng As Range, ByVal minV As Double, ByVal maxV As Double)
    With rng.Validation
        .Delete
        .Add Type:=xlValidateWholeNumber, AlertStyle:=xlValidAlertStop, Operator:=xlBetween, Formula1:=CStr(minV), Formula2:=CStr(maxV)
        .IgnoreBlank = True
        .ErrorMessage = CStr(minV) & "～" & CStr(maxV) & " の整数を入力してください"
    End With
End Sub

Private Sub AddButton(ByVal ws As Worksheet, ByVal at As Range, ByVal w As Double, ByVal h As Double, ByVal caption As String, ByVal macro As String)
    Dim b As Object
    Set b = ws.Buttons.Add(at.Left, at.Top, w, h)
    b.OnAction = macro
    b.Characters.Text = caption
    b.Font.Bold = True
    b.Placement = xlFreeFloating
    b.Name = "btn_" & macro
End Sub

'==============================================================================
' ユーティリティ
'==============================================================================
Public Function GetSheet(ByVal name As String) As Worksheet
    On Error Resume Next
    Set GetSheet = ThisWorkbook.Worksheets(name)
End Function

' セルの値を文字列に (日付・数値の表記ゆれを吸収)
Public Function CellText(ByVal v As Variant) As String
    If IsError(v) Then CellText = "": Exit Function
    Select Case VarType(v)
        Case vbEmpty, vbNull: CellText = ""
        Case vbString: CellText = v
        Case vbDate
            If CDbl(v) = Int(CDbl(v)) Then CellText = Format$(v, "yyyy-mm-dd") Else CellText = Format$(v, "yyyy-mm-dd hh:nn:ss")
        Case vbBoolean: CellText = IIf(v, "TRUE", "FALSE")
        Case vbDouble, vbSingle, vbCurrency, vbDecimal, vbInteger, vbLong, vbByte
            If CDbl(v) = Int(CDbl(v)) And Abs(CDbl(v)) < 1E+15 Then
                CellText = Format$(v, "0")
            Else
                CellText = Trim$(Str$(v))
            End If
        Case Else: CellText = CStr(v)
    End Select
End Function

Private Function ToNum(ByVal v As Variant) As Variant
    Dim s As String
    s = Trim$(CStr(v))
    If s = "" Then
        ToNum = ""
    ElseIf s Like "*[!0-9-]*" Or Len(s) > 15 Then
        ToNum = s
    ElseIf IsNumeric(s) Then
        ToNum = CDbl(s)
    Else
        ToNum = s
    End If
End Function

Private Function IsIntIn(ByVal s As String, ByVal lo As Double, ByVal hi As Double) As Boolean
    s = Trim$(s)
    If s = "" Then Exit Function
    If s Like "*[!0-9-]*" Then Exit Function
    If Len(s) > 15 Then Exit Function
    If Not IsNumeric(s) Then Exit Function
    If CDbl(s) <> Int(CDbl(s)) Then Exit Function
    IsIntIn = (CDbl(s) >= lo And CDbl(s) <= hi)
End Function

Public Function TsvEscape(ByVal s As String) As String
    s = Replace(s, "\", "\\")
    s = Replace(s, vbTab, "\t")
    s = Replace(s, vbCrLf, vbLf)
    s = Replace(s, vbLf, "\n")
    s = Replace(s, vbCr, "\r")
    TsvEscape = s
End Function

Public Function TsvUnescape(ByVal s As String) As String
    Dim i As Long, n As Long, c As String, d As String, out As String
    If InStr(s, "\") = 0 Then TsvUnescape = s: Exit Function
    n = Len(s): i = 1
    Do While i <= n
        c = Mid$(s, i, 1)
        If c = "\" And i < n Then
            d = Mid$(s, i + 1, 1)
            Select Case d
                Case "t": out = out & vbTab
                Case "n": out = out & vbLf
                Case "r": out = out & vbCr
                Case "\": out = out & "\"
                Case "0": out = out
                Case Else: out = out & "\" & d
            End Select
            i = i + 2
        Else
            out = out & c
            i = i + 1
        End If
    Loop
    TsvUnescape = out
End Function

Private Function ReadUtf8(ByVal path As String) As String
    Dim st As Object
    Set st = CreateObject("ADODB.Stream")
    st.Type = 2
    st.Charset = "UTF-8"
    st.Open
    st.LoadFromFile path
    ReadUtf8 = st.ReadText(-1)
    st.Close
End Function

Private Sub WriteUtf8NoBom(ByVal path As String, ByVal text As String)
    Dim st As Object, bin As Object
    Set st = CreateObject("ADODB.Stream")
    st.Type = 2
    st.Charset = "UTF-8"
    st.Open
    st.WriteText text
    st.Position = 0
    st.Type = 1
    st.Position = 3
    Set bin = CreateObject("ADODB.Stream")
    bin.Type = 1
    bin.Open
    st.CopyTo bin
    bin.SaveToFile path, 2
    bin.Close
    st.Close
End Sub
