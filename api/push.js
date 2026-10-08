// api/push.js — Web Push notifications for GameShelf
// POST { type: 'friend_request' | 'friend_accept' | 'quiz_daily' | 'reaction', to: <user_id>, reaction?, gameTitle? }
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

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const RULES = {
  friend_request: (r, me, to) => r.requester_id === me && r.addressee_id === to && r.status === 'pending',
  friend_accept:  (r, me, to) => r.requester_id === to && r.addressee_id === me && r.status === 'accepted',
  quiz_daily:     (r) => r.status === 'accepted',
  reaction:       (r) => r.status === 'accepted',
};
// Réactions : libellé côté serveur, le titre du jeu vient de l'app (texte brut, tronqué)
const REACTION_LABEL = {
  agree:    ['👍', 'est du même avis que toi sur'],
  disagree: ['🤨', "n'est pas d'accord avec toi sur"],
  want:     ['🎯', 'a envie de jouer à'],
  gg:       ['🏆', 'te félicite pour'],
};
const RECENT = new Map();

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

    const { type, to, reaction, gameTitle } = req.body || {};
    if (!type || !to) return res.status(400).json({ error: 'type and to required' });
    // « to » est inséré dans les filtres de la base : uniquement un UUID
    if (!UUID_RE.test(String(to)) || !UUID_RE.test(String(caller.id))) return res.status(400).json({ error: 'Invalid user id' });
    if (!RULES[type]) return res.status(400).json({ error: 'Unknown type' });
    if (type === 'reaction' && !REACTION_LABEL[reaction]) return res.status(400).json({ error: 'Unknown reaction' });

    // Lien requis entre l'appelant et le destinataire, selon le type :
    // demande d'ami → une demande en attente envoyée par l'appelant ;
    // acceptation → une amitié acceptée dont l'appelant est le destinataire ;
    // le reste → une amitié acceptée.
    const fr = await sbFetch(
      `friendships?or=(and(requester_id.eq.${caller.id},addressee_id.eq.${to}),and(requester_id.eq.${to},addressee_id.eq.${caller.id}))&select=requester_id,addressee_id,status`
    );
    if (!(fr || []).some(row => RULES[type](row, caller.id, to))) return res.status(403).json({ error: 'Not allowed' });

    // Anti-rafale (au mieux, par instance) : une même notification au plus une fois par minute
    const key = `${caller.id}:${type}:${to}`;
    const now = Date.now();
    if (RECENT.get(key) > now - 60_000) return res.status(429).json({ error: 'Too many notifications' });
    RECENT.set(key, now);
    if (RECENT.size > 5000) RECENT.clear();

    const profs = await sbFetch(`profiles?id=eq.${caller.id}&select=username`);
    const name = profs?.[0]?.username || 'Un joueur';

    const MESSAGES = {
      friend_request: { title: 'GameShelf', body: `🤝 ${name} t'a envoyé une demande d'ami !`, url: '/' },
      friend_accept:  { title: 'GameShelf', body: `🎉 ${name} a accepté ta demande d'ami !`, url: '/' },
      // tag 'quiz-daily' : plusieurs amis qui jouent le même jour remplacent
      // la notification au lieu de l'empiler (max 1 visible par jour)
      quiz_daily:     { title: 'GameShelf', body: `🧠 ${name} a lancé les quiz du jour — à toi de jouer !`, tag: 'quiz-daily', url: '/' },
    };
    if (type === 'reaction') {
      const lbl = REACTION_LABEL[reaction];
      if (!lbl) return res.status(400).json({ error: 'Unknown reaction' });
      const title = String(gameTitle || 'ton jeu').replace(/[\u0000-\u001f]/g, ' ').slice(0, 60);
      // tag : les réactions suivantes remplacent la notification au lieu de s'empiler
      MESSAGES.reaction = { title: 'GameShelf', body: `${lbl[0]} ${name} ${lbl[1]} ${title}`, tag: 'reactions', url: '/' };
    }
    const msg = MESSAGES[type];
    if (!msg) return res.status(400).json({ error: 'Unknown type' });

    const sent = await sendToUser(to, msg);
    return res.status(200).json({ sent });
  } catch (e) {
    console.error('push error', e);
    return res.status(500).json({ error: e.message });
  }
}
