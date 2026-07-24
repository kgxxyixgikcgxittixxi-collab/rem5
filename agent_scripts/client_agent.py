import socket, time, json, os, struct, urllib.request, datetime, subprocess, glob

host, port = "bore.pub", 20446
try:
    for line in open("SERVER_IP.txt"):
        k, _, v = line.strip().partition("=")
        if k == "HOST": host = v
        elif k == "PORT": port = int(v)
except: pass

print(f"[INFO] Client test -> {host}:{port}")
results = {}

def phase(name, fn):
    try:
        r = fn(); results[name] = {"ok":True,"data":str(r)[:120]}
        print(f"  OK {name}: {str(r)[:80]}"); return r
    except Exception as e:
        results[name] = {"ok":False,"error":str(e)}
        print(f"  FAIL {name}: {e}"); return None

phase("DNS", lambda: socket.gethostbyname(host))

sock = None
def do_tcp():
    global sock
    s = socket.socket(); s.settimeout(10)
    t0 = time.time(); s.connect((host,port))
    sock = s; return f"{int((time.time()-t0)*1000)}ms"
phase("TCP", do_tcp)

if sock:
    def read_key():
        sock.settimeout(8); data = b""
        deadline = time.time()+8
        while len(data)<4 and time.time()<deadline:
            try:
                c=sock.recv(4-len(data))
                if not c: break
                data+=c
            except socket.timeout: break
        if not data: raise Exception("no greeting from server")
        return f"0x{data.hex()} ({len(data)}B)"
    phase("ServerKey", read_key)

    def do_login():
        payload = bytes([0x01])+b"test_agent\x00test123\x00"
        sock.settimeout(5)
        sock.sendall(struct.pack(">H",len(payload))+payload)
        try: resp=sock.recv(64); return f"0x{resp.hex()[:32]}"
        except socket.timeout: return "timeout (server ignored)"
    phase("Login", do_login)
    try: sock.close()
    except: pass

jars = sorted(glob.glob("attached_assets/nrmod*.jar")+glob.glob("attached_assets/nro-client*.jar"))
def check_jar():
    if not jars: raise Exception("no JAR found")
    j=jars[-1]; sz=os.path.getsize(j)
    r=subprocess.run(["jar","tf",j],capture_output=True,text=True,timeout=10)
    classes=[l for l in r.stdout.split("\n") if l.endswith(".class")]
    return f"{os.path.basename(j)} {sz//1024}KB {len(classes)}cls"
phase("JAR", check_jar)

api_key = os.environ.get("AGNES_API_KEY","")
diagnosis = "AI unavailable"
if api_key:
    fails=[k for k,v in results.items() if not v["ok"]]
    oks=[k for k,v in results.items() if v["ok"]]
    prompt=f"""NRO client test bore.pub:{port}:
OK:{oks} FAIL:{fails}
ServerKey:{results.get('ServerKey',{}).get('data') or results.get('ServerKey',{}).get('error','N/A')}
Login:{results.get('Login',{}).get('data') or results.get('Login',{}).get('error','N/A')}
JAR:{results.get('JAR',{}).get('data') or results.get('JAR',{}).get('error','N/A')}
Phan tich (max 100 tu): client co vao duoc server khong? loi o dau? fix sao?"""
    try:
        pl=json.dumps({"model":"agnes-2.0-flash","messages":[{"role":"user","content":prompt}],"max_tokens":200,"temperature":0.3}).encode()
        req=urllib.request.Request("https://apihub.agnes-ai.com/v1/chat/completions",data=pl,
            headers={"Authorization":f"Bearer {api_key}","Content-Type":"application/json"})
        with urllib.request.urlopen(req,timeout=30) as r:
            diagnosis=json.loads(r.read())["choices"][0]["message"]["content"].strip()
        print(f"[AI] {diagnosis[:200]}")
    except Exception as e:
        diagnosis=f"AI err:{e}"; print(f"[WARN] {e}")

os.makedirs("agent_results",exist_ok=True)
now=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
all_ok=all(v["ok"] for v in results.values())
emoji="OK" if all_ok else ("WARN" if results.get("TCP",{}).get("ok") else "FAIL")
json.dump({"ts":now,"target":f"{host}:{port}","status":emoji,"results":results,"ai":diagnosis},
          open("agent_results/client_test.json","w"),ensure_ascii=False,indent=2)
with open("agent_results/client_log.txt","a") as f:
    f.write(f"{now} | {emoji} | {host}:{port} | {diagnosis[:90]}\n")
try:
    lines=open("agent_results/client_log.txt").readlines()
    if len(lines)>300: open("agent_results/client_log.txt","w").writelines(lines[-300:])
except: pass
print(f"[DONE] {emoji}")
