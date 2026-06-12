// api/push.js — Web Push notifications for GameShelf
// POST { type: 'friend_request' | 'friend_accept', to: <user_id> }
// Caller is identified via their Supabase access token (Authorization: Bearer).
import webpush from 'web-push';

const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '*';
const SUPABASE_URL   = process.env.SUPABASE_URL;
const SERVICE_KEY    = process.env.SUPABASE_SERVICE_ROLE_KEY;

webpush.setVapidDetails(
  'mailto:milanaksur@gmail.com',
  process.env.VAPID_PUBLIC_KEY,
  process.env.VAPID_PRIVATE_KEY
);

export async function sbFetch(path, opts = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...opts,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
      ...(opts.headers || {})
    }
  });
  if (!res.ok) throw new Error(`Supabase ${path}: ${res.status} ${await res.text()}`);
  if (res.status === 204) return null;
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

export async function sendToUser(userId, payload) {
  const subs = await sbFetch(`push_subscriptions?user_id=eq.${userId}&select=endpoint,p256dh,auth`);
  let sent = 0;
  for (const s of subs || []) {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify(payload)
      );
      sent++;
    } catch (e) {
      // Subscription expired or revoked — clean it up
      if (e.statusCode === 404 || e.statusCode === 410) {
        await sbFetch(`push_subscriptions?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: 'DELETE' }).catch(() => {});
      }
    }
  }
  return sent;
}

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method not allowed' });

  try {
    const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    if (!token) return res.status(401).json({ error: 'Missing token' });
    const uRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${token}` }
    });
    if (!uRes.ok) return res.status(401).json({ error: 'Invalid token' });
    const caller = await uRes.json();

    const { type, to } = req.body || {};
    if (!type || !to) return res.status(400).json({ error: 'type and to required' });

    // Only allow notifying users linked to the caller by a friendship row
    const fr = await sbFetch(
      `friendships?or=(and(requester_id.eq.${caller.id},addressee_id.eq.${to}),and(requester_id.eq.${to},addressee_id.eq.${caller.id}))&select=id&limit=1`
    );
    if (!fr || !fr.length) return res.status(403).json({ error: 'Not allowed' });

    const profs = await sbFetch(`profiles?id=eq.${caller.id}&select=username`);
    const name = profs?.[0]?.username || 'Un joueur';

    const MESSAGES = {
      friend_request: { title: 'GameShelf', body: `🤝 ${name} t'a envoyé une demande d'ami !` },
      friend_accept:  { title: 'GameShelf', body: `🎉 ${name} a accepté ta demande d'ami !` }
    };
    const msg = MESSAGES[type];
    if (!msg) return res.status(400).json({ error: 'Unknown type' });

    const sent = await sendToUser(to, { ...msg, url: '/' });
    return res.status(200).json({ sent });
  } catch (e) {
    console.error('push error', e);
    return res.status(500).json({ error: e.message });
  }
}
