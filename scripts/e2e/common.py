"""Shared helpers for the per-app end-to-end modules."""
import json, os, subprocess, time, uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BIN = os.environ.get("APPLE_CLI_BIN", os.path.join(ROOT, ".build/release/apple-cli"))
TOKEN = "e2e-" + uuid.uuid4().hex[:10]
SYNC_TIMEOUT = 120
steps = []


def cli(*args, config=None):
    """Runs apple-cli with --json. Returns (parsed output, milliseconds).
    `config` is a dict written to a temp config file for this one call."""
    env = dict(os.environ)
    if config is not None:
        import tempfile
        f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
        json.dump(config, f); f.close()
        env["APPLE_CLI_CONFIG"] = f.name
    t = time.perf_counter()
    p = subprocess.run([BIN, *args, "--json"], capture_output=True, text=True, timeout=90, env=env)
    if config is not None:
        os.unlink(env["APPLE_CLI_CONFIG"])
    ms = (time.perf_counter() - t) * 1000
    out = json.loads(p.stdout) if p.stdout.strip() else {"error": {"code": "no_output", "message": p.stderr.strip()}}
    return out, ms


def err(out):
    e = out.get("error")
    return e and f"{e.get('code')}: {e.get('message')}"


def step(app, name, fn):
    """Runs one step, records pass or fail, and keeps going so cleanup still runs."""
    t = time.perf_counter()
    try:
        detail, cmd_ms = fn()
        ok = True
    except Exception as e:
        detail, cmd_ms, ok = f"{type(e).__name__}: {e}", None, False
    total = (time.perf_counter() - t) * 1000
    steps.append((app, name, ok, cmd_ms, total, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {app} {name}  ({total:.0f} ms)  {detail}")
    return ok


def check(cond, msg):
    if not cond:
        raise AssertionError(msg)


def poll(fn, timeout):
    end = time.time() + timeout
    while time.time() < end:
        v = fn()
        if v:
            return v
        time.sleep(1)
    return None


def user_config():
    """The user's real config, so privacy tests start from their rules and add one."""
    p = os.environ.get("APPLE_CLI_CONFIG", os.path.expanduser("~/.config/apple-cli/config.json"))
    try:
        return json.load(open(p))
    except FileNotFoundError:
        return {}
