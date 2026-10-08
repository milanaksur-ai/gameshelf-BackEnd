// api/cron-gamepass.js — catalogue Game Pass, mis à jour 1×/jour (voir vercel.json).
// Remplace le workflow GitHub Actions, dont la planification ne se déclenchait
// plus depuis juillet. Le résultat est stocké dans Supabase (table
// gamepass_catalog, une seule ligne) et servi à l'app par /api/gamepass.
import { sbFetch } from './push.js';

const SIGLS = [
  'fdd9e2a7-0fee-49f6-ad69-4354098401ff',
  'b8900d09-a491-44cc-916e-32b5acae621b',
];
// État initial si la table est vide : le dernier catalogue publié par l'ancien workflow
const LEGACY_URL = 'https://gameshelf-seven.vercel.app/gamepass.json';

async function getJson(url) {
  const r = await fetch(url, { headers: { 'User-Agent': 'GameShelf-bot/1.0' } });
  if (!r.ok) throw new Error(`${url} → ${r.status}`);
  return r.json();
}

function cleanTitle(raw) {
  return raw
    .replace(/\s*[\(\[](?:Game Preview|Windows PC|Windows|PC|Xbox Series X\/S|Xbox One)[)\]]/gi, '')
    .replace(/\s*-\s*(?:Windows|PC|Digital Standard Edition|Standard Edition|Digital Edition).*/i, '')
    .replace(/[™®©]/g, '')
    .trim();
}

export async function buildCatalog(previous) {
  const lists = await Promise.all(SIGLS.map(id =>
    getJson(`https://catalog.gamepass.com/sigls/v2?id=${id}&language=en-US&market=US`)));
  const seen = new Set(); const ids = [];
  for (const item of lists.flatMap(l => l.slice(1))) {
    if (item.id && !seen.has(item.id)) { seen.add(item.id); ids.push(item.id); }
  }

  const byId = {};
  for (let i = 0; i < ids.length; i += 20) {
    const data = await getJson(
      `https://displaycatalog.mp.microsoft.com/v7.0/products?bigIds=${ids.slice(i, i + 20).join(',')}&market=US&languages=en-US`);
    for (const prod of data.Products || []) {
      const loc = prod.LocalizedProperties?.[0];
      if (!loc?.ProductTitle) continue;
      const imgObj = loc.Images?.find(im => ['BoxArt', 'Poster'].includes(im.ImagePurpose));
      const img = imgObj?.Uri ? (imgObj.Uri.startsWith('//') ? 'https:' + imgObj.Uri : imgObj.Uri) : null;
      byId[prod.ProductId] = {
        title: cleanTitle(loc.ProductTitle), img, id: prod.ProductId,
        releaseDate: prod.MarketProperties?.[0]?.OriginalReleaseDate || null,
      };
    }
  }

  // Tri par date de sortie décroissante (9998 = « pas de date » chez Microsoft → en dernier)
  const dateOf = g => (g.releaseDate && !g.releaseDate.startsWith('9998')) ? new Date(g.releaseDate) : new Date(0);
  const games = ids.map(id => byId[id]).filter(Boolean).sort((a, b) => dateOf(b) - dateOf(a));
  if (games.length < 50) throw new Error(`Catalogue anormalement court (${games.length} jeux) — ancien état conservé`);

  // Nouveautés = présents maintenant, absents du catalogue précédent ; fenêtre glissante de 30
  const prevIds = new Set((previous?.games || []).map(g => g.id));
  const fresh = previous?.games?.length ? games.filter(g => !prevIds.has(g.id)) : [];
  const freshIds = new Set(fresh.map(g => g.id));
  const carried = (previous?.newGames || []).filter(g => !freshIds.has(g.id) && byId[g.id]).slice(0, 30 - fresh.length);
  let newGames = [...fresh, ...carried].slice(0, 30);
  if (newGames.length < 15) {
    const have = new Set(newGames.map(g => g.id));
    newGames = [...newGames, ...games.filter(g => !have.has(g.id)).slice(0, 30 - newGames.length)];
  }
  return { games, newGames, freshCount: fresh.length };
}

export default async function handler(req, res) {
  // Refus par défaut : sans secret configuré, la tâche n'est pas exposée
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    const rows = await sbFetch('gamepass_catalog?id=eq.1&select=games,new_games');
    let previous = rows?.[0] ? { games: rows[0].games, newGames: rows[0].new_games } : null;
    if (!previous) { try { previous = await getJson(LEGACY_URL); } catch (e) { previous = null; } }

    const { games, newGames, freshCount } = await buildCatalog(previous);
    await sbFetch('gamepass_catalog?on_conflict=id', {
      method: 'POST',
      headers: { Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify({ id: 1, games, new_games: newGames, updated_at: new Date().toISOString() }),
    });
    return res.status(200).json({ games: games.length, fresh: freshCount, newGames: newGames.length });
  } catch (e) {
    console.error('cron-gamepass error', e);
    return res.status(500).json({ error: e.message });
  }
}
