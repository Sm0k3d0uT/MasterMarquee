import os, re, html, json, time, base64, hashlib, hmac, subprocess, urllib.parse, urllib.request
from email.parser import BytesParser
from email.policy import default as email_policy
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONF_PATH = os.path.join(BASE_DIR, "marquee.conf")
HOST_CONF_PATH = os.path.join(BASE_DIR, "host.conf")
SCORES_PATH = os.path.join(BASE_DIR, "highscores.json")
EFFECTS_PATH = os.path.join(BASE_DIR, "effects.json")
MEDIA_DIR = os.path.join(BASE_DIR, "marquees")
ACTIVE_IMG = "/dev/shm/marquee_display.png"
MAX_UPLOAD_BYTES = 150 * 1024 * 1024

BUILTIN_EFFECTS = [
    ("none", "None (Clean Artwork)"),
    ("lightning_single", "Lightning: Single Arc (Animated)"),
    ("lightning_storm", "Lightning: Dual Storm (Animated)"),
    ("lightning_border", "Lightning: Tesla Border (Animated)"),
    ("embers_orange", "Embers: Fire Sparks (Animated)"),
    ("embers_blue", "Embers: Plasma Sparks (Animated)"),
    ("vhs_rgb", "VHS: RGB Chroma Shift (Animated)"),
    ("scanlines_fine", "Scanlines: Fine 1px (Static)"),
    ("scanlines_thick", "Scanlines: Heavy Retro (Static)"),
    ("led_matrix_round", "LED Matrix: Round Pitch (Static)"),
    ("led_matrix_square", "LED Matrix: Square Grid (Static)"),
    ("vignette", "Lightbox: Corner Vignette (Static)"),
]

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

def load_json_file(path):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def save_json_file(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)

def fetch_catalog(cfg):
    host_ip = cfg.get("HOST_IP", "127.0.0.1")
    if host_ip in ("", "auto", "pixelcade"):
        host_ip = "127.0.0.1"
    try:
        req = urllib.request.urlopen(f"http://{host_ip}:8123/catalog", timeout=2.0)
        return json.loads(req.read().decode("utf-8"))
    except Exception:
        return {}

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

        if path_clean == "/cycle_effect":
            fx_dir = os.path.join(MEDIA_DIR, "custom", "effects")
            os.makedirs(fx_dir, exist_ok=True)
            custom_files = [f for f in sorted(os.listdir(fx_dir)) if os.path.isfile(os.path.join(fx_dir, f))]
            cycle_ids = [val for val, _ in BUILTIN_EFFECTS] + custom_files

            now_raw = open("/dev/shm/marquee_now.txt").read().strip() if os.path.exists("/dev/shm/marquee_now.txt") else ""
            target_key = ""
            if " / " in now_raw:
                parts_now = now_raw.split(" (", 1)[0].split(" / ", 1)
                if len(parts_now) == 2 and parts_now[0] != "system":
                    s_n, r_n = sanitize_name(parts_now[0]), sanitize_name(parts_now[1])
                    if s_n and r_n:
                        target_key = f"{s_n}/{r_n}"

            effects_map = load_json_file(EFFECTS_PATH)
            if target_key:
                cur_fx = effects_map.get(target_key) or effects_map.get(target_key.split("/")[0]) or cfg.get("OVERLAY_EFFECT", "none")
                next_idx = (cycle_ids.index(cur_fx) + 1) % len(cycle_ids) if cur_fx in cycle_ids else 1
                next_fx = cycle_ids[next_idx]
                effects_map[target_key] = next_fx
                save_json_file(EFFECTS_PATH, effects_map)
            else:
                cur_fx = cfg.get("OVERLAY_EFFECT", "none")
                next_idx = (cycle_ids.index(cur_fx) + 1) % len(cycle_ids) if cur_fx in cycle_ids else 1
                next_fx = cycle_ids[next_idx]
                cfg["OVERLAY_EFFECT"] = next_fx
                write_kv(CONF_PATH, cfg)

            open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "target": target_key or "global", "effect": next_fx}).encode())
            return

        if path_clean == "/trigger_fx":
            fx_name = sanitize_name(first_param(qp, "fx", "lightning_storm"))
            try:
                dur = max(0.5, min(30.0, float(first_param(qp, "sec", "3"))))
            except ValueError:
                dur = 3.0
            with open("/dev/shm/marquee_burst_fx.txt", "w") as f:
                f.write(f"{fx_name}|{time.time() + dur}\n")
            open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(200)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "burst_fx": fx_name, "duration": dur}).encode())
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

        now_raw = open("/dev/shm/marquee_now.txt").read().strip() if os.path.exists("/dev/shm/marquee_now.txt") else "Idle"
        now = html.escape(now_raw)
        active_sys, active_rom = "", ""
        if " / " in now_raw:
            parts_now = now_raw.split(" (", 1)[0].split(" / ", 1)
            if len(parts_now) == 2 and parts_now[0] != "system":
                active_sys, active_rom = sanitize_name(parts_now[0]), sanitize_name(parts_now[1])

        msg = "<p style='color:#4ade80'><b>Saved!</b></p>" if "msg=" in self.path else ""

        fx_dir = os.path.join(MEDIA_DIR, "custom", "effects")
        os.makedirs(fx_dir, exist_ok=True)
        custom_files = [f for f in sorted(os.listdir(fx_dir)) if os.path.isfile(os.path.join(fx_dir, f))]
        all_fx_choices = BUILTIN_EFFECTS + [(f, f"Custom File: {f}") for f in custom_files]

        cur_global_fx = cfg.get("OVERLAY_EFFECT", "none")
        global_opts = "".join(
            f"<option value='{html.escape(val)}' {'selected' if val == cur_global_fx else ''}>{html.escape(lbl)}</option>"
            for val, lbl in all_fx_choices
        )
        rule_opts = "".join(
            f"<option value='{html.escape(val)}'>{html.escape(lbl)}</option>"
            for val, lbl in all_fx_choices
        )

        effects_map = load_json_file(EFFECTS_PATH)
        rules_html = "".join(
            f"<li style='margin-bottom:4px'><code>{html.escape(k)}</code> &rarr; <b>{html.escape(v)}</b> "
            f"<form method='POST' action='/effect_rule' style='display:inline'>"
            f"<input type='hidden' name='rule_key' value='{html.escape(k)}'>"
            f"<input type='hidden' name='effect' value='__DELETE__'>"
            f"<button type='submit' style='background:#b91c1c;padding:2px 6px;font-size:0.8em'>Remove</button></form></li>"
            for k, v in sorted(effects_map.items())
        ) or "<li style='color:#94a3b8'>No per-game or per-emulator overrides set yet.</li>"

        quick_active_html = ""
        if active_sys and active_rom:
            quick_active_html = (
                f"<form method='POST' action='/effect_rule' style='background:#0f172a;padding:10px;border-radius:6px;margin-bottom:10px'>"
                f"<div style='margin-bottom:6px;font-size:0.9em'>Currently Highlighted: <b>{html.escape(active_sys)} / {html.escape(active_rom)}</b></div>"
                f"<input type='hidden' name='system' value='{html.escape(active_sys)}'>"
                f"<input type='hidden' name='rom' value='{html.escape(active_rom)}'>"
                f"<select name='effect'>{rule_opts}</select>"
                f"<button type='submit' style='background:#16a34a'>Apply to Current Game</button></form>"
            )

        catalog_json = json.dumps(fetch_catalog(cfg)).replace("</", "<\\/")

        page = (
            "<!DOCTYPE html><html><head><title>Arcade Marquee</title><meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<style>body{font-family:sans-serif;background:#0f172a;color:#f8fafc;max-width:720px;margin:auto;padding:15px}"
            ".c{background:#1e293b;padding:14px;border-radius:8px;margin-bottom:12px}input,select{width:100%;padding:6px;margin:4px 0 8px;background:#0f172a;color:#fff;border:1px solid #475569}"
            "button{background:#2563eb;color:#fff;border:0;padding:8px 12px;border-radius:4px;cursor:pointer;margin-right:6px}</style></head><body>"
            f"<h2>Arcade Marquee ({html.escape(cfg.get('MARQUEE_MODE','native').upper())})</h2>{msg}"
            f"<div class='c'><img src='/preview.png' style='max-width:100%;max-height:150px'><p>Showing: <b>{now}</b></p></div>"
            f"<div class='c'><h3>Overlay Effects (Select Emulator or Game)</h3>{quick_active_html}"
            "<form method='POST' action='/effect_rule'>"
            "<label>1. Select Emulator / System</label><select name='system' class='sys-sel' data-rom-target='fx-rom' data-blank-label='-- Entire Emulator (All Games) --' required></select>"
            "<label>2. Select Game (or leave on Entire Emulator)</label><select name='rom' id='fx-rom'></select>"
            f"<label>3. Select Effect</label><select name='effect'>{rule_opts}</select>"
            "<button type='submit'>Save Effect Rule</button></form>"
            f"<ul style='margin-top:10px;padding-left:18px;font-size:0.9em'>{rules_html}</ul></div>"
            "<div class='c'><h3>Log Manual High Score</h3><form method='POST' action='/hiscore'>"
            "<label>Emulator / System</label><select name='system' class='sys-sel' data-rom-target='hs-rom' required></select>"
            "<label>Game</label><select name='rom' id='hs-rom' required></select>"
            "<input name='score' placeholder='High Score Text (e.g. 1ST: 125,000 - SMK) — leave blank to clear'>"
            "<button type='submit'>Save Score</button></form></div>"
            "<div class='c'><h3>Upload Art or Custom Effect (.png / .webm)</h3><form method='POST' action='/upload' enctype='multipart/form-data'>"
            "<select name='category'><option value='startup'>Boot Splash / Fallback</option><option value='systems'>Console Wheel</option>"
            "<option value='game'>Game Marquee</option><option value='controls_sys'>Controls (System)</option><option value='controls_game'>Controls (Game)</option>"
            "<option value='effect_global'>Custom Overlay Effect (Global Library)</option>"
            "<option value='effect_sys'>Custom Overlay Effect (Per-Emulator)</option>"
            "<option value='effect_game'>Custom Overlay Effect (Per-Game)</option></select>"
            "<label>Emulator / System (if applicable)</label><select name='system' class='sys-sel' data-rom-target='up-rom' data-blank-label='-- None / Global --'></select>"
            "<label>Game (if applicable)</label><select name='rom' id='up-rom'></select>"
            "<input type='file' name='file' required><button type='submit'>Upload</button></form></div>"
            "<div class='c'><h3>Settings</h3><form method='POST' action='/config'>"
            f"<label>Global Default Overlay Effect</label><select name='OVERLAY_EFFECT'>{global_opts}</select>"
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
            "<button name='cmd' value='attract'>Attract</button><button name='cmd' value='reboot' style='background:#b91c1c'>Reboot</button></form></div>"
            f"<script>const CAT={catalog_json};"
            "function fillRoms(sysSel){const romSel=document.getElementById(sysSel.dataset.romTarget);if(!romSel)return;romSel.innerHTML='';"
            "const blank=sysSel.dataset.blankLabel;if(blank){const o=document.createElement('option');o.value='';o.textContent=blank;romSel.appendChild(o);}"
            "(CAT[sysSel.value]||[]).forEach(g=>{const o=document.createElement('option');o.value=g.rom;o.textContent=g.name+' ('+g.rom+')';romSel.appendChild(o);});}"
            "document.querySelectorAll('.sys-sel').forEach(s=>{Object.keys(CAT).forEach(sys=>{const o=document.createElement('option');o.value=sys;o.textContent=sys.toUpperCase();s.appendChild(o);});"
            "s.addEventListener('change',()=>fillRoms(s));fillRoms(s);});</script></body></html>"
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

        if self.path == "/effect_rule":
            params = parse_qs(body.decode("utf-8", errors="ignore"))
            fx_val = first_param(params, "effect").strip()
            rule_key = first_param(params, "rule_key").strip()
            effects_map = load_json_file(EFFECTS_PATH)
            if fx_val == "__DELETE__" and rule_key:
                effects_map.pop(rule_key, None)
            else:
                sys_n = sanitize_name(first_param(params, "system"))
                rom_n = sanitize_name(first_param(params, "rom"))
                if sys_n:
                    target_key = f"{sys_n}/{rom_n}" if rom_n else sys_n
                    effects_map[target_key] = fx_val
            save_json_file(EFFECTS_PATH, effects_map)
            open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(303)
            self.send_header("Location", "/?msg=ok")
            self.end_headers()
        elif self.path == "/hiscore":
            params = parse_qs(body.decode("utf-8", errors="ignore"))
            sys_n = sanitize_name(first_param(params, "system"))
            rom_n = sanitize_name(first_param(params, "rom"))
            score_val = first_param(params, "score").strip()[:100]
            if sys_n and rom_n:
                scores = load_json_file(SCORES_PATH)
                key = f"{sys_n}/{rom_n}"
                if score_val:
                    scores[key] = score_val
                else:
                    scores.pop(key, None)
                save_json_file(SCORES_PATH, scores)
                open("/dev/shm/marquee_force_refresh", "w").close()
            self.send_response(303)
            self.send_header("Location", "/?msg=ok")
            self.end_headers()
        elif self.path == "/config":
            params = parse_qs(body.decode("utf-8", errors="ignore"))
            for k in ["OVERLAY_EFFECT", "MARQUEE_MODE", "SCALE_MODE", "ENABLE_HIGHSCORES", "PHYS_W", "PHYS_H", "HOST_IP", "PIXELCADE_HW_IP", "SLEEP_START", "SLEEP_END", "OVERLAY_TEXT"]:
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
            fields, file_data, file_ext, orig_name = {}, None, "", ""
            for part in msg.iter_parts():
                name = part.get_param("name", header="Content-Disposition")
                fname = part.get_param("filename", header="Content-Disposition")
                if fname:
                    orig_name = sanitize_name(fname)
                    _, ext_raw = os.path.splitext(fname)
                    if ext_raw.lower() in (".png", ".jpg", ".jpeg", ".svg", ".mp4", ".mkv", ".webm"):
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
                    "effect_global": (os.path.join(MEDIA_DIR, "custom", "effects"), orig_name) if orig_name else None,
                    "effect_sys": (os.path.join(MEDIA_DIR, "custom", "effects"), f"{sys_n}{file_ext}") if sys_n else None,
                    "effect_game": (os.path.join(MEDIA_DIR, "custom", "effects", sys_n), f"{rom_n}{file_ext}") if (sys_n and rom_n) else None,
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