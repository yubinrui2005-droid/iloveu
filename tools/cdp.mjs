/**
 * 极简 Chrome DevTools Protocol 客户端（零依赖，只用 Node 内置的 fetch / WebSocket）。
 *
 * 抽出来是因为验证脚本越来越多：browser_check.mjs（跑起来没有 + 截图）、
 * input_probe.mjs（输入到底有没有生效）。重复一份 50 行的 CDP 客户端没必要。
 *
 * 用法：
 *   import { connect } from "./cdp.mjs";
 *   const { cdp, close } = await connect(9222);
 */

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 找到浏览器里第一个 page 类型的 target，返回它。给了 hint 就优先选 URL 里含 hint 的那个。 */
export async function findPageTarget(port = 9222, hint = "") {
	for (let i = 0; i < 40; i++) {
		try {
			const res = await fetch(`http://127.0.0.1:${port}/json/list`);
			const list = await res.json();
			const pages = list.filter((t) => t.type === "page" && t.webSocketDebuggerUrl);
			if (pages.length) {
				return (hint && pages.find((t) => t.url.includes(hint))) || pages[0];
			}
		} catch {
			/* 浏览器还没起来，继续等 */
		}
		await sleep(500);
	}
	throw new Error(`连不上 Chrome 调试端口 ${port}，确认 Chrome 已带 --remote-debugging-port 启动`);
}

export class CDP {
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

/** 连上调试端口，返回 { cdp, target, close }。 */
export async function connect(port = 9222) {
	const target = await findPageTarget(port);
	const ws = new WebSocket(target.webSocketDebuggerUrl);
	await new Promise((resolve, reject) => {
		ws.addEventListener("open", resolve, { once: true });
		ws.addEventListener("error", () => reject(new Error("CDP WebSocket 连接失败")), { once: true });
	});
	const cdp = new CDP(ws);
	return { cdp, target, close: () => ws.close() };
}
