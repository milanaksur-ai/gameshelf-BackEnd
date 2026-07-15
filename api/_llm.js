// api/_llm.js — helper partagé pour la génération de contenu via Claude
// (sondages + quiz "Actualité Gaming"). Fichier préfixé "_" : Vercel ne le
// déploie pas comme route, seulement comme module importable.
import Anthropic from '@anthropic-ai/sdk';

const anthropic = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
const MODEL = 'claude-opus-4-8';

// Appelle Claude avec un schéma JSON strict et renvoie l'objet parsé.
export async function claudeJson({ system, prompt, schema }) {
  const res = await anthropic.messages.create({
    model: MODEL,
    max_tokens: 2048,
    system,
    messages: [{ role: 'user', content: prompt }],
    output_config: { format: { type: 'json_schema', schema } },
  });
  const text = res.content.find(b => b.type === 'text')?.text;
  if (!text) throw new Error('Claude: pas de réponse texte');
  return JSON.parse(text);
}

// Récupère les derniers titres d'actu gaming via RSS (sans dépendance XML :
// extraction par regex, suffisant pour de simples <title> de flux RSS 2.0).
export async function fetchGamingHeadlines(limit = 15) {
  const feeds = [
    'https://kotaku.com/rss',
    'https://www.polygon.com/rss/index.xml',
  ];
  const headlines = [];
  for (const url of feeds) {
    try {
      const res = await fetch(url, { headers: { 'User-Agent': 'GameShelf/1.0' } });
      if (!res.ok) continue;
      const xml = await res.text();
      const items = xml.split('<item>').slice(1);
      for (const item of items) {
        const m = item.match(/<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?<\/title>/s);
        if (m && m[1]) headlines.push(m[1].trim());
        if (headlines.length >= limit) break;
      }
    } catch (e) { /* flux indisponible → on continue avec ce qu'on a */ }
    if (headlines.length >= limit) break;
  }
  return headlines.slice(0, limit);
}
