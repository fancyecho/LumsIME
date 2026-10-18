# Builds typo evaluation sets from rime-ice's base dictionary (deterministic):
#   control.tsv  correctly typed frequent words, which must keep their first place
#   typos.tsv    the same words with one typo of each kind
#   hard.tsv     every syllable, words of all frequencies and two-word phrases, typed correctly
# Usage: gen.py <cn_dicts dir> <out dir>
import random, re, sys
src, out_dir = sys.argv[1], sys.argv[2]
dict_path = f'{src}/base.dict.yaml'
random.seed(7)
rows = []
for line in open(dict_path, encoding='utf-8'):
    m = re.match(r'^([^\t#]+)\t([a-z ]+)\t(\d+)$', line.rstrip('\n'))
    if not m: continue
    word, py, w = m.group(1), m.group(2), int(m.group(3))
    if 2 <= len(word) <= 4 and len(py.split()) == len(word):
        rows.append((w, word, py))
rows.sort(reverse=True)
seen, pool = set(), []
for w, word, py in rows:
    if word in seen: continue
    seen.add(word); pool.append((word, py))
    if len(pool) >= 400: break
with open(f'{out_dir}/control.tsv', 'w') as f:
    for word, py in pool:
        f.write(f'{py.replace(" ", "")}\t{word}\tcontrol\n')

rows_kb = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
def neighbors(c):
    for r in rows_kb:
        i = r.find(c)
        if i >= 0: return [r[j] for j in (i - 1, i + 1) if 0 <= j < len(r)]
    return []

def swap(s):
    opts = [i for i in range(len(s) - 1) if s[i] != s[i + 1]]
    if not opts: return None
    i = random.choice(opts); return s[:i] + s[i + 1] + s[i] + s[i + 2:]
def adjacent(s):
    i = random.randrange(len(s)); n = neighbors(s[i])
    return s[:i] + random.choice(n) + s[i + 1:] if n else None
def double(s):
    i = random.randrange(len(s)); return s[:i + 1] + s[i] + s[i + 1:]
def omit(s):
    if len(s) < 3: return None
    i = random.randrange(1, len(s)); return s[:i] + s[i + 1:]
def zh(s):
    if re.match(r'^[zcs]h', s): return s[0] + s[2:]
    if re.match(r'^[zcs]', s): return s[0] + 'h' + s[1:]
    return None
def nasal(s):
    if s.endswith('ng') and s[-3] in 'aei': return s[:-1]
    if re.search(r'[aei]n$', s): return s + 'g'
    return None

kinds = {'swap': swap, 'adjacent': adjacent, 'double': double, 'omit': omit, 'zh-z': zh, 'nasal': nasal}
with open(f'{out_dir}/typos.tsv', 'w') as f:
    for name, fn in kinds.items():
        cases = 0
        for word, py in random.sample(pool, len(pool)):
            syl = py.split()
            order = list(range(len(syl))); random.shuffle(order)
            for k in order:
                t = fn(syl[k])
                if t and t != syl[k]:
                    typed = ''.join(syl[:k] + [t] + syl[k + 1:])
                    f.write(f'{typed}\t{word}\t{name}\n'); cases += 1
                    break
            if cases >= 120: break

# Correctly typed input for regression checks: syllables, words of every frequency, phrases.
random.seed(11)
syllables = set()
for line in open(f'{src}/8105.dict.yaml', encoding='utf-8'):
    f = line.rstrip('\n').split('\t')
    if len(f) >= 2 and not line.startswith('#') and re.fullmatch('[a-z]+', f[1]): syllables.add(f[1])
words = sorted({py.replace(' ', '') for _, _, py in rows})
top = [py.replace(' ', '') for _, py in pool]
with open(f'{out_dir}/hard.tsv', 'w') as f:
    for s in sorted(syllables): f.write(f'{s}\t-\tsingle\n')
    for w in random.sample(words, 1500): f.write(f'{w}\t-\tword\n')
    for _ in range(300): f.write(f'{random.choice(top)}{random.choice(top)}\t-\tphrase\n')
