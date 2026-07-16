// api/cron-wishlist.js — « 👀 [jeu] est sorti ! » : notifie chaque joueur quand
// un jeu de sa liste de souhaits sort. Tourne 1×/jour (voir vercel.json) —
// fenêtre de sortie = dernières 24h, donc chaque sortie ne notifie qu'une fois.
// Protégé par CRON_SECRET, comme cron-weekly.
import { sbFetch, sendToUser } from './push.js';

const CLIENT_ID     = process.env.IGDB_CLIENT_ID;
const CLIENT_SECRET = process.env.IGDB_CLIENT_SECRET;

let tokenCache = { token: null, expires: 0 };
async function getToken() {
  if (tokenCache.token && Date.now() < tokenCache.expires) return tokenCache.token;
  const res = await fetch(
    `https://id.twitch.tv/oauth2/token?client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&grant_type=client_credentials`,
    { method: 'POST' }
  );
  if (!res.ok) throw new Error(`Token error: ${res.status}`);
  const data = await res.json();
  tokenCache = { token: data.access_token, expires: Date.now() + (data.expires_in - 300) * 1000 };
  return tokenCache.token;
}

// game_id côté app : '123' (IGDB numérique) ou 'igdb_123' → id IGDB ; sinon null
function igdbIdOf(gameId) {
  const s = String(gameId || '');
  if (/^\d+$/.test(s)) return Number(s);
  const m = s.match(/^igdb_(\d+)$/);
  return m ? Number(m[1]) : null;
}

export default async function handler(req, res) {
  if (process.env.CRON_SECRET && req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    // 1. Joueurs qui ont des notifications actives
    const subs = await sbFetch('push_subscriptions?select=user_id');
    const userIds = [...new Set((subs || []).map(s => s.user_id))];
    if (!userIds.length) return res.status(200).json({ users: 0, notified: 0 });

    // 2. Leurs jeux en liste de souhaits (title stocké en base → pas de lookup nom)
    const inList = userIds.map(u => `"${u}"`).join(',');
    const wishes = await sbFetch(
      `user_games?user_id=in.(${inList})&status=eq.wish&select=user_id,game_id,title`
    );
    if (!wishes?.length) return res.status(200).json({ users: userIds.length, notified: 0 });

    // 3. Dates de sortie IGDB des jeux souhaités (une seule requête batch)
    const ids = [...new Set(wishes.map(w => igdbIdOf(w.game_id)).filter(Boolean))];
    if (!ids.length) return res.status(200).json({ users: userIds.length, notified: 0 });
    const token = await getToken();
    const igdbRes = await fetch('https://api.igdb.com/v4/games', {
      method: 'POST',
      headers: { 'Client-ID': CLIENT_ID, 'Authorization': `Bearer ${token}`, 'Content-Type': 'text/plain' },
      body: `fields id,name,first_release_date; where id = (${ids.join(',')}); limit 500;`,
    });
    if (!igdbRes.ok) throw new Error(`IGDB ${igdbRes.status}: ${await igdbRes.text()}`);
    const games = await igdbRes.json();

    // 4. Sortis dans les dernières 24h
    const now = Date.now();
    const releasedToday = new Map(); // igdbId → name
    for (const g of games) {
      if (!g.first_release_date) continue;
      const rd = g.first_release_date * 1000;
      if (rd <= now && rd > now - 24 * 3600 * 1000) releasedToday.set(g.id, g.name);
    }
    if (!releasedToday.size) return res.status(200).json({ users: userIds.length, releases: 0, notified: 0 });

    // 5. Notifie chaque joueur concerné (groupé si plusieurs sorties le même jour)
    let notified = 0;
    const byUser = new Map();
    for (const w of wishes) {
      const gid = igdbIdOf(w.game_id);
      if (gid && releasedToday.has(gid)) {
        if (!byUser.has(w.user_id)) byUser.set(w.user_id, []);
        byUser.get(w.user_id).push(w.title || releasedToday.get(gid));
      }
    }
    for (const [uid, titles] of byUser) {
      const body = titles.length === 1
        ? `👀 ${titles[0]} est sorti ! Il t'attend dans ta liste de souhaits.`
        : `👀 ${titles.length} jeux de ta wishlist sortent aujourd'hui : ${titles.slice(0, 3).join(', ')}${titles.length > 3 ? '…' : ''}`;
      const n = await sendToUser(uid, { title: 'GameShelf', body, url: '/' });
      if (n) notified++;
    }
    return res.status(200).json({ users: userIds.length, releases: releasedToday.size, notified });
  } catch (e) {
    console.error('cron-wishlist error', e);
    return res.status(500).json({ error: e.message });
  }
}
