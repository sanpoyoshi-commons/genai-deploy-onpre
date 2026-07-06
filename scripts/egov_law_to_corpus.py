#!/usr/bin/env python3
# e-gov 法令一括 XML（all_xml.zip）→ RAG 用 構造化テキスト corpus 変換器。
#
# 目的：RAG エンジンの大規模精度検証（実データ消化）。事業者関連の
# 代表法令サブセットを e-gov 法令標準 XML スキーマから章/節/条の headerPath 付きプレーンテキストへ
# 変換し、scripts/law-corpus.json（[{lawId,title,lawNum,text}]）を出力する。bench-rag-law.mjs が読む。
#
# 実行（deploy リポ直下、all_xml.zip がある場所で）：
#   python3 scripts/egov_law_to_corpus.py
# 認証不要・read-only（zip を読むだけ、DB には触れない）。

import zipfile, csv, io, json, sys
import xml.etree.ElementTree as ET
from collections import OrderedDict

ZIP = "all_xml.zip"
OUT = "scripts/law-corpus.json"

# 総務/人事/経理が実務で触れる代表法令の厳選リスト（label, 検索名）。
# 施行法/特例/臨時特例/協定/公務員専用 等のノイズを避けるため、検索名は本体名で指定する。
CURATED = [
    ("労働基準法", "労働基準法"),
    ("労働契約法", "労働契約法"),
    ("労働安全衛生法", "労働安全衛生法"),
    ("最低賃金法", "最低賃金法"),
    ("育児介護休業法", "育児休業、介護休業等育児又は家族介護を行う労働者の福祉に関する法律"),
    ("男女雇用機会均等法", "雇用の分野における男女の均等な機会及び待遇の確保等に関する法律"),
    ("パート有期労働法", "短時間労働者及び有期雇用労働者の雇用管理の改善等に関する法律"),
    ("労働者派遣法", "労働者派遣事業の適正な運営の確保及び派遣労働者の保護等に関する法律"),
    ("職業安定法", "職業安定法"),
    ("雇用保険法", "雇用保険法"),
    ("厚生年金保険法", "厚生年金保険法"),
    ("健康保険法", "健康保険法"),
    ("会社法", "会社法"),
    ("商法", "商法"),
    ("民法", "民法"),
    ("下請法", "下請代金支払遅延等防止法"),
    ("個人情報保護法", "個人情報の保護に関する法律"),
    ("マイナンバー法", "行政手続における特定の個人を識別するための番号の利用等に関する法律"),
    ("消費税法", "消費税法"),
    ("法人税法", "法人税法"),
    ("所得税法", "所得税法"),
    ("電子帳簿保存法", "電子計算機を使用して作成する国税関係帳簿書類の保存方法等の特例に関する法律"),
    ("中小企業基本法", "中小企業基本法"),
    ("独占禁止法", "私的独占の禁止及び公正取引の確保に関する法律"),
    ("不正競争防止法", "不正競争防止法"),
    ("製造物責任法", "製造物責任法"),
    ("特定商取引法", "特定商取引に関する法律"),
    ("景品表示法", "不当景品類及び不当表示防止法"),
    ("電子署名法", "電子署名及び認証業務に関する法律"),
    ("資金決済法", "資金決済に関する法律"),
]

def pick(rows, query):
    """法律・現行(未施行でない)・名前完全一致を最優先、無ければ最短名の部分一致。"""
    cands = [r for r in rows if r["法令種別"] in ("法律", "憲法") and not r.get("未施行", "").strip()]
    exact = [r for r in cands if r["法令名"] == query]
    if exact:
        return exact[0]
    # 括弧内別名（昭和XX年法律第YY号（本名））も許容
    paren = [r for r in cands if r["法令名"].endswith("（" + query + "）")]
    if paren:
        return paren[0]
    sub = [r for r in cands if query in r["法令名"]]
    if sub:
        return min(sub, key=lambda r: len(r["法令名"]))
    return None

def text_of(e):
    return "".join(e.itertext()).strip()

def law_to_text(root, title, lawnum, label=None):
    """e-gov 標準スキーマを章/節/条の headerPath 付きテキストへ。MainProvision のみ（附則は除外）。"""
    out = [f"# {title}（{lawnum}）"]
    mp = root.find(".//MainProvision")
    if mp is None:
        return "\n".join(out)

    # 構造コンテナ → 見出しレベル
    LEVEL = {"Part": "##", "Chapter": "##", "Section": "###",
             "Subsection": "####", "Division": "#####"}
    TITLE_TAG = {"Part": "PartTitle", "Chapter": "ChapterTitle", "Section": "SectionTitle",
                 "Subsection": "SubsectionTitle", "Division": "DivisionTitle"}

    def walk(node):
        for child in node:
            tag = child.tag
            if tag in LEVEL:
                tt = child.find(TITLE_TAG[tag])
                if tt is not None and text_of(tt):
                    out.append(f"{LEVEL[tag]} {text_of(tt)}")
                walk(child)
            elif tag == "Article":
                at = child.find("ArticleTitle")
                cap = child.find("ArticleCaption")
                head = (text_of(at) if at is not None else "")
                if cap is not None and text_of(cap):
                    head = f"{head}{text_of(cap)}"
                if head:
                    # 注（2026-05-30）：条見出しへの法令略称前置（label）を実機検証したが Hit@1 9→8・MRR
                    # 0.621→0.597 と僅かに悪化したため不採用（法令名トークンが埋め込みのノイズになり弁別を
                    # sharpen せず）。RRF 調整も無効と既出。残る有効レバーはリランカ（ruri-v3-reranker-310m）。
                    out.append(f"###### {head}")
                # 段落・号
                for para in child.findall("Paragraph"):
                    pnum = para.find("ParagraphNum")
                    prefix = (text_of(pnum) + " ") if (pnum is not None and text_of(pnum)) else ""
                    ps = para.find("ParagraphSentence")
                    if ps is not None:
                        s = "".join(text_of(x) for x in ps.findall("Sentence"))
                        if s:
                            out.append(prefix + s)
                    for item in para.findall("Item"):
                        it = item.find("ItemTitle")
                        isent = item.find("ItemSentence")
                        line = (text_of(it) + " ") if (it is not None and text_of(it)) else ""
                        if isent is not None:
                            line += "".join(text_of(x) for x in isent.iter("Sentence"))
                        if line.strip():
                            out.append("  " + line)
            else:
                # その他（TOC 等）は無視、ただし子に Article を含むなら掘る
                if child.find(".//Article") is not None:
                    walk(child)
    walk(mp)
    return "\n".join(out)

def main():
    z = zipfile.ZipFile(ZIP)
    with z.open("all_law_list.csv") as f:
        rows = list(csv.DictReader(io.TextIOWrapper(f, encoding="utf-8-sig", errors="replace")))
    # lawId -> zip xml path
    xml_by_id = {}
    for n in z.namelist():
        if n.endswith(".xml"):
            lid = n.split("/")[0].split("_")[0]
            xml_by_id.setdefault(lid, n)

    corpus = []
    manifest = []
    missing = []
    for label, query in CURATED:
        r = pick(rows, query)
        if not r:
            missing.append((label, query, "CSV未一致"))
            continue
        lid = r["法令ID"]
        path = xml_by_id.get(lid)
        if not path:
            missing.append((label, query, f"zipにXML無し({lid})"))
            continue
        with z.open(path) as f:
            root = ET.fromstring(f.read())
        title = r["法令名"]
        lawnum = r["法令番号"]
        text = law_to_text(root, title, lawnum, label)
        corpus.append({"lawId": lid, "label": label, "title": title,
                       "lawNum": lawnum, "shikoubi": r["施行日"], "text": text})
        manifest.append((label, title, lid, len(text)))

    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(corpus, f, ensure_ascii=False)

    total = sum(len(c["text"]) for c in corpus)
    print(f"=== corpus 生成完了: {OUT} ===")
    print(f"選定法令: {len(corpus)} 件 / 候補 {len(CURATED)} 件")
    print(f"テキスト総量: {total:,} 文字  推定 chunk1000 数: {total//1000:,}")
    print(f"\n{'label':<16}{'文字数':>10}  法令ID            法令名")
    for label, title, lid, n in manifest:
        print(f"{label:<16}{n:>10,}  {lid:<16} {title[:40]}")
    if missing:
        print("\n[未取得] " + "; ".join(f"{l}({q[:12]}…:{why})" for l, q, why in missing))

if __name__ == "__main__":
    main()
