' ThisWorkbook モジュール
Option Explicit

Private Sub Workbook_Open()
    On Error GoTo EH
    AutoBuildOnOpen
    Exit Sub
EH:
    MsgBox "スキーマ情報の展開でエラーが発生しました: " & Err.Description & vbLf & _
           "「共通設定」シートの [シートを再作成] を実行してください。", vbExclamation
End Sub
