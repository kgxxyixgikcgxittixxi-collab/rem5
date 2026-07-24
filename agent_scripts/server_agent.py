"""
NRO Server Agent - Self-healing version
- Thu nhiều goc do ket noi / protocol
- AI phan tich + tu viet fix vao working_protocol.json
- Neu phat hien loi → tu push fix len repo
"""
import socket, time, json, os, struct, urllib.request, datetime, subprocess, base64

AGNES_URL = "https://apihub.agnes-ai.com/v1/chat/completions"
AGNES_KEY = os.environ.get("AGNES_API_KEY","")
GH_TOKEN  = os.environ.get("GH_PUSH_TOKEN","")
REPO      = "kgxxyixgikcgxittixxi-collab/rem5"
NOW       = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

host, port, status_info = "bore.pub", 20446, "unknown"
try:
    for line in open("SERVER_IP.txt"):
        k,_,v = line.strip().partition("=")
        if k=="HOST": host=v
        elif k=="PORT": port=int(v)
        elif k=="STATUS": status_info=v
except: pass
print(f"[INFO] {NOW}  target={host}:{port} status={status_info}")

# ── AI helper ──────────────────────────────────────────────────────────────
def ask_ai(prompt, max_tokens=300):
    if not AGNES_KEY: return "no key"
    try:
        payload = json.dumps({"model":"agnes-2.0-flash",
            "messages":[{"role":"user","content":prompt}],
            "max_tokens":max_tokens,"temperature":0.3}).encode()
        req = urllib.request.Request(AGNES_URL, data=payload,
            headers={"Authorization":f"Bearer {AGNES_KEY}","Content-Type":"application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read())["choices"][0]["message"]["content"].strip()
    except Exception as e:
        return f"AI_ERR:{e}"

# ── GitHub push helper ──────────────────────────────────────────────────────
def gh_push(path, content_str, msg):
    if not GH_TOKEN: return False
    try:
        api = f"https://api.github.com/repos/{REPO}/contents/{path}"
        resp = urllib.request.urlopen(
            urllib.request.Request(api, headers={"Authorization":f"token {GH_TOKEN}"}), timeout=10)
        sha = json.loads(resp.read()).get("sha","")
    except: sha = ""
    try:
        b64 = base64.b64encode(content_str.encode()).decode()
        d = {"message":f"{msg} [skip ci]","content":b64}
        if sha: d["sha"] = sha
        req = urllib.request.Request(api, data=json.dumps(d).encode(), method="PUT",
            headers={"Authorization":f"token {GH_TOKEN}","Content-Type":"application/json"})
        urllib.request.urlopen(req, timeout=15)
        return True
    except Exception as e:
        print(f"[WARN] gh_push {path}: {e}"); return False

# ── Protocol probe ─────────────────────────────────────────────────────────
def probe(name, send_bytes, wait_before_send=0.5):
    """Kết nối, optionally chờ, gửi bytes, đọc response. Return (ok, latency_ms, recv_hex, error)"""
    try:
        s = socket.socket(); s.settimeout(8)
        t0 = time.time()
        s.connect((host, port))
        lat = int((time.time()-t0)*1000)
        if wait_before_send > 0:
            s.settimeout(wait_before_send)
            try:
                first = s.recv(32)   # server-initiated?
                if first:
                    s.close()
                    return True, lat, first.hex(), None, "server_sent_first"
            except socket.timeout:
                pass
        s.settimeout(6)
        if send_bytes:
            s.sendall(send_bytes)
        data = b""
        deadline = time.time()+6
        while len(data)<128 and time.time()<deadline:
            try:
                c = s.recv(128-len(data))
                if not c: break
                data += c
                if len(data)>=2: break
            except socket.timeout: break
        s.close()
        return True, lat, data.hex() if data else "", None, "sent_first"
    except ConnectionRefusedError:
        return False, 0, "", "ConnectionRefused", ""
    except socket.timeout:
        return False, 0, "", "Timeout", ""
    except Exception as e:
        return False, 0, "", str(e), ""

# ── Chạy nhiều protocol probe ──────────────────────────────────────────────
probes = {}

# P1: Listen only (server sends first?)
ok,lat,rx,err,mode = probe("server_first", b"", wait_before_send=2.0)
probes["server_first"] = {"ok":ok,"lat":lat,"rx":rx,"err":err,"mode":mode}
print(f"  [P1] server_first: ok={ok} lat={lat}ms rx=0x{rx[:32]} err={err}")

# P2: Client gửi NRO login cmd=1
import struct
payload1 = bytes([0x01]) + b"admin\x00admin\x00"
pkt1 = struct.pack(">H", len(payload1)) + payload1
ok,lat,rx,err,mode = probe("login_cmd1", pkt1, wait_before_send=0)
probes["login_cmd1"] = {"ok":ok,"lat":lat,"rx":rx,"err":err,"mode":mode}
print(f"  [P2] login_cmd1: ok={ok} lat={lat}ms rx=0x{rx[:32]} err={err}")

# P3: Gửi version handshake (0xFF 0x00 như một số game Java)
pkt_ver = bytes([0xFF, 0x00, 0x00, 0x01])
ok,lat,rx,err,mode = probe("version_ff", pkt_ver, wait_before_send=0)
probes["version_ff"] = {"ok":ok,"lat":lat,"rx":rx,"err":err,"mode":mode}
print(f"  [P3] version_ff: ok={ok} lat={lat}ms rx=0x{rx[:32]} err={err}")

# P4: Gửi 2 bytes length = 0 trước (handshake probe)
ok,lat,rx,err,mode = probe("empty_pkt", b"\x00\x00", wait_before_send=0)
probes["empty_pkt"] = {"ok":ok,"lat":lat,"rx":rx,"err":err,"mode":mode}
print(f"  [P4] empty_pkt: ok={ok} lat={lat}ms rx=0x{rx[:32]} err={err}")

# P5: Gửi cmd=-101 (0xFF9B) open URL register
payload5 = struct.pack(">h", -101)   # signed short big-endian
pkt5 = struct.pack(">H", len(payload5)) + payload5
ok,lat,rx,err,mode = probe("cmd_neg101", pkt5, wait_before_send=0)
probes["cmd_neg101"] = {"ok":ok,"lat":lat,"rx":rx,"err":err,"mode":mode}
print(f"  [P5] cmd_neg101: ok={ok} lat={lat}ms rx=0x{rx[:32]} err={err}")

# ── Phân tích kết quả ──────────────────────────────────────────────────────
any_connected   = any(v["ok"] for v in probes.values())
any_response    = any(v["rx"] for v in probes.values() if v["ok"])
best_probe      = next((k for k,v in probes.items() if v.get("rx")), None)

summary = json.dumps({k: {"ok":v["ok"],"lat":v["lat"],"rx":v["rx"][:32],"err":v["err"]} 
                      for k,v in probes.items()}, ensure_ascii=False)

ai_prompt = f"""Ban la chuyen gia debug game NRO (Ngoc Rong Online) J2ME protocol.

Ket qua test ket noi server bore.pub:{port}:
{summary}

Thong tin:
- Server Java dang chay port 14445, bore tunnel forward len {port}
- NRO J2ME client obfuscated, protocol binary TCP
- server_first: cho server gui truoc (2s timeout)
- login_cmd1: gui [2B len][0x01][username\0][password\0]
- version_ff: gui [0xFF,0x00,0x00,0x01]  
- empty_pkt: gui [0x00,0x00]
- cmd_neg101: gui command -101 (register URL)

Tra loi ngan (max 150 tu):
1. Server co dang chap nhan ket noi khong?
2. Protocol nao co ve dung nhat / server phan hoi rx khong phai rong?
3. Protocol NRO thuc su bat dau bang gi? Client hay server gui truoc?
4. Buoc fix tiep theo cu the?"""

diagnosis = ask_ai(ai_prompt, 400)
print(f"\n[AI]\n{diagnosis}\n")

# ── Tự fix: lưu working protocol + push kết quả ─────────────────────────
os.makedirs("agent_results", exist_ok=True)
report = {
    "ts": NOW, "target": f"{host}:{port}",
    "any_connected": any_connected,
    "any_response": any_response,
    "best_probe": best_probe,
    "probes": {k:{"ok":v["ok"],"lat":v["lat"],"rx":v["rx"],"err":v["err"],"mode":v["mode"]} for k,v in probes.items()},
    "ai_diagnosis": diagnosis
}
json.dump(report, open("agent_results/server_test.json","w"), ensure_ascii=False, indent=2)

emoji = "OK" if any_connected else "FAIL"
resp_summary = f"best={best_probe} rx=0x{probes[best_probe]['rx'][:16]}" if best_probe else "no_response"
log_line = f"{NOW} | {emoji} | {host}:{port} | {resp_summary} | {diagnosis[:80]}\n"
with open("agent_results/server_log.txt","a") as f: f.write(log_line)
try:
    lines = open("agent_results/server_log.txt").readlines()
    if len(lines)>500:
        open("agent_results/server_log.txt","w").writelines(lines[-500:])
except: pass

# Nếu phát hiện response từ server → ghi working_protocol.json để client_agent dùng
if any_response and best_probe:
    wp = {"probe": best_probe, "rx_hex": probes[best_probe]["rx"],
          "send_hex": {"server_first":"","login_cmd1":pkt1.hex(),
                       "version_ff":pkt_ver.hex(),"empty_pkt":"0000",
                       "cmd_neg101":pkt5.hex()}.get(best_probe,""),
          "updated": NOW}
    json.dump(wp, open("agent_results/working_protocol.json","w"), indent=2)
    print(f"[INFO] working_protocol.json saved: {best_probe}")

print(f"[DONE] {emoji} any_response={any_response}")
