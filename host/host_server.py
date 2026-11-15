import json, os, re, socket, subprocess, threading, time, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONF_PATH = os.path.join(BASE_DIR, "host.conf")
SCORES_PATH = os.path.join(BASE_DIR, "highscores.json")
RA_CACHE_PATH = os.path.join(BASE_DIR, "ra_cache.json")

ROM_EXTS = {
    ".zip", ".7z", ".nes", ".sfc", ".smc", ".md", ".bin", ".gen", ".gba",
    ".gb", ".gbc", ".n64", ".z64", ".v64", ".iso", ".cue", ".chd", ".pbp",
    ".cso", ".nds", ".3ds", ".gcm", ".rvz", ".wbfs", ".xci", ".nsp", ".dsk", ".tap"
}

def read_host_conf():
    cfg = {
        "BASE_DIR": BASE_DIR, "ROMS_DIR": "", "THEMES_DIR": "",
        "BIND_ADDR": "0.0.0.0", "PIXELCADE_HW_IP": "",
        "RA_USER": "", "RA_API_KEY": ""
    }
    if os.path.exists(CONF_PATH):
        with open(CONF_PATH) as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.strip().split("=", 1)
                    cfg[k] = v.strip('"')
    return cfg

def build_rom_catalog(roms_dir):
    catalog = {}
    if not roms_dir or not os.path.isdir(roms_dir):
        return catalog
    for sys_name in sorted(os.listdir(roms_dir)):
        sys_path = os.path.join(roms_dir, sys_name)
        if not os.path.isdir(sys_path) or sys_name.startswith("."):
            continue
        names_map = {}
        gamelist_path = os.path.join(sys_path, "gamelist.xml")
        if os.path.isfile(gamelist_path):
            try:
                tree = ET.parse(gamelist_path)
                for game in tree.getroot().findall("game"):
                    p_el = game.find("path")
                    n_el = game.find("name")
                    if p_el is not None and p_el.text:
                        rom_base = os.path.splitext(os.path.basename(p_el.text.strip()))[0]
                        title = n_el.text.strip() if (n_el is not None and n_el.text) else rom_base
                        names_map[rom_base] = title
            except Exception:
                pass
        games = []
        seen = set()
        try:
            for entry in sorted(os.listdir(sys_path)):
                full_entry = os.path.join(sys_path, entry)
                if os.path.isdir(full_entry):
                    continue
                base, ext = os.path.splitext(entry)
                if ext.lower() in ROM_EXTS and base not in seen:
                    seen.add(base)
                    games.append({"rom": base, "name": names_map.get(base, base)})
        except Exception:
            pass
        if games or names_map:
            if not games:
                games = [{"rom": k, "name": v} for k, v in sorted(names_map.items(), key=lambda x: x[1].lower())]
            else:
                games.sort(key=lambda x: x["name"].lower())
            catalog[sys_name] = games
    return catalog

def safe_join(root_dir, rel_path):
    if not root_dir:
        return None
    root_abs = os.path.abspath(root_dir)
    target_abs = os.path.abspath(os.path.join(root_abs, rel_path.lstrip("/")))
    return target_abs if (target_abs == root_abs or target_abs.startswith(root_abs + os.sep)) else None

def load_json(path):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            pass
    return {}

def save_json(path, data):
    try:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
    except Exception:
        pass

def get_mame_hiscore(sys_name, rom_name, roms_dir):
    if sys_name.lower() not in ("mame", "fbneo", "neogeo", "arcade"):
        return ""
    saves_root = os.path.join(os.path.dirname(roms_dir.rstrip("/")), "saves")
    hi_candidates = [
        os.path.join(saves_root, "mame", "hi", f"{rom_name}.hi"),
        os.path.join(saves_root, "fbneo", f"{rom_name}.hi"),
        os.path.join(saves_root, sys_name, "hi", f"{rom_name}.hi"),
    ]
    hi_file = next((p for p in hi_candidates if os.path.isfile(p)), None)
    if not hi_file:
        return ""
    for bin_path in ("/usr/bin/hitotext", "/usr/local/bin/hitotext", os.path.join(BASE_DIR, "hitotext")):
        if os.path.isfile(bin_path) and os.access(bin_path, os.X_OK):
            try:
                out = subprocess.check_output([bin_path, "-r", hi_file], timeout=2, stderr=subprocess.DEVNULL).decode("utf-8", errors="ignore")
                lines = [l.strip() for l in out.splitlines() if l.strip() and not l.startswith("RANK")]
                if lines:
                    parts = re.split(r"\s+|\|", lines[0])
                    if len(parts) >= 2:
                        return f"1ST: {parts[1]} ({parts[2]})" if len(parts) >= 3 else f"1ST: {parts[1]}"
            except Exception:
                pass
    return ""

def get_ra_score(sys_name, rom_name, cfg):
    ra_user = cfg.get("RA_USER", "").strip()
    ra_key = cfg.get("RA_API_KEY", "").strip()
    if not ra_user or not ra_key:
        return ""
    cache = load_json(RA_CACHE_PATH)
    cache_key = f"{sys_name}:{rom_name}"
    now = time.time()
    if cache_key in cache and (now - cache[cache_key].get("ts", 0)) < 3600:
        return cache[cache_key].get("score", "")
    ra_log_dirs = ["/userdata/system/configs/retroarch/logs", "/opt/retropie/configs/all/retroarch/logs"]
    game_id = ""
    for d in ra_log_dirs:
        log_f = os.path.join(d, "retroarch.log")
        if os.path.isfile(log_f):
            try:
                txt = open(log_f, "r", errors="ignore").read()
                m = re.findall(r"\[Cheevos\].*?Game ID:\s*(\d+)", txt)
                if m:
                    game_id = m[-1]
                    break
            except Exception:
                pass
    score_str = ""
    if game_id:
        try:
            url = f"https://retroachievements.org/API/API_GetGameInfoAndUserProgress.php?z={urllib.parse.quote(ra_user)}&y={urllib.parse.quote(ra_key)}&u={urllib.parse.quote(ra_user)}&g={game_id}"
            req = urllib.request.urlopen(url, timeout=2.5)
            data = json.loads(req.read().decode("utf-8"))
            earned = data.get("NumAwardedToUser", 0)
            total = data.get("NumAchievements", 0)
            if total > 0:
                score_str = f"RA: {earned}/{total} Achievements ({ra_user})"
        except Exception:
            pass
    cache[cache_key] = {"ts": now, "score": score_str}
    save_json(RA_CACHE_PATH, cache)
    return score_str

def resolve_highscore(sys_name, rom_name, cfg):
    scores = load_json(SCORES_PATH)
    key = f"{sys_name}/{rom_name}"
    if key in scores and scores[key]:
        return str(scores[key])
    mame_sc = get_mame_hiscore(sys_name, rom_name, cfg.get("ROMS_DIR", ""))
    if mame_sc:
        return mame_sc
    ra_sc = get_ra_score(sys_name, rom_name, cfg)
    if ra_sc:
        return ra_sc
    return ""

class ConsolidatedHostHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        cfg = read_host_conf()
        clean_path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        target_file = None

        if clean_path == "/catalog":
            payload = json.dumps(build_rom_catalog(cfg.get("ROMS_DIR", ""))).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if clean_path.startswith("/highscore/"):
            parts = clean_path.strip("/").split("/")
            if len(parts) >= 3:
                _, sys_n, rom_n = parts[:3]
                score_txt = resolve_highscore(sys_n, rom_n, cfg)
                body = score_txt.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return

        if clean_path.startswith("/state/"):
            rel = clean_path[len("/state/"):]
            if rel in ("current_game.txt", "theme_path.txt", "marquees.tar.gz"):
                target_file = safe_join(cfg.get("BASE_DIR"), rel)
        elif clean_path.startswith("/roms/"):
            target_file = safe_join(cfg.get("ROMS_DIR"), clean_path[len("/roms/"):])
        elif clean_path.startswith("/themes/"):
            target_file = safe_join(cfg.get("THEMES_DIR"), clean_path[len("/themes/"):])

        if not target_file or not os.path.isfile(target_file):
            self.send_response(404)
            self.end_headers()
            return

        stat = os.stat(target_file)
        self.send_response(200)
        self.send_header("Content-Length", str(stat.st_size))
        self.send_header("Last-Modified", self.date_time_string(stat.st_mtime))
        self.end_headers()
        with open(target_file, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)

def udp_beacon_loop():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    while True:
        try:
            if read_host_conf().get("BIND_ADDR") != "127.0.0.1":
                sock.sendto(b"ARCADE_MARQUEE_HOST_V1", ("255.255.255.255", 8126))
        except Exception:
            pass
        time.sleep(3)

def pixelcade_forward_loop():
    state_file = os.path.join(BASE_DIR, "current_game.txt")
    last_line = ""
    while True:
        try:
            target_ip = read_host_conf().get("PIXELCADE_HW_IP", "").strip()
            if target_ip and os.path.exists(state_file):
                raw = open(state_file).read().strip()
                if raw and raw != last_line:
                    last_line = raw
                    parts = raw.split("|")
                    if len(parts) >= 3:
                        mode, sys_name, rom_name = parts[:3]
                        evt = "GameStart" if mode == "playing" else "SystemSelect" if mode == "system" else "GameSelect"
                        url = f"http://{target_ip}:8080/arcade/stream/{urllib.parse.quote(sys_name)}/{urllib.parse.quote(rom_name)}?event={evt}"
                        urllib.request.urlopen(url, timeout=1.5).read()
        except Exception:
            pass
        time.sleep(0.25)

if __name__ == "__main__":
    cfg = read_host_conf()
    threading.Thread(target=udp_beacon_loop, daemon=True).start()
    threading.Thread(target=pixelcade_forward_loop, daemon=True).start()
    ThreadingHTTPServer((cfg.get("BIND_ADDR", "0.0.0.0"), 8123), ConsolidatedHostHandler).serve_forever()