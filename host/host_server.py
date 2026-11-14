import os, socket, threading, time, urllib.parse, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONF_PATH = os.path.join(BASE_DIR, "host.conf")

def read_host_conf():
    cfg = {"BASE_DIR": BASE_DIR, "ROMS_DIR": "", "THEMES_DIR": "", "BIND_ADDR": "0.0.0.0", "PIXELCADE_HW_IP": ""}
    if os.path.exists(CONF_PATH):
        with open(CONF_PATH) as f:
            for line in f:
                if "=" in line and not line.strip().startswith("#"):
                    k, v = line.strip().split("=", 1)
                    cfg[k] = v.strip('"')
    return cfg

def safe_join(root_dir, rel_path):
    if not root_dir:
        return None
    root_abs = os.path.abspath(root_dir)
    target_abs = os.path.abspath(os.path.join(root_abs, rel_path.lstrip("/")))
    return target_abs if (target_abs == root_abs or target_abs.startswith(root_abs + os.sep)) else None

class ConsolidatedHostHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        cfg = read_host_conf()
        clean_path = urllib.parse.unquote(urllib.parse.urlparse(self.path).path)
        target_file = None

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