const XBL_KEY  = process.env.XBL_KEY  || 'b15268e0-da41-4fad-ac2c-baee2f4d46a0';
const XBL_BASE = 'https://xbl.io/api/v2';
const ALLOWED  = process.env.ALLOWED_ORIGIN || 'https://milanaksur-ai.github.io';

export default async function handler(req, res) {
  res.setHeader('Access-Control-Allow-Origin', ALLOWED);
  res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  res.setHeader('Content-Type', 'application/json');

  if (req.method === 'OPTIONS') return res.status(200).end();

  const { endpoint } = req.query;
  const allowed = ['account', 'achievements/titles'];
  if (!endpoint || !allowed.includes(endpoint)) {
    return res.status(400).json({ error: 'Endpoint invalide' });
  }

  try {
    const upstream = await fetch(`${XBL_BASE}/${endpoint}`, {
      headers: {
        'X-Authorization': XBL_KEY,
        'Accept': 'application/json',
      }
    });
    const text = await upstream.text();
    res.status(upstream.status).send(text);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}
