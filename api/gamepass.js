// api/gamepass.js — sert le catalogue Game Pass à l'app (écrit 1×/jour par cron-gamepass).
// Mis en cache par le CDN de Vercel : 1 h frais, puis servi pendant 24 h le temps de rafraîchir.
import { sbFetch } from './push.js';

const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '*';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method not allowed' });
  try {
    const rows = await sbFetch('gamepass_catalog?id=eq.1&select=games,new_games,leaving,updated_at');
    const row = rows?.[0];
    if (!row) return res.status(404).json({ error: 'Catalog not ready' });
    res.setHeader('Cache-Control', 'public, s-maxage=3600, stale-while-revalidate=86400');
    return res.status(200).json({ games: row.games, newGames: row.new_games, leaving: row.leaving || [], updatedAt: row.updated_at });
  } catch (e) {
    console.error('gamepass error', e);
    return res.status(500).json({ error: 'Catalog unavailable' });
  }
}
