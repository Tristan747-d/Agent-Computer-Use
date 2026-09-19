import { readFile, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Host half of the Computer Use sidebar panel.
 *
 * Serves two read-only routes under `/api/computer-use/`:
 *   GET state        — the live state dsh-cua publishes
 *   GET viewport.png — the most recent window frame
 *
 * Deliberately dependency-free and defensive: a missing or malformed state
 * file degrades to `{ connected: false }` rather than breaking the mount, so
 * the panel can always render *something* (including "not running").
 */

export const name = "computer-use-panel";

const STATE_DIR = join(homedir(), ".dsh-cua");
const SHOT_PATH = join(STATE_DIR, "viewport.png");

/** Treat a publisher as gone once its heartbeat is this old. */
const STALE_MS = 15000;

const EMPTY = Object.freeze({
	connected: false,
	busy: false,
	accessibility: false,
	screenRecording: false,
	app: null,
	window: null,
	elementCount: null,
	recentActions: [],
	screenshotUrl: null,
	updatedAt: 0,
});

/**
 * Read every `<pid>.json` and return the freshest one.
 *
 * DSH holds one long-lived MCP child but also spawns short-lived ones (profile
 * probes, tests). Each publisher owns its own document, so a dying session can
 * never stamp `connected: false` over a live sibling; picking the newest
 * heartbeat is what makes concurrent sessions compose.
 */
async function readState() {
	let names;
	try {
		names = await readdir(STATE_DIR);
	} catch {
		return { ...EMPTY };
	}

	const candidates = [];
	for (const name of names) {
		if (!name.endsWith(".json")) continue;
		try {
			const doc = JSON.parse(await readFile(join(STATE_DIR, name), "utf8"));
			if (doc && typeof doc === "object") candidates.push(doc);
		} catch {
			// A half-written or corrupt document never blocks the others.
		}
	}
	if (candidates.length === 0) return { ...EMPTY };

	candidates.sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0));
	const best = candidates[0];

	// A process killed without cleanup never writes `connected: false`, so
	// staleness is what actually detects a dead publisher.
	if (best.connected === true && Date.now() - (best.updatedAt ?? 0) > STALE_MS) {
		best.connected = false;
	}
	return { ...EMPTY, ...best };
}

function sendJson(res, body) {
	const payload = JSON.stringify(body);
	res.writeHead(200, {
		"content-type": "application/json; charset=utf-8",
		"cache-control": "no-store",
		"content-length": Buffer.byteLength(payload),
	});
	res.end(payload);
}

function notFound(res) {
	res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
	res.end("not found");
}

/**
 * Register the routes on the harness webserver.
 * @param ctx - the plugin context carrying `ctx.webServer`.
 */
export function apply(ctx) {
	ctx.effect(
		() =>
			ctx.webServer.register({
				kind: "exact",
				path: "/api/computer-use/state",
				handler: async (req, res) => {
					if (req.method !== "GET" && req.method !== "HEAD") return notFound(res);
					sendJson(res, await readState());
				},
			}),
		"computer-use-panel: state route"
	);

	ctx.effect(
		() =>
			ctx.webServer.register({
				kind: "exact",
				path: "/api/computer-use/viewport.png",
				handler: async (req, res) => {
					if (req.method !== "GET" && req.method !== "HEAD") return notFound(res);
					let png;
					try {
						png = await readFile(SHOT_PATH);
					} catch {
						return notFound(res);
					}
					res.writeHead(200, {
						"content-type": "image/png",
						"cache-control": "no-store",
						"content-length": png.byteLength,
					});
					res.end(req.method === "HEAD" ? undefined : png);
				},
			}),
		"computer-use-panel: viewport route"
	);
}

export const inject = ["webServer"];
