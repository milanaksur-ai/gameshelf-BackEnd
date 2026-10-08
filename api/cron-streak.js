// api/cron-streak.js — « 🔥 Ton streak meurt à minuit » : le soir, prévient
// UNIQUEMENT les joueurs qui ont une série en cours (journée d'hier complète)
// et qui n'ont pas fini les 5 quiz du jour. Jamais de spam :
// pas de série → rien ; quiz déjà finis → rien ; max 1 notif/jour par design (cron quotidien).
// Protégé par CRON_SECRET, comme cron-weekly.
import { sbFetch, sendToUser } from './push.js';

const QUIZ_PER_DAY = 5; // doit rester aligné avec l'app

export default async function handler(req, res) {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    const subs = await sbFetch('push_subscriptions?select=user_id');
    const userIds = new Set((subs || []).map(s => s.user_id));
    if (!userIds.size) return res.status(200).json({ users: 0, notified: 0 });

    // Même index de jour que l'app : jours epoch UTC
    const today = Math.floor(Date.now() / 86400000);
    const since = today - 30; // 30 jours d'historique suffisent pour compter une série

    // Un seul fetch pour tout le monde, groupé en mémoire
    const rows = await sbFetch(
      `quiz_scores?day_index=gte.${since}&select=user_id,day_index`
    );
    const perUserDay = new Map(); // uid → Map(day → count)
    for (const r of rows || []) {
      if (!userIds.has(r.user_id)) continue;
      if (!perUserDay.has(r.user_id)) perUserDay.set(r.user_id, new Map());
      const m = perUserDay.get(r.user_id);
      m.set(r.day_index, (m.get(r.day_index) || 0) + 1);
    }

    let notified = 0;
    for (const [uid, days] of perUserDay) {
      const doneToday = days.get(today) || 0;
      if (doneToday >= QUIZ_PER_DAY) continue;          // journée déjà validée
      if ((days.get(today - 1) || 0) < QUIZ_PER_DAY) continue; // pas de série en cours
      // Longueur de la série (jours consécutifs complets en remontant depuis hier)
      let streak = 0, d = today - 1;
      while ((days.get(d) || 0) >= QUIZ_PER_DAY) { streak++; d--; }
      const left = QUIZ_PER_DAY - doneToday;
      const body = doneToday > 0
        ? `🔥 Ton streak de ${streak} jour${streak > 1 ? 's' : ''} meurt à minuit — plus que ${left} quiz !`
        : `🔥 Ton streak de ${streak} jour${streak > 1 ? 's' : ''} meurt à minuit — fais tes 5 quiz du jour !`;
      const n = await sendToUser(uid, { title: 'GameShelf', body, url: '/' });
      if (n) notified++;
    }
    return res.status(200).json({ users: userIds.size, notified });
  } catch (e) {
    console.error('cron-streak error', e);
    return res.status(500).json({ error: e.message });
  }
}
