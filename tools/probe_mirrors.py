"""测速：比较 GitHub release 各加速源，为模板下载挑一条能走的路。

每个源尝试请求 4 MB，最多等 20 秒，报告是否支持 Range、实际拿到多少字节、速度。
"""

import socket
import time
import urllib.request

ASSET = (
    "https://github.com/godotengine/godot/releases/download/"
    "4.7.1-stable/Godot_v4.7.1-stable_export_templates.tpz"
)

PROXIES = [
    ("直连 GitHub（基准）", ""),
    ("ghproxy.net", "https://ghproxy.net/"),
    ("gh-proxy.com", "https://gh-proxy.com/"),
    ("ghfast.top", "https://ghfast.top/"),
    ("gh.llkk.cc", "https://gh.llkk.cc/"),
    ("github.moeyy.xyz", "https://github.moeyy.xyz/"),
    ("hk.gh-proxy.com", "https://hk.gh-proxy.com/"),
    ("ghproxy.cc", "https://ghproxy.cc/"),
]

LIMIT = 4 << 20      # 只看前 4 MB
DEADLINE = 20        # 每个源最多等 20 秒


def probe(name: str, prefix: str) -> None:
    url = prefix + ASSET
    req = urllib.request.Request(url, headers={"Range": f"bytes=0-{LIMIT - 1}"})
    got = 0
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=DEADLINE) as resp:
            code = resp.status
            ranges = resp.headers.get("Accept-Ranges", "-")
            while True:
                if time.time() - t0 > DEADLINE:
                    break
                chunk = resp.read(1 << 16)
                if not chunk:
                    break
                got += len(chunk)
    except Exception as exc:  # noqa: BLE001
        dt = time.time() - t0
        print(f"{name:<22} 失败: {type(exc).__name__}: {str(exc)[:60]}")
        return
    dt = max(time.time() - t0, 0.001)
    speed = got / dt / 1024
    flag = "OK " if got >= LIMIT else "慢 "
    print(
        f"{name:<22} {flag} HTTP:{code} Range:{ranges:<5} "
        f"{got / 1048576:5.2f} MB / {dt:5.1f}s = {speed:8.1f} KB/s"
    )


if __name__ == "__main__":
    socket.setdefaulttimeout(DEADLINE)
    print(f"{'加速源':<22} {'结果'}")
    print("-" * 78)
    for name, prefix in PROXIES:
        probe(name, prefix)
