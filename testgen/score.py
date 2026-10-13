"""score.py <truth.json> <transcript.md> [myName]  — exact line match vs ground truth."""
import json, sys
t = json.load(open(sys.argv[1])); me = sys.argv[3] if len(sys.argv) > 3 else "Me"
exp = [f"--- {c[1]} ---" if c[0] == "ts" else f"{me if c[0]=='me' else (c[1] or t['title'])}: {c[2]}" for c in t["convo"]]
got = [l for l in open(sys.argv[2]).read().splitlines()[3:] if l]
import difflib
ok = sum(1 for e, g in zip(exp, got) if e == g) if len(exp) == len(got) else None
print(f"expected {len(exp)} got {len(got)}", "| exact:", ok)
for l in difflib.unified_diff(exp, got, "truth", "got", n=0, lineterm=""): print(" ", l)
