#!/usr/bin/env node
// Reconcile Uptime-Kuma against the stack's declarations: create the missing
// monitors, update the changed ones, and create + publish the status page when
// it does not exist yet. Run inside the kuma-ctl image by
// scripts/kuma-monitors.sh; everything arrives through the environment so no
// secret reaches a command line:
//
//   KUMA_URL            base URL of the server (http://uptime-kuma:3001)
//   KUMA_USERNAME / KUMA_PASSWORD   the admin login (api.env)
//   KUMA_MONITORS_JSON  [{"name","url","codes":[...],"interval","retryInterval","maxretries"}]
//   KUMA_STATUS_JSON    {"slug","title","group"} or empty: create + publish the page
//   KUMA_DRY_RUN / KUMA_PRUNE    the script's flags, as KUMA_DRY_RUN=1 / KUMA_PRUNE=1
//
// Three rules keep a reconcile from fighting the UI:
//   * a monitor is only touched when a *declared* field changed (url, accepted
//     status codes) -- the UI-tuned ones (interval, retries with their drift,
//     notifications it got attached to) are never rewritten;
//   * the status page is created and filled with the declared monitors only
//     while it is empty; a page that already carries monitors belongs to the
//     UI, layout and all;
//   * --prune is the only destructive mode (mirrors scripts/npm-hosts.sh).
import { io } from "socket.io-client";

const BASE_URL = process.env.KUMA_URL || "http://127.0.0.1:3001";
const USERNAME = process.env.KUMA_USERNAME || "";
const PASSWORD = process.env.KUMA_PASSWORD || "";
const MONITORS = JSON.parse(process.env.KUMA_MONITORS_JSON || "[]");
const STATUS = process.env.KUMA_STATUS_JSON ? JSON.parse(process.env.KUMA_STATUS_JSON) : null;
const DRY_RUN = process.env.KUMA_DRY_RUN === "1";
const PRUNE = process.env.KUMA_PRUNE === "1";

process.exitCode = 1;
const fail = (msg) => { console.error(`ERROR ${msg}`); process.exit(1); };
const log = (msg) => { console.log(msg); };

if (!PASSWORD || !USERNAME) fail("KUMA_USERNAME/KUMA_PASSWORD missing");
if (!Array.isArray(MONITORS) || MONITORS.length === 0) fail("KUMA_MONITORS_JSON empty");
for (const d of MONITORS) {
    if (!d?.name || !d?.url) fail(`bad monitor declaration: ${JSON.stringify(d)}`);
    if (typeof d.interval !== "number" || d.interval <= 0) fail(`bad interval for ${d.name}`);
    if (typeof d.maxretries !== "number" || d.maxretries < 0) fail(`bad retries for ${d.name}`);
}

const sock = io(BASE_URL, { transports: ["websocket"], reconnection: false, timeout: 20000, forceNew: true });

// request/response over one ack each. `args` is an ARRAY of the POSITIONAL
// arguments the server handler reads, ack lands after them -- a wrong arity
// sends the callback into a data slot and nothing answers: the client just
// times out its full minute with the server already done. Verified shapes (kuma
// 2.5.x): login({username,password}); add(monitor); editMonitor(monitor);
// deleteMonitor(id[, deleteChildren]); getStatusPage(slug);
// addStatusPage(title, slug); saveStatusPage(slug, config, imgDataUrl,
// publicGroupList).
function call(event, args = [], ms = 60000) {
    return new Promise((resolve, reject) => {
        sock.timeout(ms).emit(event, ...args, (err, res) => {
            if (err) reject(new Error(`${event}: ${err.message || "timeout"}`));
            else resolve(res);
        });
    });
}

// kuma 2.5 registers its socket handlers only after `await sendInfo()` in the
// server's connection handler, so a `login` emitted the instant `connect`
// fires can be dropped -- socket.io queues nothing (see
// news.hearso.com/uptime-kuma-login-race). The server's `info` event is the
// proof that registration happened, so wait for it before sending anything;
// attach the listener first, the event can race the connect ack on the wire.
const infoReceived = new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("the server never sent its `info` event (kuma did not finish registering its handlers); is this uptime-kuma v2?")), 20000);
    sock.on("info", () => { clearTimeout(t); resolve(); });
});
await new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("could not connect to " + BASE_URL)), 20000);
    sock.on("connect_error", (e) => { clearTimeout(t); reject(new Error(`connect failed: ${e.message}`)); });
    sock.on("connect", () => { clearTimeout(t); resolve(); });
});
await infoReceived;

// The `monitorList` push lands once after login; wait up to 15s for it. The
// persistent listener kicks in even if it arrives between the login ack and
// this wait; an *empty* list still counts as arrived -- a fresh instance has
// no monitors, and the server will never push another one.
// The `monitorList` push lands once after login; wait up to 15s for it. The
// persistent listener kicks in even if it arrives between the login ack and
// this wait; an *empty* list still counts as arrived -- a fresh instance has
// no monitors, and the server will never push another one.
let monitorList = null;
sock.on("monitorList", (list) => { monitorList = list ?? {}; });

// Two attempts: the info-wait above is the primary defense, but a future
// kuma moving its `await` could drop a login again. A dropped login times
// out instead of erroring, so a short retry is safe and cheap.
let login = null;
for (let attempt = 1; attempt <= 2; attempt++) {
    try {
        login = await call("login", [{ username: USERNAME, password: PASSWORD }], 20000);
        break;
    } catch (e) {
        if (attempt === 2 || !/timeout/i.test(String(e.message))) throw e;
        log(`login attempt ${attempt} timed out (dropped by the server, see the comment above); retrying`);
        await new Promise((r) => setTimeout(r, 3000));
    }
}
if (!login?.ok) fail(`login failed: ${login?.msg || "no answer from the server"}`);

await new Promise((resolve) => {
    if (monitorList) return resolve();
    const t = setTimeout(resolve, 15000);
    sock.once("monitorList", () => { clearTimeout(t); resolve(); });
});

const byName = new Map(Object.values(monitorList ?? {}).map((m) => [m.name, m]));
const declaredNames = new Set(MONITORS.map((m) => m.name));
const resolvedIds = []; // per declared monitor, in order; status page members

function normalizedCodes(m) {
    // The list push carries accepted_statuscodes as an array (the DB's _json
    // string only exists on older payloads).
    const codes = Array.isArray(m?.accepted_statuscodes) && m.accepted_statuscodes.length > 0
        ? m.accepted_statuscodes
        : (() => { try { return JSON.parse(m?.accepted_statuscodes_json ?? "[]"); } catch { return []; } })();
    return JSON.stringify([...codes].sort());
}

// Decode a DB JSON string into the raw array/objects the server-side handlers
// stringify back; arrays pass through, anything unrecoverable becomes [].
function rawArray(val) {
    if (Array.isArray(val)) return val;
    if (typeof val === "string") {
        try { return JSON.parse(val); } catch { /* empty */ }
    }
    return [];
}

// Declared fields only: url + accepted status codes. Interval and retries are
// deliberately ignored -- those belong to the UI once the monitor exists.
function differs(existing, d) {
    return (existing.url ?? "") !== d.url
        || normalizedCodes(existing) !== JSON.stringify([...d.codes].sort());
}

for (const d of MONITORS) {
    const existing = byName.get(d.name);
    if (!existing) {
        if (DRY_RUN) { log(`[dry-run] would create monitor "${d.name}" (${d.url}, codes ${d.codes.join(",")})`); continue; }
        const res = await call("add", [{
            name: d.name,
            type: "http",
            method: "GET",
            url: d.url,
            interval: d.interval,
            retryInterval: d.retryInterval,
            maxretries: d.maxretries,
            resendInterval: 0,
            // The add handler consumes accepted_statuscodes as the *array*
            // (it builds and stores the _json string itself), and it
            // JSON.stringifies conditions, kafkaProducerBrokers,
            // kafkaProducerSaslOptions and rabbitmqNodes directly -- so those
            // must arrive as raw arrays/objects. Sending the _json string for
            // the codes (or omitting these) crashes the handler server-side
            // ("Cannot read properties of undefined (reading 'every')").
            accepted_statuscodes: d.codes,
            notificationIDList: {},
            conditions: [],
            kafkaProducerBrokers: [],
            kafkaProducerSaslOptions: [],
            rabbitmqNodes: [],
            active: true,
        }]);
        if (!res?.monitorID) fail(`could not create monitor "${d.name}": ${res?.msg || "no monitorID"}`);
        log(`created monitor "${d.name}" (id ${res.monitorID}, ${d.url}, codes ${d.codes.join(",")})`);
        resolvedIds.push(res.monitorID);
        continue;
    }
    if (differs(existing, d)) {
        if (DRY_RUN) { log(`[dry-run] would update monitor "${d.name}" (id ${existing.id})`); continue; }
        // Spread what exists, override the declared fields: the UI's settings
        // (interval, notifications, ...) are carried over untouched. The list
        // push's object is already in the shape the edit handler reads
        // (accepted_statuscodes as an array; conditions, kafka and rabbitmq
        // parsed back from their DB strings) -- only anything that still
        // arrives as a string has to be decoded, because the handler
        // JSON.stringifies those four itself and a string in means a
        // double-encoded string in the database.
        const { accepted_statuscodes_json: _json, ...carry } = existing;
        const res = await call("editMonitor", [{
            ...carry,
            url: d.url,
            accepted_statuscodes: d.codes,
            conditions: rawArray(carry.conditions),
            kafkaProducerBrokers: rawArray(carry.kafkaProducerBrokers),
            kafkaProducerSaslOptions: rawArray(carry.kafkaProducerSaslOptions),
            rabbitmqNodes: rawArray(carry.rabbitmqNodes),
        }]);
        if (!res?.ok) fail(`could not update monitor "${d.name}": ${res?.msg || "no ok"}`);
        log(`updated monitor "${d.name}" (id ${existing.id})`);
    } else {
        log(`monitor "${d.name}" unchanged (id ${existing.id})`);
    }
    resolvedIds.push(existing.id);
}

if (PRUNE) {
    const stale = Object.values(monitorList).filter((m) => !declaredNames.has(m.name));
    if (stale.length === 0) log("nothing to prune");
    for (const m of stale) {
        if (DRY_RUN) { log(`[dry-run] would delete monitor "${m.name}" (id ${m.id})`); continue; }
        const res = await call("deleteMonitor", [m.id]);
        if (!res?.ok) fail(`could not delete monitor "${m.name}" (id ${m.id}): ${res?.msg || "no ok"}`);
        log(`deleted monitor "${m.name}" (id ${m.id}, not declared)`);
    }
}

// The status page: created + filled only while it is empty -- a page that
// already carries monitors belongs to the UI, layout and all. Existence is
// checked through the authenticated `getStatusPage` event: kuma v2's public
// routes answer for any slug that exists, `published` or not, so a REST probe
// says nothing about what the page is.
if (STATUS?.slug && STATUS?.title) {
    const existingPage = await call("getStatusPage", [STATUS.slug], 30000);
    const pageExists = existingPage?.ok === true;

    // What a visitor would see, straight from the public data endpoint; the
    // reconcile only fills a page with *nothing* on it, so unknown content
    // counts as content (leave it alone).
    let hasMonitors = false;
    let contentKnown = false;
    if (pageExists && !DRY_RUN) {
        try {
            const probe = await fetch(`${BASE_URL}/api/status-page/${encodeURIComponent(STATUS.slug)}`);
            if (probe.ok) {
                const body = await probe.json();
                const publicMonitors = (body?.publicGroupList ?? []).reduce(
                    (n, g) => n + (g.monitorList?.length ?? 0), 0);
                hasMonitors = publicMonitors > 0;
                contentKnown = true;
            }
        } catch { /* content stays unknown */ }
    }

    if (pageExists && (!contentKnown || hasMonitors)) {
        log(`status page '${STATUS.slug}' exists and carries monitors; the layout stays with the UI`);
    } else if (DRY_RUN) {
        if (pageExists) {
            log(`[dry-run] would fill the (empty) status page '${STATUS.slug}' with ${resolvedIds.length} monitor(s)`);
        } else {
            log(`[dry-run] would create + publish status page '${STATUS.slug}' with ${resolvedIds.length} monitor(s)`);
        }
    } else {
        if (!pageExists) {
            // Two positional args. One object would land in `title` and put
            // the *ack callback* into `slug`'s slot: the handler throws on
            // title.trim (logged server-side, nothing sent back), and the
            // client waits out its full timeout -- this run took three
            // monitor-adding runs before a probe nailed the mechanism.
            const created = await call("addStatusPage", [STATUS.title, STATUS.slug], 30000);
            if (!created?.ok && !/unique|duplicate|exist/i.test(String(created?.msg ?? ""))) {
                fail(`could not create status page '${STATUS.slug}': ${created?.msg || "no ok"}`);
            }
            if (created?.ok) {
                log(`created status page '${STATUS.slug}'`);
            } else {
                log(`status page '${STATUS.slug}' exists (created between the check and here); continuing`);
            }
        }
        // The save payload: start from what the server stored (a fresh page's
        // defaults are its own), override only title + description, and keep
        // its icon. imgDataUrl must be a string -- the handler calls
        // imgDataUrl.startsWith() on it and null throws.
        const statusPage = await call("getStatusPage", [STATUS.slug], 30000);
        const cfg = {
            ...(statusPage?.config ?? {}),
            description: statusPage?.config?.description ?? "",
            title: STATUS.title,
            slug: STATUS.slug,
            published: true,
        };
        const groupList = resolvedIds.length > 0 ? [{
            name: STATUS.group || "Public services",
            weight: 0,
            monitorList: resolvedIds.map((id) => ({ id, weight: 1 })),
        }] : [];
        // saveStatusPage(slug, config, imgDataUrl, publicGroupList) -- four
        // positional args, empty logo string, groups as an array.
        const saved = await call("saveStatusPage", [STATUS.slug, cfg, String(statusPage?.config?.icon ?? ""), groupList], 30000);
        if (!saved?.ok) fail(`could not publish status page '${STATUS.slug}': ${saved?.msg || "no ok"}`);
        log(`published status page '${STATUS.slug}' (${resolvedIds.length} monitor(s))`);
    }
}

sock.close();
process.exitCode = 0;
