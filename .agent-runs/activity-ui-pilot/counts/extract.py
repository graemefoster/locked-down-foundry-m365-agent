"""Extract final prose + card values from a turn's ws_frames.json; compare to compute_totals(). Usage: extract.py turnN"""
import json, re, sys
sys.path.insert(0, "agents/advanced-autopilot-agent")
from mock_m365 import compute_totals

d = sys.argv[1]
frames = json.load(open(f".agent-runs/activity-ui-pilot/counts/{d}/ws_frames.json"))
final = None
for f in frames:
    if f["dir"] != "recv" or '"type":"message"' not in f["data"].replace(" ", ""):
        continue
    try:
        a = json.loads(f["data"])
    except Exception:
        # payload truncated at 4000 chars: regex the text field
        m = re.search(r'"text":\s*"((?:[^"\\]|\\.)*)', f["data"])
        a = {"_text": json.loads('"' + m.group(1) + '"')} if m else None
    if a and (a.get("_text") or "## " in json.dumps(a)):
        final = a
raw = json.dumps(final)
card = re.findall(r'"text":\s*"(\d+)"', raw)
text = final.get("_text") or final.get("text", "") if final else ""
if not text:
    m = re.findall(r'"text":\s*"((?:[^"\\]|\\.)*)"', raw)
    text = max(m, key=len) if m else ""
text = text.encode().decode("unicode_escape", "ignore") if "\\n" in text else text
print("TOTALS", compute_totals())
print("PROSE\n" + text)
print("CARD numbers", card)
