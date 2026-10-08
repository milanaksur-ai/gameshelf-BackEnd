// api/cron-weekly.js — weekly reminder: finished games still waiting for a score
// Triggered by Vercel Cron (see vercel.json). Protected by CRON_SECRET.
import { sbFetch, sendToUser } from './push.js';

export default async function handler(req, res) {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    const subs = await sbFetch('push_subscriptions?select=user_id');
    const userIds = [...new Set((subs || []).map(s => s.user_id))];
    let notified = 0;
    for (const uid of userIds) {
      const games = await sbFetch(
        `user_games?user_id=eq.${uid}&status=eq.finished&or=(score.is.null,score.eq.0)&select=game_id`
      );
      const n = games?.length || 0;
      if (!n) continue;
      await sendToUser(uid, {
        title: 'GameShelf',
        body: n === 1
          ? '⭐ Tu as 1 jeu fini qui attend sa note !'
          : `⭐ Tu as ${n} jeux finis qui attendent leur note !`,
        url: '/'
      });
      notified++;
    }
    return res.status(200).json({ users: userIds.length, notified });
  } catch (e) {
    console.error('cron-weekly error', e);
    return res.status(500).json({ error: e.message });
  }
}
