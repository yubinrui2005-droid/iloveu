/**
 * 用 Chrome DevTools Protocol 验证一个 Godot Web 导出能否真正跑起来。
 *
 * 为什么需要它：Godot 的 Web 构建要下载并实例化 ~40 MB 的 wasm，
 * `--virtual-time-budget + --screenshot` 这种一次性截图会和 wasm 加载抢时间，
 * 经常只截到 Godot 启动画面，无法判断游戏到底有没有跑起来。
 * 这里改成轮询页面状态：等到加载遮罩消失（= 引擎启动完成）再截图，
 * 同时收集控制台报错和 JS 异常。
 *
 * 依赖：只有 Node 18+（用内置的 fetch 和 WebSocket），不需要 puppeteer/playwright。
 *
 * 用法：
 *   1) 先起静态服务器，例如：
 *        cd build/web && python -m http.server 8765 --bind 127.0.0.1
 *   2) 用调试端口启动 Chrome：
 *        chrome --headless=new --remote-debugging-port=9222 \
 *               --enable-unsafe-swiftshader --use-angle=swiftshader \
 *               --window-size=1280,720 about:blank
 *   3) node tools/browser_check.mjs http://127.0.0.1:8765/index.html .tmp/出图.png [超时秒数]
 *
 * ⚠ 截图一定要写进 .tmp/ 或项目外。
 *   写在工程根目录会被 Godot 当成资源导入，然后打进 pck
 *   （export_filter=all_resources，而且 export_presets.cfg 的 exclude_filter 管不到它）——
 *   实测这么干会让每次导出的 pck 越滚越大。`.tmp/` 里放了 .gdignore，Godot 会整个跳过。
 *
 * 手机/触屏模式（验证虚拟摇杆那套 UI）：
 *   TOUCH=1 VIEWPORT=844x390 node tools/browser_check.mjs http://127.0.0.1:8765/index.html .tmp/手机.png
 *   TOUCH=1 时会打开触屏模拟并按 VIEWPORT 伪造设备尺寸（默认 844x390 横屏）。
 *   设 SWIPE=1 还会在左半屏做一次拖拽，用来确认摇杆真的能吃到触摸输入。
 */

const [, , targetUrl, outPath = ".tmp/shot.png", timeoutSec = "90"] = process.argv;
const DEBUG_PORT = process.env.CDP_PORT || 9222;
const TIMEOUT_MS = Number(timeoutSec) * 1000;

const TOUCH = process.env.TOUCH === "1";
const SWIPE = process.env.SWIPE === "1";
const [VW, VH] = (process.env.VIEWPORT || "844x390").split("x").map(Number);

if (!targetUrl) {
	console.error("用法: node browser_check.mjs <url> <输出png> [超时秒数]");
	process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 找到浏览器里第一个 page 类型的 target，返回它的 CDP WebSocket 地址。 */
async function findPageTarget() {
	for (let i = 0; i < 40; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${DEBUG_PORT}/json/list`);
			const list = await res.json();
			const page = list.find(
				(t) => t.type === "page" && t.webSocketDebuggerUrl
			);
			if (page) return page;
		} catch {
			/* 浏览器还没起来，继续等 */
		}
		await sleep(500);
	}
	throw new Error(`连不上 Chrome 调试端口 ${DEBUG_PORT}，确认 Chrome 已带 --remote-debugging-port 启动`);
}

/** 极简 CDP 客户端：发命令、等回包、收事件。 */
class CDP {
	constructor(ws) {
		this.ws = ws;
		this.id = 0;
		this.pending = new Map();
		this.handlers = new Map();
		ws.addEventListener("message", (ev) => {
			const msg = JSON.parse(ev.data);
			if (msg.id !== undefined) {
				const p = this.pending.get(msg.id);
				if (!p) return;
				this.pending.delete(msg.id);
				msg.error
					? p.reject(new Error(`${msg.error.message} (${JSON.stringify(msg.error.data ?? "")})`))
					: p.resolve(msg.result);
			} else if (msg.method) {
				const fns = this.handlers.get(msg.method) ?? [];
				for (const fn of fns) fn(msg.params);
			}
		});
	}

	on(method, fn) {
		if (!this.handlers.has(method)) this.handlers.set(method, []);
		this.handlers.get(method).push(fn);
	}

	send(method, params = {}) {
		const id = ++this.id;
		return new Promise((resolve, reject) => {
			this.pending.set(id, { resolve, reject });
			this.ws.send(JSON.stringify({ id, method, params }));
			setTimeout(() => {
				if (this.pending.delete(id)) reject(new Error(`CDP 超时: ${method}`));
			}, 60000);
		});
	}

	async eval(expression) {
		const r = await this.send("Runtime.evaluate", {
			expression,
			returnByValue: true,
			awaitPromise: true,
		});
		if (r.exceptionDetails) {
			return { __error: r.exceptionDetails.exception?.description ?? "eval 抛异常" };
		}
		return r.result.value;
	}
}

async function main() {
	const target = await findPageTarget();
	console.log(`[CDP] 已连接 target: ${target.url}`);

	const ws = new WebSocket(target.webSocketDebuggerUrl);
	await new Promise((resolve, reject) => {
		ws.addEventListener("open", resolve, { once: true });
		ws.addEventListener("error", () => reject(new Error("CDP WebSocket 连接失败")), { once: true });
	});
	const cdp = new CDP(ws);

	const consoleErrors = [];
	const exceptions = [];
	cdp.on("Runtime.consoleAPICalled", (p) => {
		if (p.type === "error" || p.type === "warning") {
			const text = p.args.map((a) => a.value ?? a.description ?? a.type).join(" ");
			(p.type === "error" ? consoleErrors : consoleErrors).push(`[${p.type}] ${text}`);
		}
	});
	cdp.on("Runtime.exceptionThrown", (p) => {
		exceptions.push(p.exceptionDetails?.exception?.description ?? JSON.stringify(p.exceptionDetails));
	});
	cdp.on("Log.entryAdded", (p) => {
		if (p.entry.level === "error") consoleErrors.push(`[log] ${p.entry.text}`);
	});

	await cdp.send("Runtime.enable");
	await cdp.send("Log.enable");
	await cdp.send("Page.enable");

	if (TOUCH) {
		// 伪造成一台横屏手机：只改设备尺寸 + 打开触摸事件，不换 userAgent。
		// Godot 的 OS.has_feature("mobile") 在 Web 上拿不到，所以游戏是靠自己
		// 检测有没有触摸事件来启用虚拟摇杆的——必须真的让触摸事件进得来。
		await cdp.send("Emulation.setDeviceMetricsOverride", {
			width: VW,
			height: VH,
			deviceScaleFactor: 1,
			mobile: true,
			screenOrientation: { type: "landscapePrimary", angle: 90 },
		});
		await cdp.send("Emulation.setTouchEmulationEnabled", {
			enabled: true,
			maxTouchPoints: 5,
		});
		console.log(`[CDP] 触屏模拟已开启，视口 ${VW}x${VH}`);
	}

	console.log(`[CDP] 导航到 ${targetUrl}`);
	await cdp.send("Page.navigate", { url: targetUrl });

	// 轮询等待：Godot 启动成功后会把 #status 遮罩整个移除
	const t0 = Date.now();
	let loaded = false;
	while (Date.now() - t0 < TIMEOUT_MS) {
		const state = await cdp.eval(`(() => {
			const status = document.getElementById('status');
			const notice = document.getElementById('status-notice');
			return {
				statusGone: status === null,
				noticeText: notice && notice.style.display !== 'none' ? notice.innerText.trim() : '',
				progress: document.getElementById('status-progress')?.value ?? null,
				title: document.title,
				canvas: !!document.querySelector('canvas'),
			};
		})()`);
		if (state.__error) {
			console.log(`[页面] 求值异常: ${state.__error}`);
		} else if (state.noticeText) {
			console.log(`[!] 页面显示错误提示: ${state.noticeText}`);
			break;
		} else if (state.statusGone) {
			loaded = true;
			console.log(`[OK] 加载遮罩已移除，引擎启动完成（耗时 ${((Date.now() - t0) / 1000).toFixed(1)}s）`);
			break;
		} else {
			process.stdout.write(`\r[..] 加载中 进度=${state.progress ?? "-"}  已等待 ${((Date.now() - t0) / 1000).toFixed(0)}s  `);
		}
		await sleep(1000);
	}
	process.stdout.write("\n");

	// 多给几帧让游戏真正渲染出来（程序化关卡 + 第一波刷怪）
	if (loaded) {
		await sleep(4000);
	}

	// 触屏拖拽：在左半屏按住往上滑 = 推左边的虚拟摇杆，玩家应该走起来。
	// 这个动作会真正走到 TouchUI 的 _move / _apply_touch_look 分支；
	// 如果那套代码有问题，这里会以脚本错误的形式冒出来。
	let swipeEffect = null;
	if (loaded && SWIPE) {
		const before = await cdp.send("Page.captureScreenshot", { format: "png" });
		const jx = Math.round(VW * 0.18);
		const jy = Math.round(VH * 0.72);
		await cdp.send("Input.dispatchTouchEvent", {
			type: "touchStart",
			touchPoints: [{ x: jx, y: jy, id: 1 }],
		});
		for (let i = 1; i <= 14; i++) {
			await cdp.send("Input.dispatchTouchEvent", {
				type: "touchMove",
				touchPoints: [{ x: jx + i * 2, y: jy - i * 5, id: 1 }],
			});
			await sleep(60);
		}
		await sleep(1600);
		const after = await cdp.send("Page.captureScreenshot", { format: "png" });
		await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
		swipeEffect = before.data !== after.data;
		console.log(`[触屏] 摇杆拖拽后画面变化: ${swipeEffect ? "是" : "否"}`);
	}

	// 看画面是不是真的在动：连拍两张，比较是否完全一致（一致则说明卡住了）
	const shot1 = await cdp.send("Page.captureScreenshot", { format: "png" });
	await sleep(1200);
	const shot2 = await cdp.send("Page.captureScreenshot", { format: "png" });
	const moving = shot1.data !== shot2.data;

	const glInfo = await cdp.eval(`(() => {
		const c = document.querySelector('canvas');
		if (!c) return { error: '没有 canvas 元素' };
		const gl = c.getContext('webgl2');
		return {
			canvasSize: c.width + 'x' + c.height,
			hasWebGL2: !!gl,
			renderer: gl ? gl.getParameter(gl.VERSION) : null,
		};
	})()`);

	// 写截图。顺便保证输出目录里有一个 .gdignore —— 图写在工程内会被 Godot
	// 当成资源导入、然后打进 pck（见文件头那段说明），.gdignore 能让它整个跳过。
	const fs = await import("node:fs");
	const path = await import("node:path");
	let outFile = outPath;
	let dir = path.dirname(path.resolve(outFile));
	if (fs.existsSync(path.join(dir, "project.godot"))) {
		// 工程根目录不能放 .gdignore（那会让 Godot 忽略整个工程），所以挪进 .tmp/
		outFile = path.join(dir, ".tmp", path.basename(outFile));
		dir = path.dirname(outFile);
		console.warn(`[warn] 输出路径不能放在工程根目录，已改写到 ${outFile}`);
	}
	fs.mkdirSync(dir, { recursive: true });
	const gdignore = path.join(dir, ".gdignore");
	if (!fs.existsSync(gdignore)) fs.writeFileSync(gdignore, "");
	fs.writeFileSync(outFile, Buffer.from(shot2.data, "base64"));

	console.log("\n================ 验证结果 ================");
	console.log("引擎启动      :", loaded ? "成功" : "失败/超时");
	console.log("触屏模拟      :", TOUCH ? `开（${VW}x${VH}）` : "关（桌面）");
	if (swipeEffect !== null) {
		console.log("摇杆拖拽生效  :", swipeEffect ? "是" : "否");
	}
	console.log("画面是否在动  :", moving ? "是（两次截图不同，说明有渲染）" : "否（画面静止，可能卡住）");
	console.log("Canvas / WebGL:", JSON.stringify(glInfo));
	console.log("控制台报错数  :", consoleErrors.length);
	for (const e of consoleErrors.slice(0, 10)) console.log("   -", e);
	console.log("JS 异常数     :", exceptions.length);
	for (const e of exceptions.slice(0, 5)) console.log("   -", String(e).split("\n")[0]);
	console.log("截图已保存    :", outFile);
	console.log("==========================================");

	ws.close();
	process.exit(loaded ? 0 : 2);
}

main().catch((err) => {
	console.error("验证脚本失败:", err.message);
	process.exit(1);
});
