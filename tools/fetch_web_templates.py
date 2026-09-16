"""按需下载 Godot 导出模板包(.tpz)里指定的条目，避免下载整个 1.2 GB。

思路：.tpz 就是 zip。实现一个支持 seek 的只读 HTTP 文件对象（用 Range 请求），
交给标准库 zipfile 解析，于是只有真正被读到的字节才会走网络。

用法:
    python fetch_web_templates.py list                  # 列出 zip 内所有条目
    python fetch_web_templates.py extract <输出目录> [条目前缀...]
"""

import io
import os
import sys
import urllib.request
import zipfile

VERSION = "4.7.1-stable"
URL = (
    f"https://github.com/godotengine/godot/releases/download/"
    f"{VERSION}/Godot_v{VERSION}_export_templates.tpz"
)


class HttpRangeFile(io.RawIOBase):
    """只读、可 seek 的 HTTP 文件，读哪段就请求哪段。"""

    def __init__(self, url: str, chunk: int = 1 << 20):
        self._url = url
        self._chunk = chunk
        self._pos = 0
        self._buf = b""
        self._buf_start = 0
        self._requests = 0

        req = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(req, timeout=60) as resp:
            self._size = int(resp.headers["Content-Length"])
            # 确认服务端支持分段
            if resp.headers.get("Accept-Ranges", "").lower() != "bytes":
                raise RuntimeError("服务端不支持 Range 请求，无法按需下载")

    # --- io.RawIOBase 接口 -------------------------------------------------
    def readable(self) -> bool:
        return True

    def seekable(self) -> bool:
        return True

    def tell(self) -> int:
        return self._pos

    def seek(self, offset: int, whence: int = io.SEEK_SET) -> int:
        if whence == io.SEEK_SET:
            self._pos = offset
        elif whence == io.SEEK_CUR:
            self._pos += offset
        elif whence == io.SEEK_END:
            self._pos = self._size + offset
        return self._pos

    def readinto(self, b) -> int:
        n = len(b)
        if n == 0:
            return 0
        data = self._read_at(self._pos, n)
        b[: len(data)] = data
        self._pos += len(data)
        return len(data)

    # --- 内部 --------------------------------------------------------------
    def _fetch(self, start: int, length: int) -> bytes:
        end = min(start + length, self._size) - 1
        if end < start:
            return b""
        req = urllib.request.Request(
            self._url, headers={"Range": f"bytes={start}-{end}"}
        )
        with urllib.request.urlopen(req, timeout=120) as resp:
            self._requests += 1
            return resp.read()

    def _read_at(self, start: int, length: int) -> bytes:
        if start >= self._size:
            return b""
        # 命中缓存
        if self._buf and self._buf_start <= start < self._buf_start + len(self._buf):
            off = start - self._buf_start
            if off + length <= len(self._buf):
                return self._buf[off : off + length]
        # 未命中：多读一点（chunk）减少请求次数
        want = max(length, self._chunk)
        self._buf = self._fetch(start, want)
        self._buf_start = start
        return self._buf[:length]

    @property
    def request_count(self) -> int:
        return self._requests


def open_remote_zip() -> tuple[zipfile.ZipFile, HttpRangeFile]:
    f = HttpRangeFile(URL)
    return zipfile.ZipFile(io.BufferedReader(f)), f


def cmd_list() -> None:
    zf, f = open_remote_zip()
    total = 0
    print(f"{'大小(MB)':>10}  条目")
    print("-" * 60)
    for info in sorted(zf.infolist(), key=lambda i: -i.file_size):
        total += info.file_size
        print(f"{info.file_size / 1048576:10.2f}  {info.filename}")
    print("-" * 60)
    print(f"共 {len(zf.infolist())} 个条目，解压后合计 {total / 1048576:.1f} MB")
    print(f"实际网络请求次数: {f.request_count}")


def cmd_extract(out_dir: str, wanted: list[str]) -> None:
    zf, f = open_remote_zip()
    os.makedirs(out_dir, exist_ok=True)
    picked = 0
    for info in zf.infolist():
        if info.is_dir():
            continue
        name = info.filename
        if name.startswith("templates/"):
            name = name[len("templates/") :]
        if wanted and not any(w in name for w in wanted):
            continue
        dest = os.path.join(out_dir, name)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with zf.open(info) as src, open(dest, "wb") as dst:
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                dst.write(chunk)
        picked += 1
        print(f"[OK] {name}  ({info.file_size / 1048576:.2f} MB)")
    print(f"\n共提取 {picked} 个文件 -> {out_dir}")
    print(f"实际网络请求次数: {f.request_count}")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] == "list":
        cmd_list()
    elif sys.argv[1] == "extract":
        cmd_extract(sys.argv[2], sys.argv[3:])
    else:
        print(__doc__)
        sys.exit(1)
