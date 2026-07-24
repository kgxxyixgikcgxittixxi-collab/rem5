import socket, time, json, os, urllib.request, datetime

host, port, status_info = "bore.pub", 20446, "unknown"
try:
    for line in open("SERVER_IP.txt"):
        k, _, v = line.strip().partition("=")
        if k == "HOST": host = v
        elif k == "PORT": port = int(v)
        elif k == "STATUS": status_info = v
except: pass

print(f"[INFO] Target: {host}:{port} status={status_info}")

results = {}
try:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(10)
    t0 = time.time()
    sock.connect((host, port))
    results["latency_ms"] = int((time.time()-t0)*1000)
    results["connected"] = True
    print(f"[OK] TCP connect {results['latency_ms']}ms")

    sock.settimeout(8)
    data = b""
    deadline = time.time() + 8
    while len(data) < 64 and time.time() < deadline:
        try:
            chunk = sock.recv(64-len(data))
            if not chunk: break
            data += chunk
            if len(data) >= 4: break
        except socket.timeout: break

    results["greeting_hex"] = data.hex()
    results["greeting_len"] = len(data)
    print(f"[INFO] Greeting: {len(data)}B = 0x{data.hex()[:32]}")

    import struct
    login_payload = bytes([0x01]) + b"test_agent\x00test123\x00"
    pkt = struct.pack(">H", len(login_payload)) + login_payload
    sock.settimeout(5)
    sock.sendall(pkt)
    try:
        resp = sock.recv(64)
        results["login_resp"] = resp.hex()
        print(f"[INFO] Login resp: 0x{resp.hex()[:32]}")
    except: results["login_resp"] = "timeout"
    sock.close()
except ConnectionRefusedError:
    results["connected"] = False; results["error"] = "ConnectionRefused"
    print("[FAIL] ConnectionRefused")
except socket.timeout:
    results["connected"] = False; results["error"] = f"Timeout bore.pub:{port}"
    print(f"[FAIL] Timeout")
except Exception as e:
    results["connected"] = False; results["error"] = str(e)
    print(f"[FAIL] {e}")

api_key = os.environ.get("AGNES_API_KEY","")
diagnosis = "AI unavailable"
if api_key:
    prompt = f"""NRO server test bore.pub:{port}:
connected={results.get('connected')} latency={results.get('latency_ms','N/A')}ms
greeting({results.get('greeting_len',0)}B)=0x{results.get('greeting_hex','')[:32]}
login_resp=0x{results.get('login_resp','')}
error={results.get('error','none')} SERVER_IP_status={status_info}
Phan tich ngan (max 100 tu): server co chay khong? neu loi nguyen nhan + fix?"""
    try:
        payload = json.dumps({"model":"agnes-2.0-flash","messages":[{"role":"user","content":prompt}],"max_tokens":200,"temperature":0.3}).encode()
        req = urllib.request.Request("https://apihub.agnes-ai.com/v1/chat/completions", data=payload,
            headers={"Authorization":f"Bearer {api_key}","Content-Type":"application/json"})
        with urllib.request.urlopen(req, timeout=30) as r:
            diagnosis = json.loads(r.read())["choices"][0]["message"]["content"].strip()
        print(f"[AI] {diagnosis[:200]}")
    except Exception as e:
        diagnosis = f"AI err: {e}"; print(f"[WARN] {e}")

os.makedirs("agent_results", exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
emoji = "OK" if results.get("connected") else "FAIL"
json.dump({"ts":now,"target":f"{host}:{port}","results":results,"ai":diagnosis},
          open("agent_results/server_test.json","w"), ensure_ascii=False, indent=2)
with open("agent_results/server_log.txt","a") as f:
    f.write(f"{now} | {emoji} | {host}:{port} | {diagnosis[:90]}\n")
try:
    lines = open("agent_results/server_log.txt").readlines()
    if len(lines) > 500:
        open("agent_results/server_log.txt","w").writelines(lines[-500:])
except: pass
print(f"[DONE] {emoji}")
