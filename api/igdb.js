// GameShelf — IGDB Proxy
// Twitch/IGDB API via Vercel serverless
// Client ID: miel08ygfexe05pjw9m54jsfcv2eww

const CLIENT_ID     = process.env.IGDB_CLIENT_ID     || 'miel08ygfexe05pjw9m54jsfcv2eww';
const CLIENT_SECRET = process.env.IGDB_CLIENT_SECRET  || '1ltr3ucwaovbng4smqozwzpagmk767';
const ALLOWED       = process.env.ALLOWED_ORIGIN      || 'https://milanaksur-ai.github.io';

let cachedToken = null;
let tokenExpiry = 0;

async function getTwitchToken() {
  if (cachedToken && Date.now() < tokenExpiry) return cachedToken;
  const res = await fetch(
    `https://id.twitch.tv/oauth2/token?client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&grant_type=client_credentials`,
    { method: 'POST' }
  );
  if (!res.ok) throw new Error(`Twitch token error: ${res.status}`);
  const data = await res.json();
  cachedToken = data.access_token;
  tokenExpiry = Date.now() + (data.expires_in - 60) * 1000;
  return cachedToken;
}

async function igdbQuery(endpoint, body, token) {
  const res = await fetch(`https://api.igdb.com/v4/${endpoint}`, {
    method: 'POST',
    headers: {
      'Client-ID': CLIENT_ID,
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'text/plain',
    },
    body,
  });
  if (!res.ok) throw new Error(`IGDB ${endpoint} error: ${res.status}`);
  return res.json();
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  const { action, query, id, ids } = req.body || {};

  try {
    const token = await getTwitchToken();

    // ── Search games ──────────────────────────────────────
    if (action === 'search') {
      if (!query) return res.status(400).json({ error: 'Missing query' });

      const data = await igdbQuery('games', `
        search "${query}";
        fields name, cover.image_id, genres.name, first_release_date,
               aggregated_rating, platforms.name, slug, summary,
               involved_companies.company.name, involved_companies.developer;
        where version_parent = null & category = (0,8,9);
        limit 10;
      `, token);

      const games = data.map(g => formatGame(g));
      return res.status(200).json({ games });
    }

    // ── Get game by ID ────────────────────────────────────
    if (action === 'game') {
      if (!id) return res.status(400).json({ error: 'Missing id' });

      const data = await igdbQuery('games', `
        fields name, cover.image_id, genres.name, first_release_date,
               aggregated_rating, platforms.name, slug, summary,
               involved_companies.company.name, involved_companies.developer,
               screenshots.image_id, similar_games.name, similar_games.cover.image_id;
        where id = ${id};
        limit 1;
      `, token);

      if (!data.length) return res.status(404).json({ error: 'Game not found' });
      return res.status(200).json({ game: formatGame(data[0]) });
    }

    // ── Popular / trending games ──────────────────────────
    if (action === 'popular') {
      const data = await igdbQuery('games', `
        fields name, cover.image_id, genres.name, first_release_date,
               aggregated_rating, platforms.name, slug;
        where aggregated_rating > 80
          & aggregated_rating_count > 20
          & cover != null
          & version_parent = null
          & category = (0,8,9);
        sort aggregated_rating desc;
        limit 20;
      `, token);

      return res.status(200).json({ games: data.map(formatGame) });
    }

    // ── Recent / new releases ─────────────────────────────
    if (action === 'recent') {
      const oneYearAgo = Math.floor(Date.now() / 1000) - 365 * 24 * 3600;
      const now = Math.floor(Date.now() / 1000);

      const data = await igdbQuery('games', `
        fields name, cover.image_id, genres.name, first_release_date,
               aggregated_rating, platforms.name, slug;
        where first_release_date > ${oneYearAgo}
          & first_release_date < ${now}
          & cover != null
          & version_parent = null
          & category = (0,8,9)
          & aggregated_rating_count > 5;
        sort first_release_date desc;
        limit 20;
      `, token);

      return res.status(200).json({ games: data.map(formatGame) });
    }

    // ── Coming soon ───────────────────────────────────────
    if (action === 'upcoming') {
      const now = Math.floor(Date.now() / 1000);
      const sixMonths = now + 180 * 24 * 3600;

      const data = await igdbQuery('games', `
        fields name, cover.image_id, genres.name, first_release_date,
               platforms.name, slug, hypes;
        where first_release_date > ${now}
          & first_release_date < ${sixMonths}
          & cover != null
          & version_parent = null
          & category = (0,8,9);
        sort hypes desc;
        limit 10;
      `, token);

      return res.status(200).json({ games: data.map(formatGame) });
    }

    return res.status(400).json({ error: `Unknown action: ${action}` });

  } catch (e) {
    console.error('IGDB error:', e);
    return res.status(500).json({ error: e.message });
  }
}

function formatGame(g) {
  const coverId = g.cover?.image_id;
  const year = g.first_release_date
    ? new Date(g.first_release_date * 1000).getFullYear()
    : 0;
  const genre = g.genres?.[0]?.name || '';
  const meta = g.aggregated_rating ? Math.round(g.aggregated_rating) : 0;
  const developer = g.involved_companies?.find(c => c.developer)?.company?.name || '';

  return {
    id:        `igdb_${g.id}`,
    igdbId:    g.id,
    title:     g.name,
    cover:     coverId ? `https://images.igdb.com/igdb/image/upload/t_cover_big/${coverId}.jpg` : null,
    coverHd:   coverId ? `https://images.igdb.com/igdb/image/upload/t_1080p/${coverId}.jpg` : null,
    genre,
    year,
    meta,
    developer,
    summary:   g.summary || '',
    slug:      g.slug || '',
    platforms: g.platforms?.map(p => p.name) || [],
    screenshots: (g.screenshots || []).map(s =>
      `https://images.igdb.com/igdb/image/upload/t_screenshot_big/${s.image_id}.jpg`
    ),
  };
}
