"""用后端的补全实现跑一批查询,导出 test/fixtures/autocomplete_parity.json,
给 test/tag_index_test.dart 对拍 TagIndex.search。

    python -X utf8 tool/autocomplete_parity.py <后端仓库>/novelai_web_ui/server/tag_search/autocomplete.py

后端的 tags/danbooru.tsv 与 assets/danbooru.tsv 是同一份,这里直接读 app 这份。
改了后端补全的匹配口径,或换了词库,要重跑。
"""
import importlib.util
import json
import random
import re
import sys
from pathlib import Path

LIMIT = 12
ROOT = Path(__file__).resolve().parents[1]

spec = importlib.util.spec_from_file_location("autocomplete", sys.argv[1])
ac = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ac)
idx = ac.TagPrefixIndex(ROOT / "assets" / "danbooru.tsv")

rnd = random.Random(20261026)
tags = idx.tags
queries = [
    "kimono", "seifuku", "long ha", "long_ha", "long  hair", " Long Hair ", "LONG_HAIR",
    "long__hair", "white ser", "ser white", "miku", "blue e", ":)", ":d", "^^^", "lh", "/lh",
    "hair rib", "school uni", "thigh", "hatsune mku", "scholl uniform", "9-may", "_long",
    "long_", "a", "", "1girl", "1g", "hires", "oppai", "x", "qx", "b", "bb", "o_o", ">_<",
    "fate/", "fate/grand", "re:", "(cosplay)", "cosplay", "genshin", "impact genshin",
]
for t in rnd.sample(tags[:5000], 250):
    s = t.replace("_", " ")
    for n in (2, 3, 4, 6, 9):
        if n <= len(s):
            queries.append(s[:n])
for t in rnd.sample(tags[:20000], 120):
    ws = [w for w in re.split(r"[_()]+", t) if w]
    if len(ws) >= 2:
        queries.append(ws[1][:4])
        queries.append(f"{ws[-1][:3]} {ws[0][:3]}")
for t in rnd.sample(tags[20000:], 120):
    queries.append(t.replace("_", " ")[:5])
for row in rnd.sample(range(len(tags)), 3000):
    aliases = idx._aliases[row]
    if aliases:
        queries.append(aliases[0][:4])
    if len(queries) > 1600:
        break

seen = set()
cases = []
for q in queries:
    if q in seen:
        continue
    seen.add(q)
    cases.append({"q": q, "want": [h["value"] for h in idx.search(q, LIMIT)]})

out = ROOT / "test" / "fixtures" / "autocomplete_parity.json"
out.parent.mkdir(exist_ok=True)
# 一条查询一行,重跑后的 diff 看得清
lines = ",\n".join(json.dumps(c, ensure_ascii=False) for c in cases)
out.write_text(f'{{"limit": {LIMIT}, "cases": [\n{lines}\n]}}\n', encoding="utf-8")
print(f"{out.relative_to(ROOT)}  {len(cases)} 条")
