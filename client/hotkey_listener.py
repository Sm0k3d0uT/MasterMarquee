import glob, os, select, struct, urllib.request

# Linux input_event struct (64-bit: tv_sec, tv_usec, type, code, value)
EVENT_FMT = "llHHI"
EVENT_SIZE = struct.calcsize(EVENT_FMT)
EV_KEY = 0x01
KEY_LEFTCTRL, KEY_RIGHTCTRL = 29, 97
KEY_LEFTALT, KEY_RIGHTALT = 56, 100
KEY_E = 18

pressed = set()
fds = []
for dev in sorted(glob.glob("/dev/input/event*")):
    try:
        fd = os.open(dev, os.O_RDONLY | os.O_NONBLOCK)
        fds.append(fd)
    except Exception:
        pass

while fds:
    r, _, _ = select.select(fds, [], [])
    for fd in r:
        try:
            data = os.read(fd, EVENT_SIZE * 16)
            for i in range(0, len(data), EVENT_SIZE):
                _, _, etype, code, val = struct.unpack(EVENT_FMT, data[i:i+EVENT_SIZE])
                if etype == EV_KEY:
                    if val in (1, 2):
                        pressed.add(code)
                        if val == 1 and code == KEY_E and (pressed & {KEY_LEFTCTRL, KEY_RIGHTCTRL}) and (pressed & {KEY_LEFTALT, KEY_RIGHTALT}):
                            try:
                                urllib.request.urlopen("http://127.0.0.1:8080/cycle_effect", timeout=1.0).read()
                            except Exception:
                                pass
                    elif val == 0:
                        pressed.discard(code)
        except OSError:
            pass