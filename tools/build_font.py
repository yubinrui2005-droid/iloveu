#!/usr/bin/env python3
"""把中文字体子集化后打包进工程。

## 为什么需要这个脚本

Godot 自带的默认主题字体不含中文字形。桌面端能靠「系统字体回退」兜住，
所以你在编辑器里看到的中文是正常的；但 Web 导出（以及部分 Android 设备）
跑在沙盒里，没有系统字体可以回退，所有中文就会变成 □□□ 豆腐块。

解决办法只有一个：把字体文件本身打包进工程。

## 为什么要子集化

完整的 Noto Sans SC 是 17 MB，而本工程实际只用到 800 来个字符。
用 fontTools 裁掉用不到的字形后通常能压到几百 KB，Web 首屏加载时间差一个数量级。

## 用法

    python tools/build_font.py

产物：
    assets/fonts/game_font.ttf    ← 会被 Godot 导入并作为全局默认字体
    assets/fonts/OFL.txt          ← 字体许可证（OFL 要求随附）

注意：**改了界面文案之后要重新跑一次**，否则新出现的字会变成豆腐块。
"""

from __future__ import annotations

import glob
import os
import sys
import urllib.request

from fontTools import subset
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "fonts")
OUT_FONT = os.path.join(OUT_DIR, "game_font.ttf")
OUT_LICENSE = os.path.join(OUT_DIR, "OFL.txt")
CACHE_DIR = os.path.join(ROOT, ".font-cache")

FONT_URLS = [
    "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf",
    "https://gh-proxy.com/https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/NotoSansSC%5Bwght%5D.ttf",
]
LICENSE_URLS = [
    "https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/OFL.txt",
    "https://gh-proxy.com/https://raw.githubusercontent.com/google/fonts/main/ofl/notosanssc/OFL.txt",
]

# 界面上可能出现的、但代码里搜不到的字符（运行时拼出来的、或符号）
EXTRA_CHARS = "★☆·—…←→×÷≥≤°「」『』（），。：；？！、％　"

SCAN_GLOBS = [
    "scripts/*.gd",
    "tools/*.gd",
    "scenes/*.tscn",
    "project.godot",
    "export_presets.cfg",
]


def collect_chars() -> str:
    chars: set[str] = set()
    for pattern in SCAN_GLOBS:
        for path in glob.glob(os.path.join(ROOT, pattern)):
            with open(path, encoding="utf-8") as fh:
                for ch in fh.read():
                    if ord(ch) > 127:
                        chars.add(ch)
    # ASCII 可打印字符一定要带上，否则连数字和英文都会缺字
    chars.update(chr(i) for i in range(32, 127))
    chars.update(EXTRA_CHARS)
    return "".join(sorted(chars))


def download(urls: list[str], dest: str, min_size: int = 1_000_000) -> None:
    if os.path.exists(dest) and os.path.getsize(dest) >= min_size:
        print(f"  已有缓存 {os.path.basename(dest)}")
        return
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    last_err: Exception | None = None
    for url in urls:
        try:
            print(f"  下载 {url.split('/')[2]} …")
            with urllib.request.urlopen(url, timeout=300) as resp:
                data = resp.read()
            if len(data) < min_size:
                raise RuntimeError(f"文件太小（{len(data)} 字节），可能被拦截了")
            with open(dest, "wb") as fh:
                fh.write(data)
            print(f"  完成：{len(data) / 1024:.1f} KB")
            return
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            print(f"  失败：{exc}")
    raise SystemExit(f"下载失败（{urls[0]}）：{last_err}")


def main() -> int:
    print("[1/4] 收集工程里用到的字符…")
    text = collect_chars()
    non_ascii = sum(1 for c in text if ord(c) > 127)
    print(f"  共 {len(text)} 个字符（其中中文/符号 {non_ascii} 个）")

    os.makedirs(CACHE_DIR, exist_ok=True)
    src = os.path.join(CACHE_DIR, "NotoSansSC-var.ttf")
    print("[2/4] 准备源字体…")
    download(FONT_URLS, src)
    if not os.path.exists(OUT_LICENSE):
        download(LICENSE_URLS, OUT_LICENSE, min_size=100)

    print("[3/4] 子集化…")
    options = subset.Options()
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.notdef_outline = True
    options.recalc_bounds = True
    options.hinting = False
    options.glyph_names = False
    options.drop_tables += ["DSIG"]

    font = subset.load_font(src, options)
    subsetter = subset.Subsetter(options=options)
    subsetter.populate(text=text)
    subsetter.subset(font)

    tmp = os.path.join(CACHE_DIR, "subset.ttf")
    subset.save_font(font, tmp, options)
    print(f"  子集大小：{os.path.getsize(tmp) / 1024:.0f} KB")

    print("[4/4] 实例化可变字体到 wght=500 并输出…")
    static = TTFont(tmp)
    instancer.instantiateVariableFont(static, {"wght": 500}, inplace=True,
                                      updateFontNames=True)
    os.makedirs(OUT_DIR, exist_ok=True)
    static.save(OUT_FONT)
    print(f"  输出 {OUT_FONT}")
    print(f"  最终大小：{os.path.getsize(OUT_FONT) / 1024:.0f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
