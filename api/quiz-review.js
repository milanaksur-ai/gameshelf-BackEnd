// api/quiz-review.js — écran d'admin caché : liste les questions de quiz
// générées en attente de validation (GET) et permet de les approuver ou
// rejeter (POST). Réservé au compte de Milan (vérifié via le token Supabase
// de l'appelant, pas juste côté client).
import { sbFetch } from './push.js';

const ADMIN_EMAIL = 'milanaksur@gmail.com';
const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;

async function requireAdmin(req) {
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return null;
  const uRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${token}` },
  });
  if (!uRes.ok) return null;
  const user = await uRes.json();
  return user.email === ADMIN_EMAIL ? user : null;
}

export default async function handler(req, res) {
  const ALLOWED_ORIGIN = process.env.ALLOWED_ORIGIN || '*';
  res.setHeader('Access-Control-Allow-Origin', ALLOWED_ORIGIN);
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
  if (req.method === 'OPTIONS') return res.status(200).end();

  try {
    const admin = await requireAdmin(req);
    if (!admin) return res.status(403).json({ error: 'Forbidden' });

    if (req.method === 'GET') {
      const rows = await sbFetch(
        `generated_quiz_pool?status=eq.pending_review&order=created_at.desc&select=id,week_index,q,a,c,q_en,a_en,topic,factcheck_notes,created_at`
      );
      return res.status(200).json({ items: rows || [] });
    }

    if (req.method === 'POST') {
      const { id, action } = req.body || {};
      if (!id || !['approve', 'reject'].includes(action)) {
        return res.status(400).json({ error: 'id and action (approve|reject) required' });
      }
      await sbFetch(`generated_quiz_pool?id=eq.${id}`, {
        method: 'PATCH',
        body: JSON.stringify({
          status: action === 'approve' ? 'published' : 'rejected',
          reviewed_at: new Date().toISOString(),
          reviewed_by: admin.email,
        }),
      });
      return res.status(200).json({ ok: true });
    }

    return res.status(405).json({ error: 'Method not allowed' });
  } catch (e) {
    console.error('quiz-review error', e);
    return res.status(500).json({ error: e.message });
  }
}
