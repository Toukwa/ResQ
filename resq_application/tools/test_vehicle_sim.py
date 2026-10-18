"""ResQ test vehicle: drives a fake GPS tracker along real Iriga City roads.

It behaves like the ESP32 tracker (hardware/esp32_resq_tracker, v8): signs in with its own
tracker account, writes its live position to trackers/<uid> every few seconds, and records
route points (on turns / every 150 m / every 30 s) that it uploads in batches to
tracker_history/<uid>.

Two signal cuts are simulated so the gap handling can be checked:
  1. LOST:     like the old firmware - no position and no route points for a while.
               The History map should show a dashed line along the road (not a straight
               line through buildings) with a "no signal" marker, and the live map pin
               should jump instead of sliding across the gap.
  2. BUFFERED: like the new firmware - no live position, but route points are kept and
               uploaded when the signal returns. The History map should show no gap at all.

Run (Python 3, no extra packages):
    python tools/test_vehicle_sim.py
    python tools/test_vehicle_sim.py --kph 60 --interval 2

The first run creates the account tracker-simtest01@resq-tracker.app. It then appears in
the admin app as an Unassigned vehicle: assign it (plate, type, department) once, then
open its History to see the route. Ctrl+C stops it.
"""

import argparse
import json
import math
import sys
import time
import urllib.error
import urllib.request

API_KEY = "AIzaSyDHBxLSpKSbICYzLekvrysNP7dobVZFK6s"
RTDB = "https://resq-db-41ff8-default-rtdb.asia-southeast1.firebasedatabase.app"
OSRM = "https://router.project-osrm.org"
HARDWARE_ID = "SIM:TE:ST:00:00:01"
EMAIL = "tracker-simtest01@resq-tracker.app"

# A loop through Iriga City's streets (lat, lng); OSRM turns it into the road path.
WAYPOINTS = [
    (13.42340, 123.41160),  # city centre
    (13.43190, 123.41760),
    (13.43350, 123.40860),
    (13.42620, 123.40330),
    (13.41700, 123.40900),
    (13.42340, 123.41160),
]

# Same rules as the firmware
HISTORY_MAX_INTERVAL_S = 30
HISTORY_MIN_INTERVAL_S = 2
HISTORY_TURN_DEG = 20
HISTORY_TURN_MIN_M = 15
HISTORY_STRAIGHT_M = 150
HISTORY_FLUSH_S = 10
HISTORY_BATCH = 25


def request(method, url, body=None, form=False):
    data = None
    headers = {}
    if body is not None:
        if form:
            data = body.encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        else:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as res:
            text = res.read().decode()
            return res.status, (json.loads(text) if text else None)
    except urllib.error.HTTPError as e:
        text = e.read().decode()
        try:
            return e.code, json.loads(text)
        except ValueError:
            return e.code, text


class Auth:
    def __init__(self, password):
        self.password = password
        self.token = None
        self.uid = None
        self.got = 0

    def sign_in(self):
        body = {"email": EMAIL, "password": self.password, "returnSecureToken": True}
        code, r = request("POST", f"https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key={API_KEY}", body)
        if code != 200:
            print("No tracker account yet - creating", EMAIL)
            code, r = request("POST", f"https://identitytoolkit.googleapis.com/v1/accounts:signUp?key={API_KEY}", body)
        if code != 200:
            sys.exit(f"Sign-in failed ({code}): {r}")
        self.token, self.uid, self.got = r["idToken"], r["localId"], time.time()

    def id_token(self):
        if self.token is None or time.time() - self.got > 50 * 60:
            self.sign_in()
        return self.token


def distance_m(a, b):
    r = 6371000
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


def bearing(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dl = math.radians(b[1] - a[1])
    y = math.sin(dl) * math.cos(p2)
    x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl)
    return (math.degrees(math.atan2(y, x)) + 360) % 360


def road_path():
    coords = ";".join(f"{lng},{lat}" for lat, lng in WAYPOINTS)
    code, r = request("GET", f"{OSRM}/route/v1/driving/{coords}?overview=full&geometries=geojson")
    if code != 200 or r.get("code") != "Ok":
        sys.exit(f"Could not get a road route from OSRM ({code}): {r}")
    path = [(c[1], c[0]) for c in r["routes"][0]["geometry"]["coordinates"]]
    print(f"Road route: {r['routes'][0]['distance'] / 1000:.2f} km, {len(path)} shape points")
    return path


def positions(path, kph, interval):
    """Positions every `interval` seconds when driving `path` at `kph`."""
    step = kph / 3.6 * interval
    i, pos, left = 0, path[0], step
    yield pos, bearing(path[0], path[1])
    while i < len(path) - 1:
        seg = distance_m(pos, path[i + 1])
        if seg >= left:
            f = left / seg if seg else 1
            pos = (pos[0] + (path[i + 1][0] - pos[0]) * f, pos[1] + (path[i + 1][1] - pos[1]) * f)
            yield pos, bearing(path[i], path[i + 1])
            left = step
        else:
            left -= seg
            pos = path[i + 1]
            i += 1
    yield path[-1], bearing(path[-2], path[-1])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kph", type=float, default=40, help="driving speed (default 40)")
    ap.add_argument("--interval", type=float, default=3, help="seconds between live updates (default 3, like the SIM)")
    ap.add_argument("--password", default="simtest-ResQ-2026", help="tracker account password")
    ap.add_argument("--laps", type=int, default=1, help="times to drive the loop (default 1)")
    args = ap.parse_args()

    auth = Auth(args.password)
    auth.sign_in()
    print("Tracker uid:", auth.uid)
    path = road_path()
    steps = list(positions(path, args.kph, args.interval))
    n = len(steps)
    lost = range(int(n * 0.25), int(n * 0.40))      # signal cut 1: nothing kept
    buffered = range(int(n * 0.60), int(n * 0.75))  # signal cut 2: points kept, uploaded later
    print(f"{n} updates per lap (~{n * args.interval / 60:.1f} min). Signal cut 1 (lost) at updates "
          f"{lost.start}-{lost.stop}, cut 2 (buffered) at {buffered.start}-{buffered.stop}.\n")

    buffer, last_flush = [], 0
    last_point = None  # (time, pos, course)

    def flush():
        nonlocal buffer, last_flush
        last_flush = time.time()
        while buffer:
            batch = buffer[:HISTORY_BATCH]
            body = {f"t{p['ts']}": p for p in batch}
            code, r = request("PATCH", f"{RTDB}/tracker_history/{auth.uid}.json?auth={auth.id_token()}&print=silent", body)
            if code not in (200, 204):
                print(f"  ! history upload failed ({code}): {r}")
                return
            buffer = buffer[len(batch):]
            print(f"  history: uploaded {len(batch)} point(s), {len(buffer)} still buffered")

    for lap in range(args.laps):
        for k, (pos, course) in enumerate(steps):
            now = time.time()
            in_lost, in_buffered = k in lost, k in buffered
            online = not (in_lost or in_buffered)
            if k == lost.start:
                print(">> SIGNAL CUT 1 (lost): nothing is recorded until it comes back")
            if k == lost.stop:
                print("<< signal back")
            if k == buffered.start:
                print(">> SIGNAL CUT 2 (buffered): route points kept on the board")
            if k == buffered.stop:
                print("<< signal back - uploading the buffered points")

            # Route history, like recordHistoryPoint() on the board
            if not in_lost:
                due = last_point is None
                if not due and now - last_point[0] >= HISTORY_MIN_INTERVAL_S:
                    moved = distance_m(last_point[1], pos)
                    turn = abs(course - last_point[2]) % 360
                    turn = 360 - turn if turn > 180 else turn
                    due = (now - last_point[0] >= HISTORY_MAX_INTERVAL_S or moved >= HISTORY_STRAIGHT_M
                           or (turn >= HISTORY_TURN_DEG and moved >= HISTORY_TURN_MIN_M))
                if due:
                    ts = int(now * 1000)
                    buffer.append({"latitude": round(pos[0], 7), "longitude": round(pos[1], 7),
                                   "speed_kph": args.kph, "ts": ts})
                    last_point = (now, pos, course)
            else:
                last_point = None  # the old firmware kept nothing; start fresh after

            if online:
                body = {
                    "hardwareId": HARDWARE_ID, "hasFix": True,
                    "latitude": round(pos[0], 7), "longitude": round(pos[1], 7),
                    "speed_kph": args.kph, "course_deg": round(course, 1), "altitude_m": 30,
                    "satellites": 9, "source": "simulator",
                    "fix_timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                    "received_at": {".sv": "timestamp"},
                }
                code, r = request("PATCH", f"{RTDB}/trackers/{auth.uid}.json?auth={auth.id_token()}&print=silent", body)
                state = "ok" if code in (200, 204) else f"FAILED {code}: {r}"
                print(f"[lap {lap + 1} {k + 1}/{n}] {pos[0]:.5f}, {pos[1]:.5f}  {state}")
                if buffer and (now - last_flush >= HISTORY_FLUSH_S or len(buffer) > HISTORY_BATCH):
                    flush()
            else:
                print(f"[lap {lap + 1} {k + 1}/{n}] (no signal) {len(buffer)} point(s) buffered")

            time.sleep(max(0, args.interval - (time.time() - now)))
    flush()
    print("\nDone. Open the vehicle's History in the admin app to check the route.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\nStopped.")
