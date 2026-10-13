"""Writes iMessage-lookalike HTML parts (header/body/footer/control-center) + ground truth.

usage: python3 make_html.py <outdir> <light|dark> <dm|group>
"""
import html, json, sys, os

out, theme, kind = sys.argv[1], sys.argv[2], sys.argv[3]
os.makedirs(out, exist_ok=True)
dark = theme == "dark"
BG = "#000" if dark else "#fff"
THEM_BG = "#262628" if dark else "#E9E9EB"
THEM_FG = "#fff" if dark else "#000"
GRAY = "#8E8E93"

if kind == "dm":
    title = "Alex Lopez"
    convo = [
        ("ts", "Yesterday 8:12 PM"),
        ("them", None, "yo are you still coming to the thing saturday"),
        ("me", None, "yeah I think so, what time does it start"),
        ("them", None, "doors at 9 but nobody shows up till like 10:30"),
        ("them", None, "also bring a jacket it's supposed to get cold"),
        ("me", None, "ok"),
        ("me", None, "should I drive or are we ubering"),
        ("them", None, "uber for sure, parking there is a nightmare and I am not getting towed again"),
        ("me", None, "lol fair"),
        ("ts", "Today 9:41 AM"),
        ("them", None, "did you finish the COP3502 assignment"),
        ("me", None, "not yet, the pattern printing part is annoying. I keep getting an off by one error on the last row and I can't figure out why"),
        ("them", None, "check your loop bound, it should be <= not <"),
        ("me", None, "omg that was it"),
        ("me", None, "thank you"),
        ("them", None, "lol"),
        ("them", None, "np"),
        ("me", None, "lol"),
        ("them", None, "are you going to office hours at 3"),
        ("me", None, "probably, I have a question about the exam format"),
        ("them", None, "same. meet at Marston first?"),
        ("me", None, "sounds good, 2:45"),
        ("them", None, "bet"),
        ("me", None, "also can you send me the notes from tuesday"),
        ("them", None, "yeah one sec"),
        ("them", None, "just emailed them to you"),
        ("me", None, "got it, appreciate it"),
    ]
else:
    title = "Weekend Plans"
    convo = [
        ("ts", "Sat 11:02 AM"),
        ("them", "Jordan", "who's down for brunch tomorrow"),
        ("them", "Jordan", "thinking 11 at the usual spot"),
        ("me", None, "I'm in"),
        ("them", "Sam", "can we do 11:30 I have a thing in the morning"),
        ("them", "Jordan", "works for me"),
        ("me", None, "11:30 it is"),
        ("them", "Priya", "sorry just saw this, I can come but I'll be a little late"),
        ("them", "Priya", "save me a seat"),
        ("me", None, "will do"),
        ("ts", "Sun 10:47 AM"),
        ("them", "Sam", "running 5 min behind"),
        ("me", None, "no worries we just got a table by the window"),
        ("them", "Jordan", "ordering the pancakes for the table"),
        ("them", "Priya", "omw"),
        ("me", None, "see you soon"),
    ]

json.dump({"title": title, "convo": convo}, open(f"{out}/truth.json", "w"), indent=1)

CSS = f"""
* {{ margin:0; padding:0; box-sizing:border-box; }}
body {{ background:{BG}; width:390px; font-family:-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif;
       -webkit-font-smoothing:antialiased; }}
"""

rows = []
prev = None
for i, item in enumerate(convo):
    if item[0] == "ts":
        rows.append(f'<div class="ts">{html.escape(item[1])}</div>')
        prev = None
        continue
    side, sender, text = item
    nxt = convo[i + 1] if i + 1 < len(convo) else None
    run_start = prev is None or prev[0] != side or prev[1] != sender
    last_of_run = nxt is None or nxt[0] != side or nxt[1] != sender
    top = 2 if not run_start else 12
    label = ""
    if side == "them" and sender and run_start:
        label = f'<div class="name">{html.escape(sender)}</div>'
    avatar = ""
    if side == "them" and kind == "group":
        avatar = f'<div class="av">{sender[0]}</div>' if last_of_run else '<div class="avs"></div>'
    rows.append(f'{label}<div class="row {side}" style="margin-top:{top}px">{avatar}<div class="b {side}">{html.escape(text)}</div></div>')
    prev = item
    if i == len(convo) - 1 and side == "me":
        rows.append('<div class="status">Delivered</div>')

group_pad = 52 if kind == "group" else 16
body = f"""<html><head><style>{CSS}
.wrap {{ padding: 14px 0 18px; }}
.ts {{ text-align:center; color:{GRAY}; font-size:12px; margin:18px 0 6px; }}
.ts:first-child {{ margin-top:4px; }}
.row {{ display:flex; align-items:flex-end; padding:0 16px 0 {group_pad - (36 if kind=='group' else 0)}px; }}
.row.me {{ justify-content:flex-end; }}
.b {{ max-width:75%; padding:7px 12px; border-radius:18px; font-size:17px; line-height:22px; }}
.b.me {{ background:#0B84FE; color:#fff; }}
.b.them {{ background:{THEM_BG}; color:{THEM_FG}; }}
.name {{ font-size:11px; color:{GRAY}; margin:10px 0 2px {group_pad + 12}px; }}
.av {{ width:28px; height:28px; border-radius:14px; background:#A0A4AB; color:#fff; font-size:13px; font-weight:600;
       display:flex; align-items:center; justify-content:center; margin-right:8px; flex:none; }}
.avs {{ width:28px; margin-right:8px; flex:none; }}
.status {{ text-align:right; color:{GRAY}; font-size:11px; font-weight:600; padding:3px 20px 0; }}
</style></head><body><div class="wrap">{''.join(rows)}</div></body></html>"""
open(f"{out}/body.html", "w").write(body)

HB = "#1C1C1E" if dark else "#F6F6F6"
FG = "#fff" if dark else "#000"
initials = "".join(w[0] for w in title.split()[:2]).upper()
header = f"""<html><head><style>{CSS}
body {{ background:{HB}; height:122px; position:relative; border-bottom:0.5px solid {'#333' if dark else '#ccc'}; }}
.time {{ position:absolute; left:42px; top:15px; font-size:17px; font-weight:600; color:{FG}; }}
.bat {{ position:absolute; right:30px; top:18px; width:26px; height:12px; border:1.5px solid {FG}; border-radius:4px; }}
.back {{ position:absolute; left:12px; top:62px; font-size:30px; color:#0B84FE; }}
.av {{ position:absolute; left:170px; top:50px; width:50px; height:50px; border-radius:25px;
       background:linear-gradient(#A5ABB8,#858994); color:#fff; font-size:20px; font-weight:600;
       display:flex; align-items:center; justify-content:center; }}
.nm {{ position:absolute; left:0; right:0; top:103px; text-align:center; font-size:12px; color:{FG}; }}
</style></head><body><div class="time">9:41</div><div class="bat"></div><div class="back">‹</div>
<div class="av">{initials}</div><div class="nm">{html.escape(title)} ›</div></body></html>"""
open(f"{out}/header.html", "w").write(header)

footer = f"""<html><head><style>{CSS}
body {{ background:{BG}; height:86px; position:relative; }}
.plus {{ position:absolute; left:12px; top:10px; width:34px; height:34px; border-radius:17px; background:{'#2C2C2E' if dark else '#EEEEF0'};
        color:{GRAY}; font-size:26px; display:flex; align-items:center; justify-content:center; }}
.field {{ position:absolute; left:54px; right:12px; top:10px; height:34px; border:1px solid {'#3A3A3C' if dark else '#D1D1D6'}; border-radius:17px;
         color:{GRAY}; font-size:17px; padding:6px 14px; }}
.home {{ position:absolute; left:128px; bottom:8px; width:134px; height:5px; border-radius:3px; background:{FG}; }}
</style></head><body><div class="plus">+</div><div class="field">iMessage</div><div class="home"></div></body></html>"""
open(f"{out}/footer.html", "w").write(footer)

cc = f"""<html><head><style>{CSS}
body {{ background:#2a2f3a; height:844px; position:relative; }}
.t {{ position:absolute; border-radius:22px; background:#6b7280; color:#fff; font-size:15px; padding:14px; }}
</style></head><body>
<div class="t" style="left:24px;top:110px;width:160px;height:160px;background:#0A84FF">Wi-Fi<br>UF-Secure</div>
<div class="t" style="left:206px;top:110px;width:160px;height:72px">Focus</div>
<div class="t" style="left:206px;top:198px;width:160px;height:72px;background:#FF453A">Screen Recording</div>
<div class="t" style="left:24px;top:290px;width:342px;height:120px">Not Playing</div>
</body></html>"""
open(f"{out}/cc.html", "w").write(cc)
print("ok", out)
