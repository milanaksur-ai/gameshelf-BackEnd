// api/cron-generate-content.js — génère automatiquement :
//  1. la question d'actu du sondage de la semaine (weekly_poll_override)
//  2. des questions de quiz "Actualité Gaming" (generated_quiz_pool),
//     vérifiées par une 2e passe LLM de fact-check avant de rejoindre la
//     file d'attente de review de Milan (jamais publiées automatiquement).
// Tourne quotidiennement (voir vercel.json) — idempotent : ne régénère rien
// si le contenu de la semaine existe déjà. Protégé par CRON_SECRET.
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

const QUIZ_SCHEMA = {
  type: 'object',
  properties: {
    topic: { type: 'string' },
    q: { type: 'string' },
    a: { type: 'array', items: { type: 'string' } },
    c: { type: 'integer' },
    q_en: { type: 'string' },
    a_en: { type: 'array', items: { type: 'string' } },
  },
  required: ['topic', 'q', 'a', 'c', 'q_en', 'a_en'],
  additionalProperties: false,
};

const FACTCHECK_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['pass', 'fail'] },
    notes: { type: 'string' },
  },
  required: ['verdict', 'notes'],
  additionalProperties: false,
};

async function generatePoll(headlines, week) {
  const poll = await claudeJson({
    system: `Tu écris des questions de sondage pour GameShelf, une app de suivi de jeux vidéo façon Letterboxd. Le sondage de la semaine est une question d'opinion sur l'actualité ou la culture gaming, sans bonne ou mauvaise réponse. Ton : direct, un peu clivant, jamais neutre-mou. 3 à 4 options courtes (3-6 mots), pas de "aucune de ces réponses". Un seul emoji maximum, uniquement dans la question, jamais dans les options. Fournis systématiquement la version anglaise (q_en/opts_en), même nombre d'options, même ordre.
Exemples de ton (ne pas recopier, juste s'en inspirer) :
- "Les jeux à 90 € : tu suis ou tu décroches ?" / ["Je paie pour les grosses sorties", "J'attends les soldes, toujours", "Je suis passé à l'abonnement", "J'achète moins, mais mieux"]
- "Encore un remake annoncé. Réaction ?" / ["Le patrimoine mérite ça", "L'industrie tourne en rond", "Tout dépend du prix"]`,
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

async function generateQuizCandidate(headline, week) {
  const draft = await claudeJson({
    system: `Tu écris des questions de quiz gaming pour GameShelf. RÈGLE ABSOLUE : la bonne réponse doit être un fait EXPLICITEMENT présent dans le titre d'actualité fourni — jamais une connaissance externe, jamais une supposition. C'est une question de compréhension de texte, pas de culture générale libre. 4 réponses plausibles, une seule correcte. Fournis la version anglaise (q_en/a_en), même ordre, même nombre de réponses.`,
    prompt: `Titre d'actualité : "${headline}"\n\nÉcris une question de quiz à choix multiples (4 réponses) dont la réponse correcte est explicitement donnée par ce titre.`,
    schema: QUIZ_SCHEMA,
  });
  if (!Array.isArray(draft.a) || draft.a.length !== 4 || !Array.isArray(draft.a_en) || draft.a_en.length !== 4) {
    throw new Error('quiz: le nombre de réponses FR/EN doit être 4');
  }
  const check = await claudeJson({
    system: `Tu es un vérificateur factuel strict. On te donne un titre d'actualité et une question de quiz censée en découler. Réponds "pass" UNIQUEMENT si la réponse marquée correcte est explicitement et sans ambiguïté soutenue par le texte du titre. Au moindre doute, réponds "fail".`,
    prompt: `Titre : "${headline}"\nQuestion : "${draft.q}"\nRéponses : ${draft.a.map((a, i) => `${i}) ${a}`).join(', ')}\nRéponse marquée correcte : ${draft.a[draft.c]}`,
    schema: FACTCHECK_SCHEMA,
  });
  const row = {
    week_index: week, q: draft.q, a: draft.a, c: draft.c, q_en: draft.q_en, a_en: draft.a_en,
    topic: headline, factcheck_verdict: check.verdict, factcheck_notes: check.notes,
    status: check.verdict === 'pass' ? 'pending_review' : 'rejected',
  };
  await sbFetch('generated_quiz_pool', { method: 'POST', body: JSON.stringify(row) });
  return row;
}

export default async function handler(req, res) {
  if (process.env.CRON_SECRET && req.headers.authorization !== `Bearer ${process.env.CRON_SECRET}`) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  try {
    const week = weekIndex();
    const result = { week, poll: null, quiz: [] };

    const existingPoll = await sbFetch(`weekly_poll_override?week_index=eq.${week}&select=week_index&limit=1`);
    const headlines = await fetchGamingHeadlines();
    if (!existingPoll?.length && headlines.length) {
      result.poll = await generatePoll(headlines, week);
    }

    const existingQuiz = await sbFetch(
      `generated_quiz_pool?week_index=eq.${week}&status=in.(pending_review,published)&select=id&limit=1`
    );
    if (!existingQuiz?.length && headlines.length) {
      // 2 candidats, headlines distincts si possible — le fact-check filtre déjà
      // le mauvais ; Milan valide ce qui passe via l'écran de review caché.
      const picks = [headlines[0], headlines[Math.min(1, headlines.length - 1)]];
      for (const h of new Set(picks)) {
        try { result.quiz.push(await generateQuizCandidate(h, week)); }
        catch (e) { console.error('cron-generate-content quiz candidate error', e); }
      }
    }

    return res.status(200).json(result);
  } catch (e) {
    console.error('cron-generate-content error', e);
    return res.status(500).json({ error: e.message });
  }
}
