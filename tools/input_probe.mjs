/**
 * 验证"输入到底有没有生效"—— 尤其是网页版的第一人称视角。
 *
 * 为什么不能用截图判断：场景里有敌人巡逻、枪口动画、雾效，两张截图永远不一样，
 * "画面在动"根本区分不出"视角跟着鼠标转了"还是"敌人自己在走"。
 * 所以走游戏内的量化探针：URL 加 ?fps_debug=1 时 scripts/qa_probe.gd 会每 0.5 秒
 * 往控制台打一行 `[qa] yaw=.. pitch=.. touch=.. mouse_mode=.. paused=..`，
 * 这里抓控制台、比较扫动前后的 yaw 差值 —— 转了多少度是硬数据。
 *
 * 依赖：Node 18+（内置 fetch / WebSocket），以及一个带 --remote-debugging-port 的 Chrome。
 *
 * 用法：
 *   # 桌面条件（普通鼠标玩家）
 *   node tools/input_probe.mjs http://127.0.0.1:8765/index.html .tmp/probe-desktop
 *   # 复现"浏览器报告有触摸能力"的机器（Windows 触摸屏笔记本就是这种）
 *   TOUCH_EMU=1 node tools/input_probe.mjs http://127.0.0.1:8765/index.html .tmp/probe-touch
 *
 * 环境变量：
 *   TOUCH_EMU=1   打开触摸事件模拟（会让 'ontouchstart' in window 变成 true，
 *                 也就是 Godot 网页版判断"有触摸屏"的那个条件）
 *   MOBILE_UA=1   让浏览器自称移动设备（配合 VIEWPORT 一起用，模拟真手机）
 *   UA_ANDROID=1  把 UA 换成 Android 手机 —— Godot 的 web_android 特征只认 UA 字符串，
 *                 测"真手机是否自动出现触屏控件"必须用这个
 *   VIEWPORT=844x390  视口尺寸（默认 1280x720 桌面）
 *   CLICK=0       不先点一下画面（默认会点：浏览器要求指针锁定必须发生在用户手势里）
 *   SWEEP=0       不做鼠标扫动
 *   TOUCH_FIRST=1 加测"先摸屏幕、再动鼠标"（触摸屏笔记本场景）
 *
 * ⚠ 截图写到 .tmp/ 或工程外。写在工程根目录会被 Godot 当资源导入、然后打进 pck。
 */

import { connect, sleep } from "./cdp.mjs";
import fs from "node:fs";
import path from "node:path";

const DEBUG_PORT = Number(process.env.CDP_PORT || 9222);
const TOUCH_EMU = process.env.TOUCH_EMU === "1";
const DO_CLICK = process.env.CLICK !== "0";
const DO_SWEEP = process.env.SWEEP !== "0";
const DO_TOUCH_FIRST = process.env.TOUCH_FIRST === "1";
// 手机尺寸 + 手机 UA 标记。默认关（桌面尺寸，桌面 UA）——
// 关键：必须每轮都显式设定，不能靠"清掉上一次的模拟"。
// 踩过的坑：上一轮移动端测试留下的 mobile:true 会一直挂着，
// 让 Godot 把这一轮桌面测试也判定成手机平台，测出来的 touch=1 完全是假的。
const [VW, VH] = (process.env.VIEWPORT || "1280x720").split("x").map(Number);
const MOBILE_UA = process.env.MOBILE_UA === "1";
// 真手机模拟：换 UA 成 Android 手机（Godot 的 web_android 特征只认 UA 字符串）
const UA_ANDROID = process.env.UA_ANDROID === "1";

const [, , rawUrl, outDir = ".tmp/probe"] = process.argv;
if (!rawUrl) {
	console.error("用法: node input_probe.mjs <url> [输出目录]");
	process.exit(1);
}

// 强制带上探针参数：这一整个脚本的前提就是游戏里那行 [qa] 日志
const url = new URL(rawUrl);
url.searchParams.set("fps_debug", "1");

const QA_RE = /\[qa\]\s*yaw=(-?[\d.]+)\s+pitch=(-?[\d.]+)\s+touch=(-?\d+)\s+mouse_mode=(-?\d+)\s+paused=(\w+)(?:\s+ctl=(\d+))?/;

const qaHistory = [];
let last = null;
const consoleAll = [];

function pushQa(text) {
	const m = QA_RE.exec(text);
	if (!m) return;
	last = {
		yaw: Number(m[1]),
		pitch: Number(m[2]),
		touch: Number(m[3]),
		mouseMode: Number(m[4]),
		paused: m[5],
		ctl: m[6] === undefined ? 1 : Number(m[6]),
		at: Date.now(),
	};
	qaHistory.push(last);
}

/** 等一条足够新的 [qa] 行，避免拿到扫动前的旧值。 */
async function freshQa(ms = 2500) {
	const base = qaHistory.length;
	const t0 = Date.now();
	while (Date.now() - t0 < ms) {
		if (qaHistory.length > base) return qaHistory[qaHistory.length - 1];
		await sleep(100);
	}
	return last;
}

function modeName(m) {
	return ["VISIBLE", "HIDDEN", "CAPTURED", "CONFINED", "CONFINED_HIDDEN"][m] ?? `?${m}`;
}

/** 玩家脚本里 mouse_sensitivity = 0.0022 rad/px，换算成"每像素多少度"，用来算预期值。 */
const DEG_PER_PX = (0.0022 * 180) / Math.PI;

/** 记下浏览器已经收到的 mousemove 条数，作为后面统计位移的起点。 */
const mmMark = async (cdp) => (await cdp.eval("window.__mm ? window.__mm.length : -1"));

/** 从 mark 之后浏览器实际报出的 |movementX| 累计。这才是"游戏应该转多少度"的依据。 */
const movedPx = async (cdp, mark) => {
	if (mark < 0) return null;
	return await cdp.eval(`(() => { if (!window.__mm) return null;
		return window.__mm.slice(${mark}).reduce((s, m) => s + Math.abs(m[2]), 0); })()`);
};

async function mouseSweep(cdp, cx, cy, { drag = false, steps = 24, step = 20 } = {}) {
	if (drag) {
		await cdp.send("Input.dispatchMouseEvent", {
			type: "mousePressed", x: cx, y: cy, button: "left", buttons: 1, clickCount: 1,
		});
		await sleep(80);
	}
	for (let i = 1; i <= steps; i++) {
		await cdp.send("Input.dispatchMouseEvent", {
			type: "mouseMoved",
			x: cx + i * step,
			y: cy,
			button: drag ? "left" : "none",
			buttons: drag ? 1 : 0,
		});
		await sleep(25);
	}
	if (drag) {
		await cdp.send("Input.dispatchMouseEvent", {
			type: "mouseReleased", x: cx + steps * step, y: cy, button: "left", buttons: 0, clickCount: 1,
		});
	}
}

async function touchDrag(cdp, x0, y0, x1, y1, steps = 12) {
	await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [{ x: x0, y: y0, id: 1 }] });
	for (let i = 1; i <= steps; i++) {
		await cdp.send("Input.dispatchTouchEvent", {
			type: "touchMove",
			touchPoints: [{ x: x0 + ((x1 - x0) * i) / steps, y: y0 + ((y1 - y0) * i) / steps, id: 1 }],
		});
		await sleep(50);
	}
	await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
}

async function main() {
	const { cdp, target, close } = await connect(DEBUG_PORT, url.host);
	console.log(`[CDP] 已连接 target: ${target.url}`);

	cdp.on("Runtime.consoleAPICalled", (p) => {
		const text = p.args.map((a) => a.value ?? a.description ?? a.type).join(" ");
		if (text.includes("[qa]")) pushQa(text);
	});
	const jsErrors = [];
	cdp.on("Runtime.exceptionThrown", (p) =>
		jsErrors.push(p.exceptionDetails?.exception?.description?.split("\n")[0] ?? "?"));
	const logErrors = [];
	cdp.on("Log.entryAdded", (p) => {
		if (p.entry.level === "error") logErrors.push(p.entry.text);
	});

	await cdp.send("Runtime.enable");
	await cdp.send("Log.enable");
	await cdp.send("Page.enable");
	// 关掉缓存：否则重新导出之后 Chrome 可能还在用旧的 index.pck（python -m http.server
	// 不发 Cache-Control，Chrome 会按 Last-Modified 猜一个新鲜度），
	// 那样测到的就是上一次构建的行为，"修复前/后"的对比直接失效。
	await cdp.send("Network.enable");
	await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });

	// 视口和 UA 标记每轮都显式设定，不依赖"清掉上一次的模拟"（见文件头那个坑）
	await cdp.send("Emulation.setDeviceMetricsOverride", {
		width: VW,
		height: VH,
		deviceScaleFactor: 1,
		mobile: MOBILE_UA,
		screenOrientation: MOBILE_UA ? { type: "landscapePrimary", angle: 90 } : undefined,
	});
	// 这一项只翻转"浏览器支不支持触摸事件"，也就是 'ontouchstart' in window ——
	// Windows 触摸屏笔记本上 Chrome 的天然状态就是它 true、而尺寸/UA 仍是桌面。
	await cdp.send("Emulation.setTouchEmulationEnabled", {
		enabled: TOUCH_EMU,
		maxTouchPoints: TOUCH_EMU ? 5 : 1,
	});
	// 真手机路径：Godot 网页版的 web_android / web_ios 特征看的是 UA 字符串，
	// 所以必须真的换掉 UA（setDeviceMetricsOverride 的 mobile:true 不够 ——
	// 实测 navigator.userAgentData.mobile 仍然是 false）。
	await cdp.send("Emulation.setUserAgentOverride", {
		userAgent: UA_ANDROID
			? "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Mobile Safari/537.36"
			: "",
	});

	console.log(`[CDP] 导航到 ${url}`);
	await cdp.send("Page.navigate", { url: url.toString() });
	const t0 = Date.now();
	let loaded = false;
	while (Date.now() - t0 < 90000) {
		const gone = await cdp.eval(`document.getElementById('status') === null`);
		if (gone === true) {
			loaded = true;
			console.log(`[OK] 引擎启动完成（${((Date.now() - t0) / 1000).toFixed(1)}s）`);
			break;
		}
		await sleep(1000);
	}
	if (!loaded) console.log("[!] 加载超时");

	// 节奏要快：玩家站着不动会被敌人打死，一旦死了 paused=true / can_control=0，
	// 视角本来就不会响应，测出来的"转不动"就是假阳性。
	await sleep(1500);           // 让探针打几行

	const env = await cdp.eval(`({
		ontouchstart: 'ontouchstart' in window,
		maxTouchPoints: navigator.maxTouchPoints,
		uaMobile: navigator.userAgentData ? navigator.userAgentData.mobile : null,
		ua: navigator.userAgent.slice(0, 90),
		hasFocus: document.hasFocus(),
		pointerLock: document.pointerLockElement ? document.pointerLockElement.tagName : null,
		canvasRect: (() => { const c = document.querySelector('canvas');
			if (!c) return null; const r = c.getBoundingClientRect();
			return { x: r.left, y: r.top, w: r.width, h: r.height }; })(),
	})`);
	console.log("\n--- 浏览器侧事实 ---");
	console.log(`'ontouchstart' in window : ${env.ontouchstart}`);
	console.log(`navigator.maxTouchPoints  : ${env.maxTouchPoints}`);
	console.log(`UA 声称是移动设备          : ${env.uaMobile}   （Godot 的 mobile 特征就看这个）`);
	console.log(`UA                        : ${env.ua}`);
	console.log(`document.hasFocus()       : ${env.hasFocus}`);
	if (env.canvasRect) {
		// Godot 网页版的鼠标位移 = movementX * (canvas.width / rect.width)，
		// 所以这两个尺寸的比值直接决定灵敏度，值得打出来。
		const r = env.canvasRect;
		const backing = await cdp.eval(`(() => { const c = document.querySelector('canvas');
			return c ? { w: c.width, h: c.height } : null; })()`);
		const rw = backing && r.w ? backing.w / r.w : NaN;
		console.log(`canvas 显示尺寸           : ${Math.round(r.w)}x${Math.round(r.h)}`);
		console.log(`canvas 后备缓冲           : ${backing ? backing.w + "x" + backing.h : "?"}`);
		console.log(`换算系数 width/rect.width : ${rw.toFixed(2)}（应为 1 左右；远大于 1 会让鼠标灵敏度成倍放大）`);
	}

	// 记录浏览器实际报出来的 movementX/movementY：
	// 视角能不能转是一回事，转的量级对不对是另一回事（Godot 网页端用的是
	// movementX * canvas.width / rect.width，CDP 注入的事件未必和真鼠标一样）。
	await cdp.eval(`(() => { window.__mm = [];
		window.addEventListener('mousemove', (e) => {
			window.__mm.push([e.clientX, e.clientY, e.movementX, e.movementY]);
		}, true); return true; })()`);

	await saveShot(cdp, outDir, "1-初始.png");
	const before = last;
	console.log(`\n--- 初始状态 ---\n  ${fmt(before)}`);

	const rect = env.canvasRect;
	const cx = Math.round(rect ? rect.x + rect.w / 2 : 400);
	const cy = Math.round(rect ? rect.y + rect.h / 2 : 300);

	// ① 先点一下画面：浏览器要求 requestPointerLock() 发生在用户手势里
	let afterClick = before;
	if (DO_CLICK) {
		await cdp.send("Input.dispatchMouseEvent", {
			type: "mousePressed", x: cx, y: cy, button: "left", buttons: 1, clickCount: 1,
		});
		await sleep(60);
		await cdp.send("Input.dispatchMouseEvent", {
			type: "mouseReleased", x: cx, y: cy, button: "left", buttons: 0, clickCount: 1,
		});
		await sleep(600);
		afterClick = (await freshQa(1500)) ?? before;
		const pl = await cdp.eval(`document.pointerLockElement ? document.pointerLockElement.tagName : null`);
		console.log(`\n--- 点击画面后 ---\n  指针锁定=${pl ?? "无"}  ${fmt(afterClick)}`);
	}

	// ② 扫动鼠标：视角 yaw 应该跟着变。
	// 光看"yaw 变了"还不够 —— 得知道转的量级对不对，所以同时统计浏览器实际报出的
	// |movementX| 累计，按 0.0022 rad/px 换算出"应该转多少度"，和实测值比。
	let freeDelta = null;
	let freeExpected = null;
	let ratio = null;
	let dragDelta = null;
	if (DO_SWEEP) {
		const a = afterClick ?? before;
		const mark = await mmMark(cdp);
		await mouseSweep(cdp, cx, cy, { drag: false });
		await sleep(400);
		const b = (await freshQa(2500)) ?? a;
		freeDelta = yawDelta(a, b);
		const px = await movedPx(cdp, mark);
		freeExpected = px === null ? null : px * DEG_PER_PX;
		if (freeDelta !== null && freeExpected) ratio = Math.abs(freeDelta) / freeExpected;
		console.log(`\n--- 自由移动鼠标（不按键）---\n  ${fmt(b)}`);
		console.log(`  yaw 实测变化: ${freeDelta === null ? "无数据" : freeDelta.toFixed(1) + "°"}`);
		console.log(`  浏览器位移 ${px}px → 预期 ${freeExpected.toFixed(1)}°` +
			(ratio ? `（实测/预期 = ${ratio.toFixed(2)}）` : ""));
		await saveShot(cdp, outDir, "2-自由移动后.png");

		// ③ 按住左键拖动（有些实现只在按住时转动视角）
		const c = b;
		await mouseSweep(cdp, cx, cy, { drag: true });
		await sleep(400);
		const d = (await freshQa(2500)) ?? c;
		dragDelta = yawDelta(c, d);
		console.log(`\n--- 按住左键拖动 ---\n  ${fmt(d)}\n  yaw 变化: ${dragDelta === null ? "无数据" : dragDelta.toFixed(1) + "°"}`);
		await saveShot(cdp, outDir, "3-拖动后.png");
	}

	// ⑤ 触摸屏笔记本场景：先摸屏幕，再动鼠标。
	// 摸屏幕时触屏控件应该出现（否则平板/手机没控件）；
	// 之后动鼠标时控件应该让位（否则鼠标玩家永远被焊死在触屏模式）。
	let touchFirst = null;
	if (DO_TOUCH_FIRST) {
		await touchDrag(cdp, cx + 40, cy - 60, cx + 220, cy + 20);
		await sleep(500);
		const a = (await freshQa(1500)) ?? last;
		console.log(`\n--- ① 摸了一下屏幕后 ---\n  ${fmt(a)}\n  触屏控件: ${a && a.touch ? "出现 ✅" : "没出现 ❌"}`);
		await saveShot(cdp, outDir, "4-触摸后.png");

		await sleep(900);             // 越过 0.7 秒的仲裁窗口（touch_ui.gd 里的 MOUSE_TAKEOVER_DELAY_MS）
		await mouseSweep(cdp, cx, cy, { drag: false });
		await sleep(300);
		const b = (await freshQa(1500)) ?? a;
		const dy = yawDelta(a, b);
		touchFirst = { touchAfterTouch: a?.touch, touchAfterMouse: b?.touch, yawDelta: dy };
		console.log(`\n--- ② 接着动鼠标后 ---\n  ${fmt(b)}`);
		console.log(`  触屏控件: ${b && b.touch ? "仍占着 ❌" : "已让位给鼠标 ✅"}`);
		console.log(`  yaw 变化: ${dy === null ? "无数据" : dy.toFixed(1) + "°"}`);
		await saveShot(cdp, outDir, "5-触摸后动鼠标.png");
	}

	const total = yawDelta(before, last);
	const ok = total !== null && Math.abs(total) > 5;
	const dirty = [before, afterClick, last].some(interfered);
	// 构建里的 GDScript 报错必须先于一切结论：脚本编译失败时玩家脚本根本不加载，
	// 测出来的"输入没反应"完全是假象（这个坑真踩过：export 退出码是 0、游戏照样
	// 能启动渲染，但 player.gd 是空的）。
	const scriptErrors = consoleAll.filter((l) => l.includes("SCRIPT ERROR") || l.includes("Failed to load script"));
	console.log("\n================ 结论 ================");
	if (scriptErrors.length) {
		console.log(`⚠ 构建里有脚本错误（${scriptErrors.length} 条）—— 下面的输入结论全部不可信：`);
		for (const e of scriptErrors.slice(0, 6)) console.log("   -", e);
	}
	console.log(`触摸事件模拟      : ${TOUCH_EMU ? "开（模拟 Windows 触摸屏笔记本）" : "关（普通桌面）"}`);
	console.log(`触屏模式是否激活  : ${last ? (last.touch ? "是 ← 鼠标玩家会被夺走视角" : "否") : "无数据（探针没打印）"}`);
	console.log(`鼠标模式          : ${last ? modeName(last.mouseMode) : "无数据"}`);
	console.log(`全流程 yaw 总变化 : ${total === null ? "无数据" : total.toFixed(1) + "°"}`);
	console.log(`视角能否用鼠标控制: ${last && last.touch ? "不适用（触屏模式已接管，这是预期行为）" : ok ? "能 ✅" : "不能 ❌"}`);
	if (ratio) {
		const sane = ratio > 0.6 && ratio < 1.7;
		console.log(`灵敏度是否正常    : ${sane ? "正常 ✅" : "异常 ❌"}（实测/预期 = ${ratio.toFixed(2)}，应接近 1）`);
	}
	if (dirty) console.log(`⚠ 结果可能不可信    : 测量期间出现 paused=true 或 can_control=0（玩家死了），需要重测`);
	console.log(`JS 异常(${jsErrors.length})       : ${jsErrors.slice(0, 3).join(" | ") || "-"}`);
	console.log(`控制台错误(${logErrors.length})   : ${logErrors.slice(0, 3).join(" | ") || "-"}`);

	// 浏览器侧收到的原始鼠标位移。yaw 的数字受欧拉角回卷影响（±180° 之外会被折回来），
	// 所以量级要看这里：真鼠标每次移动通常是个位到几十像素。
	const mm = await cdp.eval(`window.__mm || []`);
	if (mm && mm.length) {
		const head = mm.slice(0, 6).map((m) => `(${m[0]},${m[1]}) Δ(${m[2]},${m[3]})`).join("  ");
		const sum = mm.reduce((s, m) => s + Math.abs(m[2]), 0);
		console.log(`\n浏览器收到 ${mm.length} 次 mousemove，|movementX| 累计 ${sum}px`);
		console.log(`  前几次: ${head}`);
	}
	if (!qaHistory.length) {
		console.log(`\n没有 [qa] 日志。页面控制台全部输出（前 15 条，用来区分"探针没挂上"和"print 没被抓到"）：`);
		console.log(consoleAll.slice(0, 15).map((l) => "   " + l).join("\n") || "   （控制台是空的）");
	}
	console.log("=====================================");

	close();
	process.exit(scriptErrors.length ? 3 : 0);
}

/**
 * 两个采样点之间 yaw 转了多少度。
 *
 * ⚠ 必须按 360° 取模：Godot 会把欧拉角 rotation.y 折回 ±180°，
 *   转两圈再采样会得到 "5597.8°" 这种离谱数字（实测量到过），
 *   照抄进结论就会把"能转"误读成"灵敏度爆炸"。
 */
const yawDelta = (from, to) => {
	if (!from || !to) return null;
	let d = to.yaw - from.yaw;
	while (d > 180) d -= 360;
	while (d < -180) d += 360;
	return d;
};

const fmt = (s) =>
	s
		? `yaw=${s.yaw.toFixed(1)}° touch=${s.touch} mouse_mode=${modeName(s.mouseMode)} ` +
			`paused=${s.paused} ctl=${s.ctl}`
		: "（无 [qa] 日志）";

/** 测量期间玩家死了 / 游戏暂停了，结果就不能算数 —— 那时视角本来就不该响应。 */
const interfered = (s) => !!s && (s.paused === "true" || s.ctl === 0);

async function saveShot(cdp, dir, name) {
	const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
	const abs = path.resolve(dir);
	fs.mkdirSync(abs, { recursive: true });
	if (!fs.existsSync(path.join(abs, ".gdignore"))) fs.writeFileSync(path.join(abs, ".gdignore"), "");
	fs.writeFileSync(path.join(abs, name), Buffer.from(shot.data, "base64"));
}

main().catch((err) => {
	console.error("探针失败:", err.message);
	process.exit(1);
});
