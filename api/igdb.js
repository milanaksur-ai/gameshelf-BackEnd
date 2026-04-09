// api/igdb.js — IGDB proxy for GameShelf
const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '*';
const CLIENT_ID      = process.env.IGDB_CLIENT_ID;
const CLIENT_SECRET  = process.env.IGDB_CLIENT_SECRET;
const IGDB_BASE      = 'https://api.igdb.com/v4';

// Modern platforms: PC, PS4, PS5, Xbox One, Xbox Series X|S, Switch
const MODERN_PLATFORMS = '(6,48,49,130,167,169)';
const COMMON_FIELDS = [
  'name', 'cover.image_id',
  'first_release_date', 'genres.name',
  'rating', 'aggregated_rating', 'aggregated_rating_count', 'rating_count',
  'external_games.uid', 'external_games.category',
  'platforms.abbreviation', 'platforms.name',
].join(',');

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

async function igdbQuery(endpoint, body) {
  const token = await getToken();
  const res = await fetch(`${IGDB_BASE}/${endpoint}`, {
    method: 'POST',
    headers: {
      'Client-ID': CLIENT_ID,
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'text/plain',
    },
    body,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`IGDB ${endpoint} error ${res.status}: ${text}`);
  }
  return res.json();
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  try {
    const { action, query, ids, limit = 12 } = req.body || {};

    if (action === 'search') {
      if (!query) return res.status(400).json({ error: 'query required' });
      const data = await igdbQuery('games',
        `search "${query}"; fields ${COMMON_FIELDS}; where platforms = ${MODERN_PLATFORMS}; limit ${limit};`);
      return res.json(data);
    }

    if (action === 'trending') {
      const oneYearAgo = Math.floor(Date.now() / 1000) - 365 * 24 * 3600;
      const data = await igdbQuery('games',
        `fields ${COMMON_FIELDS}; where first_release_date > ${oneYearAgo} & rating_count > 10 & platforms = ${MODERN_PLATFORMS}; sort rating_count desc; limit ${limit};`);
      return res.json(data);
    }

    if (action === 'popular') {
      const data = await igdbQuery('games',
        `fields ${COMMON_FIELDS}; where aggregated_rating > 80 & aggregated_rating_count > 10 & rating_count > 50 & platforms = ${MODERN_PLATFORMS}; sort aggregated_rating desc; limit ${limit};`);
      return res.json(data);
    }

    if (action === 'game' && ids?.length) {
      const data = await igdbQuery('games',
        `fields ${COMMON_FIELDS}; where id = (${ids.join(',')}); limit ${ids.length};`);
      return res.json(data);
    }

    return res.status(400).json({ error: 'Unknown action' });
  } catch(e) {
    console.error('IGDB proxy error:', e);
    return res.status(500).json({ error: e.message });
  }
}
