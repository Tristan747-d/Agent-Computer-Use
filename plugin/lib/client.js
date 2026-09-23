window.__ModuleLoader__.load({
	id: "dsh-computer-use-panel",
	factory: (require) => {
		var module = { exports: {} };
		var exports = module.exports;
		Object.defineProperty(exports, Symbol.toStringTag, { value: "Module" });

		const react = require("react");
		const jsxRuntime = require("react/jsx-runtime");
		const h = jsxRuntime.jsx;
		const jsxs = jsxRuntime.jsxs;
		const Fragment = jsxRuntime.Fragment;

		// ── styles ────────────────────────────────────────────────────────────
		// Injected at materialization (inside the factory), never at script
		// execution — the module loader's lazy-CJS contract.
		const CSS = `
.cua-root{display:flex;flex-direction:column;height:100%;min-height:0;background:var(--dsw-alias-bg-base,#fff);color:var(--dsw-alias-text-primary,#111);font-size:13px}
.cua-head{display:flex;align-items:center;gap:8px;padding:10px 12px;border-bottom:1px solid var(--dsw-alias-border-secondary,rgba(0,0,0,.08));flex:0 0 auto}
.cua-dot{width:8px;height:8px;border-radius:999px;background:#9aa0a6;flex:0 0 auto}
.cua-dot[data-live="true"]{background:#1aa260;box-shadow:0 0 0 3px rgba(26,162,96,.18);animation:cua-pulse 1.6s ease-in-out infinite}
.cua-dot[data-err="true"]{background:#d93025;box-shadow:0 0 0 3px rgba(217,48,37,.18)}
@keyframes cua-pulse{0%,100%{opacity:1}50%{opacity:.45}}
.cua-title{font-weight:600;flex:1 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.cua-sub{color:var(--dsw-alias-text-secondary,#666);font-size:12px}
.cua-btn{border:1px solid var(--dsw-alias-border-secondary,rgba(0,0,0,.14));background:transparent;color:inherit;border-radius:6px;padding:3px 8px;font-size:12px;cursor:pointer;line-height:18px}
.cua-btn:hover{background:var(--dsw-alias-bg-secondary,rgba(0,0,0,.04))}
.cua-btn:disabled{opacity:.45;cursor:default}
.cua-stage{position:relative;flex:1 1 auto;min-height:0;display:flex;align-items:center;justify-content:center;background:#0f1117;overflow:hidden}
.cua-shot{max-width:100%;max-height:100%;object-fit:contain;display:block}
.cua-empty{color:#9aa0a6;font-size:12px;text-align:center;padding:24px;line-height:1.6}
.cua-badge{position:absolute;top:8px;left:8px;background:rgba(0,0,0,.62);color:#fff;border-radius:6px;padding:2px 7px;font-size:11px;font-variant-numeric:tabular-nums;backdrop-filter:blur(6px)}
.cua-foot{flex:0 0 auto;border-top:1px solid var(--dsw-alias-border-secondary,rgba(0,0,0,.08));padding:8px 12px;display:flex;flex-direction:column;gap:6px}
.cua-row{display:flex;align-items:center;gap:8px;justify-content:space-between}
.cua-kv{color:var(--dsw-alias-text-secondary,#666);font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.cua-warn{color:#b06000;font-size:12px;line-height:1.5}
.cua-log{max-height:170px;overflow:auto;display:flex;flex-direction:column;gap:2px;margin-top:2px}
.cua-li{display:flex;gap:8px;font-size:12px;line-height:1.5;font-variant-numeric:tabular-nums}
.cua-li time{color:var(--dsw-alias-text-secondary,#888);flex:0 0 auto}
.cua-li span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
`;

		const TAG_ID = "dsh-computer-use-panel/viewport.css";
		if (typeof document !== "undefined" &&
			document.querySelector('style[data-plugin-css=' + JSON.stringify(TAG_ID) + ']') === null) {
			const tag = document.createElement("style");
			tag.dataset.plugin = "dsh-computer-use-panel";
			tag.dataset.pluginCss = TAG_ID;
			tag.textContent = CSS;
			document.head.appendChild(tag);
		}

		// ── dictionaries ──────────────────────────────────────────────────────
		const zh = {
			"panel.title": "Computer Use",
			"state.live": "运行中",
			"state.idle": "空闲",
			"state.offline": "未连接",
			"state.denied": "缺少辅助功能权限",
			"act.refresh": "刷新",
			"act.autoOn": "暂停实时",
			"act.autoOff": "开启实时",
			"empty.title": "Computer Use 待命中",
			"empty.hint": "模型操作本机 app 时，这里会实时显示画面与动作。",
			"empty.noscreen": "缺少「屏幕录制」权限，无法显示画面。可在 系统设置 → 隐私与安全性 → 屏幕录制 中授权 dsh-cua.app。",
			"badge.live": "实时",
			"kv.app": "目标 app",
			"kv.window": "窗口",
			"kv.elements": "元素",
			"kv.updated": "更新于",
			"log.title": "最近动作",
			"log.empty": "还没有动作记录。",
			"err.fetch": "无法读取状态"
		};
		const en = {
			"panel.title": "Computer Use",
			"state.live": "Active",
			"state.idle": "Idle",
			"state.offline": "Disconnected",
			"state.denied": "Accessibility permission missing",
			"act.refresh": "Refresh",
			"act.autoOn": "Pause live",
			"act.autoOff": "Go live",
			"empty.title": "Computer Use standing by",
			"empty.hint": "When the model operates an app, its screen and actions appear here live.",
			"empty.noscreen": "Screen Recording permission is missing, so no live image is available. Grant it to dsh-cua.app in System Settings → Privacy & Security → Screen Recording.",
			"badge.live": "LIVE",
			"kv.app": "Target app",
			"kv.window": "Window",
			"kv.elements": "Elements",
			"kv.updated": "Updated",
			"log.title": "Recent actions",
			"log.empty": "No actions recorded yet.",
			"err.fetch": "Cannot read state"
		};

		const NS = "computerUse";
		const POLL_MS = 1000;

		// ── helpers ───────────────────────────────────────────────────────────
		function fmtTime(ms) {
			if (!ms) return "—";
			const d = new Date(ms);
			const p = (n) => String(n).padStart(2, "0");
			return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
		}

		function useComputerUseState() {
			const [state, setState] = react.useState(null);
			const [error, setError] = react.useState(null);
			const [auto, setAuto] = react.useState(true);
			const aliveRef = react.useRef(true);

			const load = react.useCallback(async () => {
				try {
					const res = await fetch("/api/computer-use/state", { headers: { accept: "application/json" } });
					if (!res.ok) throw new Error("HTTP " + res.status);
					const data = await res.json();
					if (!aliveRef.current) return;
					setState(data);
					setError(null);
				} catch (e) {
					if (!aliveRef.current) return;
					setError(e instanceof Error ? e.message : String(e));
				}
			}, []);

			react.useEffect(() => {
				aliveRef.current = true;
				load();
				return () => { aliveRef.current = false; };
			}, [load]);

			react.useEffect(() => {
				if (!auto) return undefined;
				const id = setInterval(load, POLL_MS);
				return () => clearInterval(id);
			}, [auto, load]);

			return { state, error, auto, setAuto, reload: load };
		}

		// ── the panel body ────────────────────────────────────────────────────
		function ComputerUsePanel(props) {
			const t = props.t;
			const { state, error, auto, setAuto, reload } = useComputerUseState();

			const connected = Boolean(state && state.connected);
		 const axOK = state ? state.accessibility === true : false;
			const screenOK = state ? state.screenRecording === true : false;
			const live = connected && axOK;
			const busy = Boolean(state && state.busy);

			const dotState = !connected ? "off" : !axOK ? "denied" : busy ? "live" : "idle";
			const statusText =
				!connected ? t("state.offline")
					: !axOK ? t("state.denied")
						: busy ? t("state.live")
							: t("state.idle");

			const shot = state && state.screenshotUrl ? state.screenshotUrl : null;
			// Prefer the live MJPEG stream when the agent has started one: it is a
			// continuous multipart/x-mixed-replace response, which an <img> renders
			// natively with no decoder and no polling. The still is the fallback for
			// when Screen Recording is granted but no live session is running.
			const liveStream = state && state.streamUrl ? state.streamUrl : null;
			const frame = state && state.window
				? `${state.window.width}×${state.window.height}`
				: null;
			const actions = (state && Array.isArray(state.recentActions)) ? state.recentActions : [];

			return jsxs("div", {
				className: "cua-root",
				children: [
					// header
					jsxs("div", {
						className: "cua-head",
						children: [
							h("span", {
								className: "cua-dot",
								"data-live": String(dotState === "live"),
								"data-err": String(dotState === "denied"),
								"aria-hidden": true
							}),
							jsxs("div", {
								style: { flex: "1 1 auto", minWidth: 0 },
								children: [
									h("div", { className: "cua-title", children: t("panel.title") }),
									h("div", { className: "cua-sub", children: statusText })
								]
							}),
							h("button", {
								type: "button",
								className: "cua-btn",
								onClick: () => setAuto(!auto),
								title: auto ? t("act.autoOn") : t("act.autoOff"),
								children: auto ? t("act.autoOn") : t("act.autoOff")
							}),
							h("button", {
								type: "button",
								className: "cua-btn",
								onClick: reload,
								children: t("act.refresh")
							})
						]
					}),

					// stage: the live image (MJPEG stream when running, else a still)
					h("div", {
						className: "cua-stage",
						children: (liveStream || shot)
							? jsxs(Fragment, {
								children: [
									h("img", {
										className: "cua-shot",
										// `src` is only swapped when the target changes;
										// re-assigning the same MJPEG URL would restart
										// the connection on every poll.
										src: liveStream || shot,
										alt: (state && state.app) || "Computer Use viewport"
									}),
									live && h("div", {
										className: "cua-badge",
										style: { left: 8, right: "auto" },
										children: t("badge.live")
									}),
									frame !== null && h("div", { className: "cua-badge", children: frame })
								]
							})
							: h("div", {
								className: "cua-empty",
								children: !screenOK
									? t("empty.noscreen")
									: jsxs(Fragment, {
										children: [
											h("div", { style: { fontWeight: 600, marginBottom: 4 }, children: t("empty.title") }),
											h("div", { children: t("empty.hint") })
										]
									})
							})
					}),

					// footer: metadata + action log
					jsxs("div", {
						className: "cua-foot",
						children: [
							jsxs("div", {
								className: "cua-row",
								children: [
									h("span", { className: "cua-kv", children: t("kv.app") + ": " + ((state && state.app) || "—") }),
									h("span", { className: "cua-kv", children: t("kv.elements") + ": " + ((state && state.elementCount) ?? "—") })
								]
							}),
							jsxs("div", {
								className: "cua-row",
								children: [
									h("span", { className: "cua-kv", children: t("kv.window") + ": " + (frame || "—") }),
									h("span", { className: "cua-kv", children: t("kv.updated") + ": " + fmtTime(state && state.updatedAt) })
								]
							}),
							!connected && error
								? h("div", { className: "cua-warn", children: t("err.fetch") + " (" + error + ")" })
								: null,
							jsxs("div", {
								children: [
									h("div", { className: "cua-kv", style: { marginTop: 2 }, children: t("log.title") }),
									actions.length === 0
										? h("div", { className: "cua-kv", children: t("log.empty") })
										: h("div", {
											className: "cua-log",
											children: actions.slice(0, 40).map((a, i) =>
												jsxs("div", {
													className: "cua-li",
													children: [
														h("time", { children: fmtTime(a.at) }),
														h("span", { title: a.text, children: a.text })
													]
												}, String(a.at) + "-" + i)
											)
										})
								]
							})
						]
					})
				]
			});
		}

		// ── sidebar entry icon ────────────────────────────────────────────────
		function ComputerUseIcon(props) {
			const size = props && props.size ? props.size : 16;
			return h("svg", {
				width: size, height: size, viewBox: "0 0 16 16", fill: "none",
				"aria-hidden": true, focusable: false,
				children: [
					h("rect", {
						x: 1.5, y: 2.5, width: 13, height: 9, rx: 1.6,
						stroke: "currentColor", strokeWidth: 1.3
					}),
					h("path", {
						d: "M5.5 14h5", stroke: "currentColor", strokeWidth: 1.3, strokeLinecap: "round"
					}),
					h("path", {
						d: "M8 11.5V14", stroke: "currentColor", strokeWidth: 1.3, strokeLinecap: "round"
					}),
					h("circle", { cx: 8, cy: 7, r: 1.7, fill: "currentColor" })
				]
			});
		}

		// ── plugin body ───────────────────────────────────────────────────────
		const inject = ["slots", "locale"];

		function apply(ctx) {
			ctx.effect(
				() => ctx.locale.register(NS, { zh, en }),
				"computer-use-panel: dictionaries"
			);

			// Thunked copy: read again on every use, so a language change needs
			// no re-registration.
			const translate = ctx.locale.bind(NS);

			// The sidebar entry. Its `id` is also the main-slot key that the
			// row selects, which is how the sidebar resolves where a click goes.
			ctx.effect(
				() => ctx.slots.inject("sidebar.panellist", () =>
					ctx.slots.register({
						name: "sidebar.panellist",
						id: "computer-use",
						order: 50,
						label: () => translate("panel.title"),
						locale: NS,
						inject: () => ({ t: translate })
					}, ComputerUseIcon)
				),
				"computer-use-panel: sidebar entry"
			);

			// The centre panel that entry opens.
			ctx.effect(
				() => ctx.slots.inject("main", () =>
					ctx.slots.register({
						name: "main",
						key: "computer-use",
						locale: NS,
						inject: () => ({ t: translate })
					}, ComputerUsePanel)
				),
				"computer-use-panel: main panel"
			);
		}

		exports.apply = apply;
		exports.inject = inject;
		exports.ComputerUsePanel = ComputerUsePanel;
		exports.ComputerUseIcon = ComputerUseIcon;
		return module.exports;
	}
});
