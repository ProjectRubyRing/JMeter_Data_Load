#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xlsm_embed.py : スキーマ情報 TSV (#DBTOOL-SCHEMA) を Excel テンプレート (.xlsm) の
                非表示シート "_schema" に埋め込み、新しい .xlsm を出力する。
                (Excel を開いたときに VBA が _schema から各設定シートを作成する)

  python3 xlsm_embed.py <template.xlsm> <schema.tsv> <output.xlsm>

RHEL 9 標準の Python 3.9 の標準ライブラリのみを使用する。
"""
import re
import sys
import zipfile
import posixpath
from xml.sax.saxutils import escape

NS_MAIN = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
NS_REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
NS_PKGREL = "http://schemas.openxmlformats.org/package/2006/relationships"
SHEET_NAME = "_schema"

# XML 1.0 で使えない制御文字 (タブ・改行を除く)
_CTRL = re.compile("[\x00-\x08\x0b\x0c\x0d\x0e-\x1f￾￿]")
_XESC = re.compile(r"_(x[0-9A-Fa-f]{4})_")


def tsv_unescape(s):
    if "\\" not in s:
        return s
    out = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            d = s[i + 1]
            out.append({"t": "\t", "n": "\n", "r": "\r", "\\": "\\", "0": ""}.get(d, "\\" + d))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def xml_text(s):
    # OOXML の文字列エスケープ: 既存の _xHHHH_ を保護し、制御文字は _xHHHH_ で表す
    s = _XESC.sub(r"_x005F_\1_", s)
    s = _CTRL.sub(lambda m: "_x%04X_" % ord(m.group(0)), s)
    return escape(s)


def col_letter(n):
    s = ""
    while n > 0:
        n, r = divmod(n - 1, 26)
        s = chr(65 + r) + s
    return s


def build_sheet_xml(lines):
    rows = []
    for ri, line in enumerate(lines, start=1):
        fields = line.split("\t")
        cells = []
        for ci, f in enumerate(fields, start=1):
            v = tsv_unescape(f)
            if v == "":
                continue
            ref = "%s%d" % (col_letter(ci), ri)
            cells.append('<c r="%s" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>' % (ref, xml_text(v)))
        rows.append('<row r="%d">%s</row>' % (ri, "".join(cells)))
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<worksheet xmlns="%s" xmlns:r="%s"><sheetData>%s</sheetData></worksheet>' % (NS_MAIN, NS_REL, "".join(rows)))


def find_sheet_part(zf):
    wb = zf.read("xl/workbook.xml").decode("utf-8")
    m = None
    for sm in re.finditer(r"<sheet\b[^>]*/>", wb):
        tag = sm.group(0)
        name = re.search(r'\bname="([^"]*)"', tag)
        if name and name.group(1) == SHEET_NAME:
            m = re.search(r'\br:id="([^"]*)"', tag) or re.search(r'\bid="([^"]*)"', tag)
            break
    if not m:
        raise SystemExit("テンプレートにシート %s がありません" % SHEET_NAME)
    rid = m.group(1)
    rels = zf.read("xl/_rels/workbook.xml.rels").decode("utf-8")
    for rm in re.finditer(r"<Relationship\b[^>]*/>", rels):
        tag = rm.group(0)
        if re.search(r'\bId="%s"' % re.escape(rid), tag):
            target = re.search(r'\bTarget="([^"]*)"', tag).group(1)
            if target.startswith("/"):
                return target[1:]
            return posixpath.normpath(posixpath.join("xl", target))
    raise SystemExit("シート %s の参照先が見つかりません" % SHEET_NAME)


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: xlsm_embed.py template.xlsm schema.tsv output.xlsm\n")
        return 2
    tpl, tsv, out = argv[1], argv[2], argv[3]
    with open(tsv, "r", encoding="utf-8-sig", newline="") as f:
        text = f.read()
    lines = [ln[:-1] if ln.endswith("\r") else ln for ln in text.split("\n")]
    while lines and lines[-1] == "":
        lines.pop()
    if not lines or not lines[0].startswith("#DBTOOL-SCHEMA\t"):
        sys.stderr.write("スキーマ TSV の形式が不正です: %s\n" % tsv)
        return 2
    sheet_xml = build_sheet_xml(lines).encode("utf-8")
    with zipfile.ZipFile(tpl, "r") as zin:
        part = find_sheet_part(zin)
        tmp = out + ".part"
        with zipfile.ZipFile(tmp, "w") as zout:
            for info in zin.infolist():
                data = sheet_xml if info.filename == part else zin.read(info.filename)
                zi = zipfile.ZipInfo(info.filename, date_time=info.date_time)
                zi.compress_type = zipfile.ZIP_DEFLATED
                zi.external_attr = info.external_attr
                zout.writestr(zi, data)
    import os
    os.replace(tmp, out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
