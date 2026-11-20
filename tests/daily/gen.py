#!/usr/bin/env python3
"""Turns tests/daily/*.txt into tests/daily/daily.tsv for `LumaIME --eval`.

Each line is cut at punctuation into clauses (people type up to a punctuation mark, then commit).
Every clause becomes a full-pinyin case; clauses of 2–4 characters also become an abbreviation case
(first letter of each syllable, e.g. wzdl → 我知道了). Clauses are split into dev and test halves
by a stable hash, so settings can be tuned on dev and checked on test.

Needs pypinyin (pip install pypinyin). The generated daily.tsv is committed, so running the eval
does not.
"""
import hashlib, re, sys
from pathlib import Path
from pypinyin import lazy_pinyin

here = Path(__file__).parent
rows, seen = [], set()
for source in sorted(here.glob('*.txt')):
    for line in source.read_text().splitlines():
        if not line.strip() or line.startswith('#'):
            continue
        for clause in re.split(r'[，。！？、；：,.!?;:\s]+', line):
            if len(clause) < 2 or clause in seen or not re.fullmatch(r'[一-鿿]+', clause):
                continue
            seen.add(clause)
            half = 'dev' if hashlib.md5(clause.encode()).digest()[0] % 2 == 0 else 'test'
            syllables = lazy_pinyin(clause)  # ü comes out as v, as typed
            rows.append((''.join(syllables), clause, f'{source.stem}-{half}'))
            if len(clause) <= 4:
                rows.append((''.join(s[0] for s in syllables), clause, f'abbrev-{source.stem}'))

rows.sort(key=lambda r: r[2])
out = here / 'daily.tsv'
out.write_text(''.join('\t'.join(r) + '\n' for r in rows))
print(f'{len(rows)} cases → {out}', file=sys.stderr)
