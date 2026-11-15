import os, re, html, json, base64, hashlib, hmac, subprocess, urllib.parse
from email.parser import BytesParser
from email.policy import default as email_policy
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONF_PATH = os.path.join(BASE_DIR, "marquee.conf")
HOST_CONF_PATH = os.path.join(BASE_DIR, "host.conf")
SCORES_PATH = os.path.join(BASE_DIR, "highscores.json")
MEDIA_DIR = os.path.join(BASE_DIR, "marquees")
ACTIVE_IMG = "/dev/shm/marquee_display.png"
MAX_UPLOAD_BYTES = 150 * 1024 * 1024

def read_kv(path):
    cfg = {}
    if os.path.exists(path):
        with open(path) as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.strip().split("=", 1)
                    cfg[k] = v.strip('"')
    return cfg

def write_kv(path, cfg):
    with open(path, "w") as f:
        for k, v in cfg.items():
            safe_val = str(v).replace('"', "").replace("\n", "").replace("\r", "")
            f.write(f'{k}="{safe_val}"\n')
    os.chmod(path, 0o600)

def sanitize_name(name):
    cleaned = re.sub(r"[^a-zA-Z0-9._ -]", "", os.path.basename(name.strip()))
    return cleaned if cleaned not in ("", ".", "..") else ""

def first_param(params, key, default=""):
    vals = params.get(key)
    return next(iter(vals)) if vals else default

def verify_auth(headers, cfg):
    salt_hex, hash_hex = cfg.get("WEB_PASS_SALT", ""), cfg.get("WEB_PASS_HASH", "")
    if not salt_hex or not hash_hex:
        return True
    auth = headers.get("Authorization", "")
    if not auth.startswith("Basic "):
        return False
    try:
        _, pw = base64.b64decode(auth[6:]).decode("utf-8").split(":", 1)
        dk = hashlib.pbkdf2_hmac("sha256", pw.encode("utf-8"), bytes.fromhex(salt_hex), 100000).hex()
        return hmac.compare_digest(dk, hash_hex)
    except Exception:
        return False

class MarqueeHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def require_auth(self, cfg):
        if verify_auth(self.headers, cfg):
            return True
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Arcade Marquee"')
        self.end_headers()
        return False

    def do_GET(self):
        cfg = read_kv(CONF_PATH)
        hcfg = read_kv(HOST_CONF_PATH)
        if not self.require_auth(cfg):
            return
        parsed = urllib.parse.urlparse(self.path)
        path_clean = urllib.parse.unquote(parsed.path)
        qp = urllib.parse.parse_qs(parsed.query)

        if path_clean.startswith("/arcade/stream/"):
            parts = path_clean.strip("/").split("/")
            if len(parts) >= 4:
                _, _, raw_sys, raw_rom = parts[:4]
                rom_base, _ = os.path.splitext(raw_rom)
                sys_n, rom_n = sanitize_name(raw_sys), sanitize_name(rom_base)
                mode = "playing" if "start" in first_param(qp, "event").lower() else "browse"
                if sys_n == "black" and rom_n == "dummy":
                    open("/dev/shm/pixelcade_state.txt", "w").write("system|default|default\n")
                elif sys_n and rom_n:
                    open("/dev/shm/pixelcade_state.txt", "w").write(f"{mode}|{sys_n}|{rom_n}\n")
                open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return

        if path_clean == "/text":
            cfg["OVERLAY_TEXT"] = first_param(qp, "t")[:120]
            write_kv(CONF_PATH, cfg)
            open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return

        if path_clean == "/preview.png":
            if os.path.exists(ACTIVE_IMG):
                self.send_response(200)
                self.send_header("Content-type", "image/png")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(open(ACTIVE_IMG, "rb").read())
            else:
                self.send_response(404)
                self.end_headers()
            return

        now = html.escape(open("/dev/shm/marquee_now.txt").read().strip()) if os.path.exists("/dev/shm/marquee_now.txt") else "Idle"
        msg = "<p style='color:#4ade80'><b>Saved!</b></p>" if "msg=" in self.path else ""
        page = (
            "<!DOCTYPE html><html><head><title>Arcade Marquee</title><meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<style>body{font-family:sans-serif;background:#0f172a;color:#f8fafc;max-width:700px;margin:auto;padding:15px}"
            ".c{background:#1e293b;padding:14px;border-radius:8px;margin-bottom:12px}input,select{width:100%;padding:6px;margin:4px 0 8px;background:#0f172a;color:#fff;border:1px solid #475569}"
            "button{background:#2563eb;color:#fff;border:0;padding:8px 12px;border-radius:4px;cursor:pointer;margin-right:6px}</style></head><body>"
            f"<h2>Arcade Marquee ({html.escape(cfg.get('MARQUEE_MODE','native').upper())})</h2>{msg}"
            f"<div class='c'><img src='/preview.png' style='max-width:100%;max-height:150px'><p>Showing: <b>{now}</b></p></div>"
            "<div class='c'><h3>Log Manual High Score</h3><form method='POST' action='/hiscore'>"
            "<input name='system' placeholder='System (e.g. snes, mame, psx)' required>"
            "<input name='rom' placeholder='Exact ROM name without extension (e.g. dkong)' required>"
            "<input name='score' placeholder='High Score Text (e.g. 1ST: 125,000 - SMK) — leave blank to clear'>"
            "<button type='submit'>Save Score</button></form></div>"
            "<div class='c'><h3>Upload Art</h3><form method='POST' action='/upload' enctype='multipart/form-data'>"
            "<select name='category'><option value='startup'>Boot Splash / Fallback</option><option value='systems'>Console Wheel</option>"
            "<option value='game'>Game Marquee</option><option value='controls_sys'>Controls (System)</option><option value='controls_game'>Controls (Game)</option></select>"
            "<input name='system' placeholder='System (e.g. mame, snes)'><input name='rom' placeholder='Exact ROM name (no ext)'>"
            "<input type='file' name='file' required><button type='submit'>Upload</button></form></div>"
            "<div class='c'><h3>Settings</h3><form method='POST' action='/config'>"
            f"<label>Mode (native / pixelcade_rx / hybrid)</label><input name='MARQUEE_MODE' value='{html.escape(cfg.get('MARQUEE_MODE','native'))}'>"
            f"<label>Scaling (fit / stretch)</label><input name='SCALE_MODE' value='{html.escape(cfg.get('SCALE_MODE','fit'))}'>"
            f"<label>Enable High Scores (true / false)</label><input name='ENABLE_HIGHSCORES' value='{html.escape(cfg.get('ENABLE_HIGHSCORES','true'))}'>"
            f"<label>RetroAchievements Username (Host)</label><input name='RA_USER' value='{html.escape(hcfg.get('RA_USER',''))}'>"
            f"<label>RetroAchievements Web API Key (Host)</label><input name='RA_API_KEY' value='{html.escape(hcfg.get('RA_API_KEY',''))}'>"
            f"<label>Physical LCD Width (e.g. 1920)</label><input name='PHYS_W' value='{html.escape(cfg.get('PHYS_W',''))}'>"
            f"<label>Physical LCD Height (e.g. 440)</label><input name='PHYS_H' value='{html.escape(cfg.get('PHYS_H',''))}'>"
            f"<label>Host IP</label><input name='HOST_IP' value='{html.escape(cfg.get('HOST_IP',''))}'>"
            f"<label>Pixelcade HW IP</label><input name='PIXELCADE_HW_IP' value='{html.escape(cfg.get('PIXELCADE_HW_IP',''))}'>"
            f"<label>Banner Text</label><input name='OVERLAY_TEXT' value='{html.escape(cfg.get('OVERLAY_TEXT',''))}'>"
            f"<label>Sleep Start (HH:MM)</label><input name='SLEEP_START' value='{html.escape(cfg.get('SLEEP_START',''))}'>"
            f"<label>Sleep End (HH:MM)</label><input name='SLEEP_END' value='{html.escape(cfg.get('SLEEP_END',''))}'>"
            "<button type='submit'>Save</button></form></div>"
            "<div class='c'><form method='POST' action='/action'><button name='cmd' value='splash'>Splash</button>"
            "<button name='cmd' value='attract'>Attract</button><button name='cmd' value='reboot' style='background:#b91c1c'>Reboot</button></form></div></body></html>"
        )
        self.send_response(200)
        self.send_header("Content-type", "text/html")
        self.end_headers()
        self.wfile.write(page.encode())

    def do_POST(self):
        cfg = read_kv(CONF_PATH)
        if not self.require_auth(cfg):
            return
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > MAX_UPLOAD_BYTES:
            self.send_response(413)
            self.end_headers()
            return
        body = self.rfile.read(length)

        if self.path == "/hiscore":
            params = parse_qs(body.decode("utf-8", errors="ignore"))
            sys_n = sanitize_name(first_param(params, "system"))
            rom_n = sanitize_name(first_param(params, "rom"))
            score_val = first_param(params, "score").strip()[:100]
            if sys_n and rom_n:
                scores = {}
                if os.path.exists(SCORES_PATH):
                    try:
                        scores = json.load(open(SCORES_PATH, "r", encoding="utf-8"))
                    except Exception:
                        scores = {}
                key = f"{sys_n}/{rom_n}"
                if score_val:
                    scores[key] = score_val
                else:
                    scores.pop(key, None)
                with open(SCORES_PATH, "w", encoding="utf-8") as f:
                    json.dump(scores, f, indent=2)
                open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(303)
            self.send_header("Location", "/?msg=ok")
            self.end_headers()
        elif self.path == "/config":
            params = parse_qs(body.decode("utf-8", errors="ignore"))
            for k in ["MARQUEE_MODE", "SCALE_MODE", "ENABLE_HIGHSCORES", "PHYS_W", "PHYS_H", "HOST_IP", "PIXELCADE_HW_IP", "SLEEP_START", "SLEEP_END", "OVERLAY_TEXT"]:
                cfg[k] = first_param(params, k)
            write_kv(CONF_PATH, cfg)
            if os.path.exists(HOST_CONF_PATH):
                hcfg = read_kv(HOST_CONF_PATH)
                hcfg["RA_USER"] = first_param(params, "RA_USER")
                hcfg["RA_API_KEY"] = first_param(params, "RA_API_KEY")
                write_kv(HOST_CONF_PATH, hcfg)
            open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(303)
            self.send_header("Location", "/?msg=ok")
            self.end_headers()
        elif self.path == "/action":
            cmd = first_param(parse_qs(body.decode("utf-8", errors="ignore")), "cmd")
            if cmd == "splash": open("/dev/shm/marquee_test_splash", "w").close()
            elif cmd == "attract": open("/dev/shm/marquee_test_attract", "w").close()
            elif cmd == "reboot": subprocess.Popen(["/sbin/reboot"])
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
        elif self.path == "/upload":
            msg = BytesParser(policy=email_policy).parsebytes(f"Content-Type: {self.headers.get('Content-Type','')}\r\n\r\n".encode() + body)
            fields, file_data, file_ext = {}, None, ""
            for part in msg.iter_parts():
                name = part.get_param("name", header="Content-Disposition")
                fname = part.get_param("filename", header="Content-Disposition")
                if fname:
                    _, ext_raw = os.path.splitext(fname)
                    if ext_raw.lower() in (".png", ".jpg", ".jpeg", ".svg", ".mp4", ".mkv"):
                        file_ext, file_data = ext_raw.lower(), part.get_payload(decode=True)
                elif name:
                    fields[name] = part.get_content().strip()
            if file_data and file_ext:
                cat, sys_n, rom_n = fields.get("category", "startup"), sanitize_name(fields.get("system", "")), sanitize_name(fields.get("rom", ""))
                routes = {
                    "systems": (os.path.join(MEDIA_DIR, "custom", "systems"), f"{sys_n}{file_ext}") if sys_n else None,
                    "game": (os.path.join(MEDIA_DIR, "custom", sys_n), f"{rom_n}{file_ext}") if (sys_n and rom_n) else None,
                    "controls_sys": (os.path.join(MEDIA_DIR, "custom", "controls"), f"{sys_n}{file_ext}") if sys_n else None,
                    "controls_game": (os.path.join(MEDIA_DIR, "custom", "controls", sys_n), f"{rom_n}{file_ext}") if (sys_n and rom_n) else None,
                }
                dest_dir, dest_name = routes.get(cat) or (os.path.join(MEDIA_DIR, "custom", "startup"), f"default{file_ext}")
                os.makedirs(dest_dir, exist_ok=True)
                open(os.path.join(dest_dir, dest_name), "wb").write(file_data)
                open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(303)
            self.send_header("Location", "/?msg=ok")
            self.end_headers()

if __name__ == "__main__":
    cfg = read_kv(CONF_PATH)
    bind_ip = "127.0.0.1" if (cfg.get("CLIENT_MODE") == "local" and not os.path.exists(HOST_CONF_PATH)) else "0.0.0.0"
    ThreadingHTTPServer((bind_ip, 8080), MarqueeHandler).serve_forever()