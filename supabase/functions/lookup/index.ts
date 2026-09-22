// RaskBud "lookup": søk etter spill med bilder, og slå opp strekkoder.
//
//   GET ?q=zelda          -> { items: [ { name, platform, image, year, kind, source } ] }
//   GET ?upc=0045496590741 -> { item: { name, platform, image, kind, source } | null }
//
// Nøklene ligger som hemmeligheter i Supabase (aldri i nettsiden):
//   TGDB_KEY  = API-nøkkel fra TheGamesDB (valgfri)
//   RAWG_KEY  = API-nøkkel fra RAWG (valgfri, brukes hvis TheGamesDB ikke gir treff)
// Strekkoder slås opp gratis hos UPCitemdb (100 per dag) og lagres i tabellen
// "barcodes", så samme kode aldri slås opp to ganger.

import { createClient } from "npm:@supabase/supabase-js@2";

const TGDB = Deno.env.get("TGDB_KEY") ?? "";
const RAWG = Deno.env.get("RAWG_KEY") ?? "";
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "public, max-age=600" } });

type Item = { name: string; platform: string; image: string | null; year?: string; kind: "game" | "console" | "accessory"; source: string };
const DAY = 86_400_000;

// ---------- cache i databasen (sparer de gratis kvotene) ----------
async function cached<T>(key: string, days: number, fetcher: () => Promise<T | undefined>): Promise<T | undefined> {
  const { data } = await db.from("lookup_cache").select("value, created_at").eq("key", key).maybeSingle();
  if (data && Date.now() - Date.parse(data.created_at) < days * DAY) return data.value as T;
  const value = await fetcher();
  if (value !== undefined) await db.from("lookup_cache").upsert({ key, value, created_at: new Date().toISOString() });
  return value ?? (data?.value as T | undefined); // ved feil: bruk gammelt svar hvis vi har et
}

async function getJSON(url: string) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch(url, { signal: ctl.signal, headers: { "User-Agent": "RaskBud/1.0" } });
    if (!r.ok) throw new Error(`${r.status} ${url.split("?")[0]}`);
    return await r.json();
  } finally { clearTimeout(t); }
}

// ---------- konsollnavn gjøres like overalt ----------
const PLATFORMS: [RegExp, string][] = [
  [/switch 2/, "Switch 2"], [/switch/, "Switch"],
  [/playstation 5|\bps5\b/, "PS5"], [/playstation 4|\bps4\b/, "PS4"], [/playstation 3|\bps3\b/, "PS3"], [/playstation 2|\bps2\b/, "PS2"],
  [/vita/, "PS Vita"], [/\bpsp\b|playstation portable/, "PSP"], [/playstation|\bpsx\b|\bps1\b/, "PS1"],
  [/xbox series/, "Xbox Series"], [/xbox one/, "Xbox One"], [/xbox 360/, "Xbox 360"], [/xbox/, "Xbox"],
  [/gamecube/, "GameCube"], [/wii u/, "Wii U"], [/\bwii\b/, "Wii"], [/nintendo 64|\bn64\b/, "N64"],
  [/3ds/, "3DS"], [/nintendo ds|\bds\b/, "DS"], [/game ?boy advance|\bgba\b/, "GBA"], [/game ?boy colou?r|\bgbc\b/, "GBC"], [/game ?boy/, "Game Boy"],
  [/super nintendo|\bsnes\b/, "SNES"], [/nintendo entertainment system|\bnes\b/, "NES"],
  [/genesis|mega drive/, "Mega Drive"], [/dreamcast/, "Dreamcast"], [/saturn/, "Saturn"], [/master system/, "Master System"],
  [/^pc$|windows|\bpc\b/, "PC"],
];
const shortPlatform = (n = "") => { const s = n.toLowerCase(); for (const [r, v] of PLATFORMS) if (r.test(s)) return v; return n; };

// ---------- søk: TheGamesDB (boks-bilder) ----------
async function tgdbPlatformNames(): Promise<Record<string, string>> {
  return (await cached("tgdb:platforms", 30, async () => {
    const d = await getJSON(`https://api.thegamesdb.net/v1/Platforms?apikey=${TGDB}`);
    const list = Object.values(d?.data?.platforms ?? {}) as { id: number; name: string }[];
    return Object.fromEntries(list.map((p) => [String(p.id), p.name]));
  })) ?? {};
}
async function searchTGDB(q: string): Promise<Item[]> {
  const url = `https://api.thegamesdb.net/v1/Games/ByGameName?${new URLSearchParams({ apikey: TGDB, name: q, include: "boxart" })}`;
  const d = await getJSON(url);
  const games = (d?.data?.games ?? []) as { id: number; game_title: string; platform: number; release_date?: string }[];
  const box = d?.include?.boxart ?? {};
  const base: string = box?.base_url?.medium ?? box?.base_url?.original ?? "https://cdn.thegamesdb.net/images/medium/";
  const names = await tgdbPlatformNames();
  return games.slice(0, 12).map((g) => {
    const arts = (box?.data?.[g.id] ?? box?.data?.[String(g.id)] ?? []) as { side?: string; filename: string }[];
    const front = arts.find((a) => a.side === "front") ?? arts[0];
    return { name: g.game_title, platform: shortPlatform(names[String(g.platform)] ?? ""), image: front ? base + front.filename : null, year: (g.release_date ?? "").slice(0, 4), kind: "game", source: "TheGamesDB" };
  });
}

// ---------- søk: RAWG (reserve) ----------
async function searchRAWG(q: string): Promise<Item[]> {
  const d = await getJSON(`https://api.rawg.io/api/games?${new URLSearchParams({ key: RAWG, search: q, page_size: "10" })}`);
  return ((d?.results ?? []) as any[]).map((g) => {
    const ps = [...new Set(((g.platforms ?? []) as any[]).map((p) => shortPlatform(p?.platform?.name)).filter(Boolean))];
    return { name: g.name, platform: ps.length === 1 ? ps[0] : "", image: g.background_image ?? null, year: (g.released ?? "").slice(0, 4), kind: "game", source: "RAWG" };
  });
}

async function search(qRaw: string) {
  const q = qRaw.trim().toLowerCase().replace(/\s+/g, " ").slice(0, 60);
  if (q.length < 3) return [];
  // 1) ting du selv har lært opp via strekkoder
  const { data: learned } = await db.from("barcodes").select("item").ilike("item->>name", `%${q}%`).limit(5);
  const own: Item[] = (learned ?? []).map((r: any) => ({ ...r.item, source: "RaskBud" }));
  // 2) spilldatabasene (svar lagres i 14 dager)
  const ext = await cached<Item[]>(`q:${q}`, 14, async () => {
    let ok = false, items: Item[] = [];
    if (TGDB) { try { items = await searchTGDB(q); ok = true; } catch (e) { console.error("TGDB", e); } }
    if (!items.length && RAWG) { try { items = await searchRAWG(q); ok = true; } catch (e) { console.error("RAWG", e); } }
    return ok ? items : undefined; // lagre ikke feil
  }) ?? [];
  const seen = new Set<string>();
  return [...own, ...ext].filter((i) => { const k = `${i.name}|${i.platform}`.toLowerCase(); if (seen.has(k)) return false; seen.add(k); return true; });
}

// ---------- strekkode ----------
function cleanTitle(t = "") {
  return t
    .replace(/\s*[-–|(\[]\s*(for\s+)?(nintendo|sony|playstation|ps\d|xbox|microsoft|switch|wii|gamecube|3ds|ds|pal|ntsc|standard|brand new|new|sealed|video ?game)[^)\]]*[)\]]?\s*$/i, "")
    .replace(/\s{2,}/g, " ").trim();
}
async function byBarcode(code: string) {
  const { data: known } = await db.from("barcodes").select("item, source").eq("code", code).maybeSingle();
  if (known) return { ...known.item, source: known.source };

  const d = await cached<any>(`upc:${code}`, 60, async () => {
    const r = await fetch(`https://api.upcitemdb.com/prod/trial/lookup?upc=${code}`, { headers: { Accept: "application/json" } });
    if (r.status === 429) return undefined; // dagskvoten er brukt opp: ikke lagre, prøv i morgen
    return await r.json();
  });
  const it = d?.items?.[0];
  if (!it?.title) return null;
  const text = `${it.title} ${it.category ?? ""}`;
  const item: Item = {
    name: cleanTitle(it.title),
    platform: shortPlatform(text),
    image: (it.images ?? [])[0] ?? null,
    kind: /console|system|konsoll/i.test(text) && !/game\b/i.test(it.category ?? "") ? "console" : /controller|kontroll|adapter|cable/i.test(text) ? "accessory" : "game",
    source: "UPCitemdb",
  };
  // bedre bilde: boks-bilde fra TheGamesDB hvis vi finner samme spill
  if (TGDB && item.kind === "game") {
    try { const hit = (await search(item.name)).find((x) => x.image && (!item.platform || x.platform === item.platform)); if (hit) item.image = hit.image; } catch { /* beholder UPCitemdb-bildet */ }
  }
  await db.from("barcodes").upsert({ code, item, source: "UPCitemdb" });
  return item;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  try {
    const upc = (url.searchParams.get("upc") ?? "").replace(/\D/g, "");
    if (upc) {
      if (!/^(\d{8}|\d{12,14})$/.test(upc)) return json({ error: "Ugyldig strekkode" }, 400);
      const code = upc.length === 12 ? "0" + upc : upc;
      return json({ item: await byBarcode(code) });
    }
    const q = url.searchParams.get("q");
    if (q) return json({ items: await search(q) });
    return json({ error: "Bruk ?q= eller ?upc=" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: "Oppslaget feilet" }, 502);
  }
});
