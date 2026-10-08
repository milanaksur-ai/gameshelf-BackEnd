// api/cron-generate-content.js — génère automatiquement la question d'actu
// du sondage de la semaine (weekly_poll_override), inspirée des dernières
// actus gaming. Tourne quotidiennement (voir vercel.json) — idempotent : ne
// régénère rien si le sondage de la semaine existe déjà. Protégé par CRON_SECRET.
import { sbFetch } from './push.js';
import { claudeJson, fetchGamingHeadlines } from './_llm.js';

function weekIndex() {
  const dayIndex = Math.floor(Date.now() / 86400000);
  return Math.floor(dayIndex / 7);
}

const POLL_SCHEMA = {
  type: 'object',
  properties: {
    q: { type: 'string' },
    opts: { type: 'array', items: { type: 'string' } },
    q_en: { type: 'string' },
    opts_en: { type: 'array', items: { type: 'string' } },
  },
  required: ['q', 'opts', 'q_en', 'opts_en'],
  additionalProperties: false,
};

async function generatePoll(headlines, week) {
  const poll = await claudeJson({
    system: `Tu écris des questions de sondage pour GameShelf, une app de suivi de jeux vidéo façon Letterboxd. Le sondage de la semaine est une question d'opinion sur l'actualité ou la culture gaming, sans bonne ou mauvaise réponse. Ton : direct, un peu clivant, jamais neutre-mou. 3 à 4 options courtes (3-6 mots), pas de "aucune de ces réponses". Un seul emoji maximum, uniquement dans la question, jamais dans les options. Fournis systématiquement la version anglaise (q_en/opts_en), même nombre d'options, même ordre.
Exemples de ton (ne pas recopier, juste s'en inspirer) :
- "Les jeux à 90 € : tu suis ou tu décroches ?" / ["Je paie pour les grosses sorties", "J'attends les soldes, toujours", "Je suis passé à l'abonnement", "J'achète moins, mais mieux"]
- "Un remake de plus vient d'être annoncé : ta réaction ?" / ["Ces classiques le méritent", "L'industrie tourne en rond", "Tout dépend du prix"]`,
    prompt: `Voici quelques titres d'actualité gaming récents (pour t'inspirer d'un sujet chaud, sans obligation de les citer littéralement) :\n${headlines.map(h => `- ${h}`).join('\n')}\n\nÉcris UNE nouvelle question de sondage originale, différente des exemples donnés.`,
    schema: POLL_SCHEMA,
  });
  if (!Array.isArray(poll.opts) || poll.opts.length < 2 || poll.opts.length !== poll.opts_en.length) {
    throw new Error('poll: options FR/EN incohérentes');
  }
  await sbFetch('weekly_poll_override', {
    method: 'POST',
    body: JSON.stringify({ week_index: week, q: poll.q, opts: poll.opts, q_en: poll.q_en, opts_en: poll.opts_en }),
  });
  return poll;
}

export default async function handler(req, res) {
  if (!process.env.CRON_SECRET || req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    const week = weekIndex();
    const result = { week, poll: null };

    const existingPoll = await sbFetch(`weekly_poll_override?week_index=eq.${week}&select=week_index&limit=1`);
    if (!existingPoll?.length) {
      const headlines = await fetchGamingHeadlines();
      if (headlines.length) result.poll = await generatePoll(headlines, week);
    }

    return res.status(200).json(result);
  } catch (e) {
    console.error('cron-generate-content error', e);
    return res.status(500).json({ error: e.message });
  }
}
