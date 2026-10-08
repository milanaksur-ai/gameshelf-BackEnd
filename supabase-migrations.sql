-- GameShelf Supabase migrations
-- Run these in the Supabase SQL editor (project: tphspftxnfhqhhykavbw)

-- ── 1. COLLECTIONS ────────────────────────────────────────────────────────────
-- Stores user-created game playlists. Public read, user-only write.
-- Primary key is TEXT so it works with the frontend's 'col_<timestamp>' IDs.

CREATE TABLE IF NOT EXISTS collections (
  id         TEXT PRIMARY KEY,
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  emoji      TEXT NOT NULL DEFAULT '📚',
  games      JSONB NOT NULL DEFAULT '[]',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE collections ENABLE ROW LEVEL SECURITY;

CREATE POLICY "collections_read_all"  ON collections FOR SELECT USING (true);
CREATE POLICY "collections_write_own" ON collections FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "collections_update_own" ON collections FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "collections_delete_own" ON collections FOR DELETE USING (auth.uid() = user_id);

-- Index for fetching by user
CREATE INDEX IF NOT EXISTS collections_user_id_idx ON collections (user_id);


-- ── 2. QUIZ CHALLENGES ────────────────────────────────────────────────────────
-- Async quiz duels between friends. Both players complete independently.
-- Status: 'pending' → 'challenger_done' → 'completed'

CREATE TABLE IF NOT EXISTS quiz_challenges (
  id                 UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  challenger_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  challenged_id      UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  quiz_id            TEXT NOT NULL,
  quiz_name          TEXT NOT NULL,
  status             TEXT NOT NULL DEFAULT 'pending',
  challenger_score   INTEGER,
  challenger_total   INTEGER,
  challenged_score   INTEGER,
  challenged_total   INTEGER,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE quiz_challenges ENABLE ROW LEVEL SECURITY;

CREATE POLICY "qc_select_participants" ON quiz_challenges FOR SELECT
  USING (auth.uid() = challenger_id OR auth.uid() = challenged_id);

CREATE POLICY "qc_insert_challenger" ON quiz_challenges FOR INSERT
  WITH CHECK (auth.uid() = challenger_id);

CREATE POLICY "qc_update_participants" ON quiz_challenges FOR UPDATE
  USING (auth.uid() = challenger_id OR auth.uid() = challenged_id);

-- Indexes for notification queries
CREATE INDEX IF NOT EXISTS qc_challenged_idx ON quiz_challenges (challenged_id, status);
CREATE INDEX IF NOT EXISTS qc_challenger_idx ON quiz_challenges (challenger_id, status);


-- ── 3. XP COLUMN ON PROFILES ──────────────────────────────────────────────────
-- Tracks accumulated XP for the leveling system.
-- Public read so friends can see each other's rank.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS xp INTEGER NOT NULL DEFAULT 0;

-- Allow anyone to read xp (profiles already have public select policy)
-- Allow users to update their own xp only
DROP POLICY IF EXISTS "profiles_update_own_xp" ON profiles;
CREATE POLICY "profiles_update_own_xp" ON profiles FOR UPDATE
  USING (auth.uid() = id);


-- ── 4. ACHIEVEMENTS COLUMN ON PROFILES ───────────────────────────────────────
-- Stores unlocked achievement IDs as a JSON array.
-- Public read so friends can see each other's achievements (competitive).

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS achievements JSONB NOT NULL DEFAULT '[]';


-- ── 5. XP_BACKFILLED FLAG ON PROFILES ────────────────────────────────────────
-- Cross-device guard: once the retroactive XP backfill has run for a user,
-- this is set to TRUE in Supabase. Any other device loading the profile sees
-- this flag and skips the backfill entirely, preventing double XP.

ALTER TABLE profiles ADD COLUMN IF NOT EXISTS xp_backfilled BOOLEAN NOT NULL DEFAULT FALSE;

-- ── 6. VISIBILITÉ DES COLLECTIONS : public / amis / privé ───────────────────
-- Avant : policy "collections_read_all" USING (true) → toute collection, même
-- marquée privée, était lisible par n'importe qui avec la clé publique ; le 🔒
-- n'était qu'un filtre d'affichage. Ici le contrôle se fait dans la base.
-- Idempotent : peut être relancé sans risque.

ALTER TABLE collections ADD COLUMN IF NOT EXISTS is_public  BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE collections ADD COLUMN IF NOT EXISTS visibility TEXT;
UPDATE collections
   SET visibility = CASE WHEN is_public = FALSE THEN 'private' ELSE 'public' END
 WHERE visibility IS NULL;
ALTER TABLE collections ALTER COLUMN visibility SET DEFAULT 'public';
ALTER TABLE collections ALTER COLUMN visibility SET NOT NULL;
ALTER TABLE collections DROP CONSTRAINT IF EXISTS collections_visibility_check;
ALTER TABLE collections ADD CONSTRAINT collections_visibility_check
  CHECK (visibility IN ('public', 'friends', 'private'));

-- Garde is_public cohérent (= « pas privée ») pour les anciennes versions de
-- l'app qui n'écrivent que is_public : un passage en privé depuis un vieux
-- client met bien visibility à 'private'.
CREATE OR REPLACE FUNCTION collections_sync_visibility() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.is_public = FALSE THEN NEW.visibility := 'private'; END IF;
  ELSIF NEW.visibility IS NOT DISTINCT FROM OLD.visibility
    AND NEW.is_public IS DISTINCT FROM OLD.is_public THEN
    NEW.visibility := CASE WHEN NEW.is_public THEN 'public' ELSE 'private' END;
  END IF;
  NEW.is_public := NEW.visibility <> 'private';
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS collections_sync_visibility ON collections;
CREATE TRIGGER collections_sync_visibility
  BEFORE INSERT OR UPDATE ON collections
  FOR EACH ROW EXECUTE FUNCTION collections_sync_visibility();

-- L'utilisateur connecté est-il ami (accepté) avec `other` ?
-- SECURITY DEFINER : ne dépend pas des policies de friendships. Ne prend qu'un
-- argument (l'autre est auth.uid()) pour ne pas permettre de tester l'amitié
-- entre deux inconnus via RPC.
CREATE OR REPLACE FUNCTION public.is_friend_of(other UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM friendships f
     WHERE f.status = 'accepted'
       AND ((f.requester_id = auth.uid() AND f.addressee_id = other)
         OR (f.addressee_id = auth.uid() AND f.requester_id = other))
  );
$$;
REVOKE ALL ON FUNCTION public.is_friend_of(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_friend_of(UUID) TO anon, authenticated;

-- Remplace TOUTES les policies de lecture existantes (y compris celles créées
-- à la main dans le dashboard) : une seule policy permissive USING (true)
-- restante suffirait à tout rendre lisible.
DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN SELECT policyname FROM pg_policies
            WHERE schemaname = 'public' AND tablename = 'collections' AND cmd = 'SELECT'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.collections', p.policyname);
  END LOOP;
END $$;

CREATE POLICY "collections_read_by_visibility" ON collections FOR SELECT USING (
     user_id = auth.uid()
  OR visibility = 'public'
  OR (visibility = 'friends' AND public.is_friend_of(user_id))
);

CREATE INDEX IF NOT EXISTS friendships_pair_idx ON friendships (requester_id, addressee_id) WHERE status = 'accepted';

-- Vérification : doit lister une seule ligne SELECT (collections_read_by_visibility).
-- Une policy "ALL" en USING (true) annulerait tout : la signaler si présente.
SELECT policyname, cmd, qual FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'collections' ORDER BY cmd;

-- ── 7. VISIBILITÉ DES TIER LISTS : public / amis / privé ────────────────────
-- Même principe que la section 6 (collections). Prérequis : section 6 lancée
-- (fonction is_friend_of). Idempotent.
-- Cas particulier : d'anciennes listes ont été créées sans user_id. L'app les
-- « revendique » au chargement (UPDATE … WHERE user_id IS NULL), ce qui exige
-- qu'elles restent lisibles : elles le sont tant qu'elles n'ont pas de
-- propriétaire, puis suivent leur visibilité une fois revendiquées.

ALTER TABLE tier_lists ADD COLUMN IF NOT EXISTS is_public  BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE tier_lists ADD COLUMN IF NOT EXISTS visibility TEXT;
UPDATE tier_lists
   SET visibility = CASE WHEN is_public = FALSE THEN 'private' ELSE 'public' END
 WHERE visibility IS NULL;
ALTER TABLE tier_lists ALTER COLUMN visibility SET DEFAULT 'public';
ALTER TABLE tier_lists ALTER COLUMN visibility SET NOT NULL;
ALTER TABLE tier_lists DROP CONSTRAINT IF EXISTS tier_lists_visibility_check;
ALTER TABLE tier_lists ADD CONSTRAINT tier_lists_visibility_check
  CHECK (visibility IN ('public', 'friends', 'private'));

-- Même fonction de synchro is_public ↔ visibility que pour les collections
DROP TRIGGER IF EXISTS tier_lists_sync_visibility ON tier_lists;
CREATE TRIGGER tier_lists_sync_visibility
  BEFORE INSERT OR UPDATE ON tier_lists
  FOR EACH ROW EXECUTE FUNCTION collections_sync_visibility();

DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN SELECT policyname FROM pg_policies
            WHERE schemaname = 'public' AND tablename = 'tier_lists' AND cmd = 'SELECT'
  LOOP
    EXECUTE format('DROP POLICY %I ON public.tier_lists', p.policyname);
  END LOOP;
END $$;

CREATE POLICY "tier_lists_read_by_visibility" ON tier_lists FOR SELECT USING (
     user_id = auth.uid()
  OR user_id IS NULL
  OR visibility = 'public'
  OR (visibility = 'friends' AND public.is_friend_of(user_id))
);

-- Vérification : une seule ligne SELECT (tier_lists_read_by_visibility).
-- Les lignes INSERT / UPDATE / DELETE / ALL sont à me transmettre pour relecture.
SELECT policyname, cmd, qual, with_check FROM pg_policies
 WHERE schemaname = 'public' AND tablename = 'tier_lists' ORDER BY cmd;

-- ── 8. ÉCRITURE DES TIER LISTS : propriétaire uniquement ────────────────────
-- État constaté en prod avant cette section :
--   "Public update"  UPDATE USING (true)        → n'importe qui (même anonyme)
--                    pouvait modifier, rendre publique ou s'approprier
--                    (user_id) n'importe quelle tier list ;
--   "Public insert"  INSERT WITH CHECK (true)   → création au nom d'un autre ;
--   "tl_delete_own"  DELETE … OR user_id IS NULL → suppression par n'importe qui
--                    des anciennes listes sans propriétaire.
-- Remplace toutes les policies d'écriture (INSERT / UPDATE / DELETE / ALL).
-- Les anciennes listes sans user_id restent revendicables par un utilisateur
-- connecté (UPDATE … SET user_id = soi), ce que fait l'app au chargement.
-- Idempotent.

DO $$
DECLARE p RECORD;
BEGIN
  FOR p IN SELECT policyname FROM pg_policies
            WHERE schemaname = 'public' AND tablename = 'tier_lists'
              AND cmd IN ('INSERT', 'UPDATE', 'DELETE', 'ALL')
  LOOP
    EXECUTE format('DROP POLICY %I ON public.tier_lists', p.policyname);
  END LOOP;
END $$;

CREATE POLICY "tier_lists_insert_own" ON tier_lists FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL AND user_id = auth.uid());

CREATE POLICY "tier_lists_update_own" ON tier_lists FOR UPDATE
  USING      (user_id = auth.uid() OR (user_id IS NULL AND auth.uid() IS NOT NULL))
  WITH CHECK (user_id = auth.uid());

CREATE POLICY "tier_lists_delete_own" ON tier_lists FOR DELETE
  USING (user_id = auth.uid());

-- Vérification : toutes les policies des deux tables.
SELECT tablename, policyname, cmd, qual, with_check FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('tier_lists', 'collections')
 ORDER BY tablename, cmd;

-- ── 9. ORDRE DU TOP (départage des jeux de même note) ───────────────────────
-- Liste d'ids de jeux dans l'ordre choisi par le joueur. Sert uniquement à
-- départager les égalités de note (Top 6 du profil, Top 20, vues des amis).
-- Lisible avec le profil, modifiable via la policy UPDATE existante des profils.
ALTER TABLE profiles ADD COLUMN IF NOT EXISTS top_order JSONB NOT NULL DEFAULT '[]'::jsonb;

-- ── 10. FORMATS DES DONNÉES AFFICHÉES CHEZ LES AUTRES JOUEURS ──────────────
-- Défense en profondeur : l'app échappe désormais tout ce qu'elle affiche, et la
-- base refuse en plus les valeurs capables de casser le HTML (pseudo, avatar,
-- dégradé, photo, identifiants de jeu). Sans ces contraintes, n'importe qui peut
-- écrire ces champs directement via l'API, sans passer par l'app.
-- NOT VALID : s'applique aux nouvelles écritures sans bloquer sur l'existant ;
-- la requête de fin liste les lignes existantes hors format. Idempotent.

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_username_safe;
ALTER TABLE profiles ADD CONSTRAINT profiles_username_safe CHECK (
  username IS NULL OR (char_length(username) BETWEEN 1 AND 40
                       AND username !~ '[<>"`&\\[:cntrl:]]')) NOT VALID;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_avatar_safe;
ALTER TABLE profiles ADD CONSTRAINT profiles_avatar_safe CHECK (
  avatar IS NULL OR (char_length(avatar) <= 16 AND avatar !~ '[<>"''`&\\[:cntrl:]]')) NOT VALID;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_avatar_grad_safe;
ALTER TABLE profiles ADD CONSTRAINT profiles_avatar_grad_safe CHECK (
  avatar_grad IS NULL OR (avatar_grad ~ '^(linear|radial|conic)-gradient\([#0-9A-Za-z,.%[:space:]()-]*\)$'
                          AND avatar_grad !~* 'url[[:space:]]*\(')) NOT VALID;

ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_avatar_url_safe;
ALTER TABLE profiles ADD CONSTRAINT profiles_avatar_url_safe CHECK (
  avatar_url IS NULL
  OR avatar_url ~ '^https://[^[:space:]"''<>`\\]+$'
  OR avatar_url ~ '^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$') NOT VALID;

ALTER TABLE user_games DROP CONSTRAINT IF EXISTS user_games_ids_safe;
ALTER TABLE user_games ADD CONSTRAINT user_games_ids_safe CHECK (
  game_id ~ '^[A-Za-z0-9_:.-]{1,100}$'
  AND (image_id IS NULL OR image_id ~ '^[A-Za-z0-9_-]{0,64}$')) NOT VALID;

-- Lignes existantes hors format (à corriger à la main si la liste n'est pas vide)
SELECT 'profiles' AS t, id::text, username FROM profiles
 WHERE (username IS NOT NULL AND (char_length(username) NOT BETWEEN 1 AND 40 OR username ~ '[<>"`&\\[:cntrl:]]'))
    OR (avatar IS NOT NULL AND (char_length(avatar) > 16 OR avatar ~ '[<>"''`&\\[:cntrl:]]'))
    OR (avatar_grad IS NOT NULL AND (avatar_grad !~ '^(linear|radial|conic)-gradient\([#0-9A-Za-z,.%[:space:]()-]*\)$' OR avatar_grad ~* 'url[[:space:]]*\('))
    OR (avatar_url IS NOT NULL AND avatar_url !~ '^https://[^[:space:]"''<>`\\]+$' AND avatar_url !~ '^data:image/(png|jpe?g|webp|gif);base64,[A-Za-z0-9+/=]+$')
UNION ALL
SELECT 'user_games', user_id::text || ' / ' || game_id, title FROM user_games
 WHERE game_id !~ '^[A-Za-z0-9_:.-]{1,100}$' OR (image_id IS NOT NULL AND image_id !~ '^[A-Za-z0-9_-]{0,64}$');

-- ── 11. COMPTE PRIVÉ : RÈGLE UNIQUE DE CONFIDENTIALITÉ ─────────────────────
-- Un compte privé ne montre jamais rien au public : ses collections et tier
-- lists « Public » ne sont visibles que de ses amis (et n'apparaissent plus dans
-- « Découvre la communauté »). « Amis » et « Privé » sont inchangés.
-- Prérequis : sections 6 et 7. Idempotent.

CREATE OR REPLACE FUNCTION public.profile_is_public(uid UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE((SELECT is_public FROM profiles WHERE id = uid), TRUE);
$$;
REVOKE ALL ON FUNCTION public.profile_is_public(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.profile_is_public(UUID) TO anon, authenticated;

DROP POLICY IF EXISTS "collections_read_by_visibility" ON collections;
CREATE POLICY "collections_read_by_visibility" ON collections FOR SELECT USING (
     user_id = auth.uid()
  OR (visibility = 'public' AND public.profile_is_public(user_id))
  OR (visibility IN ('public', 'friends') AND public.is_friend_of(user_id))
);

DROP POLICY IF EXISTS "tier_lists_read_by_visibility" ON tier_lists;
CREATE POLICY "tier_lists_read_by_visibility" ON tier_lists FOR SELECT USING (
     user_id = auth.uid()
  OR user_id IS NULL
  OR (visibility = 'public' AND public.profile_is_public(user_id))
  OR (visibility IN ('public', 'friends') AND public.is_friend_of(user_id))
);

-- ── 12. AMITIÉS, BIBLIOTHÈQUES, SCORES DE QUIZ ─────────────────────────────
-- Audit du 8 octobre 2026 :
--  - friendships : un joueur pouvait créer une amitié déjà « accepted » avec
--    n'importe qui, ou accepter lui-même sa demande → contournait le niveau
--    « Amis » des collections / tier lists et l'accès aux bibliothèques.
--  - user_games : « Enable read access for all users » USING (true) → toutes les
--    bibliothèques (comptes privés compris) lisibles sans compte.
--  - quiz_scores : score modifiable après coup ; lisible sans compte.
-- Idempotent. Prérequis : sections 6 et 11 (is_friend_of, profile_is_public).

-- Amitiés : on ne crée qu'une demande en attente ; seul le destinataire l'accepte
DROP POLICY IF EXISTS "Users insert friendships" ON friendships;
DROP POLICY IF EXISTS "friendships_insert_pending" ON friendships;
CREATE POLICY "friendships_insert_pending" ON friendships FOR INSERT
  WITH CHECK (auth.uid() = requester_id AND status = 'pending' AND requester_id <> addressee_id);

DROP POLICY IF EXISTS "Users update own friendships" ON friendships;
DROP POLICY IF EXISTS "friendships_accept_by_addressee" ON friendships;
CREATE POLICY "friendships_accept_by_addressee" ON friendships FOR UPDATE
  USING (auth.uid() = addressee_id) WITH CHECK (auth.uid() = addressee_id);

CREATE OR REPLACE FUNCTION friendships_guard() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.requester_id IS DISTINCT FROM OLD.requester_id
     OR NEW.addressee_id IS DISTINCT FROM OLD.addressee_id THEN
    RAISE EXCEPTION 'friendship participants cannot change';
  END IF;
  IF NEW.status NOT IN ('pending', 'accepted') THEN
    RAISE EXCEPTION 'invalid friendship status';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS friendships_guard ON friendships;
CREATE TRIGGER friendships_guard BEFORE UPDATE ON friendships
  FOR EACH ROW EXECUTE FUNCTION friendships_guard();

-- Bibliothèques : soi, ses amis, ou un compte public pour un joueur connecté
DROP POLICY IF EXISTS "Enable read access for all users" ON user_games;
DROP POLICY IF EXISTS "Authenticated read user_games" ON user_games;
DROP POLICY IF EXISTS "Users can read own games" ON user_games;
DROP POLICY IF EXISTS "user_games_read" ON user_games;
CREATE POLICY "user_games_read" ON user_games FOR SELECT USING (
     user_id = auth.uid()
  OR public.is_friend_of(user_id)
  OR (auth.uid() IS NOT NULL AND public.profile_is_public(user_id))
);

-- Scores de quiz : définitifs une fois écrits, lisibles par les joueurs connectés
DROP POLICY IF EXISTS "quiz_scores_update" ON quiz_scores;
DROP POLICY IF EXISTS "quiz_scores_select" ON quiz_scores;

-- Vérification
SELECT tablename, policyname, cmd, qual, with_check FROM pg_policies
 WHERE schemaname = 'public' AND tablename IN ('friendships', 'user_games', 'quiz_scores')
 ORDER BY tablename, cmd;

-- ── 13. CATALOGUE GAME PASS (écrit par la tâche Vercel cron-gamepass) ────────
-- Une seule ligne (id = 1). Aucune règle d'accès : seul le backend (clé de
-- service) lit et écrit ; l'app passe par /api/gamepass. Idempotent.
CREATE TABLE IF NOT EXISTS gamepass_catalog (
  id         INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  games      JSONB NOT NULL DEFAULT '[]'::jsonb,
  new_games  JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE gamepass_catalog ENABLE ROW LEVEL SECURITY;

-- ── 14. XP ET SCORES DE QUIZ CALCULÉS PAR LE SERVEUR ───────────────────────
-- Avant : l'app décidait des montants et appelait increment_xp(delta), qui
-- ajoutait n'importe quel nombre ; podium, série et scores de quiz étaient
-- calculés et écrits par l'app.
-- Après : chaque gain d'XP passe par une fonction serveur qui le déduit des
-- données en base, une seule fois (table xp_events), et la colonne xp n'est
-- plus modifiable depuis l'app. Idempotent. Prérequis : sections 6 et 12.

CREATE TABLE IF NOT EXISTS xp_events (
  user_id    UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  reason     TEXT NOT NULL,
  ref        TEXT NOT NULL,
  amount     INT  NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, reason, ref)
);
ALTER TABLE xp_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "xp_events_read_own" ON xp_events;
CREATE POLICY "xp_events_read_own" ON xp_events FOR SELECT USING (user_id = auth.uid());

-- Catalogue des succès qui rapportent de l'XP (repris de l'app)
CREATE TABLE IF NOT EXISTS achievement_catalog (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, threshold INT NOT NULL, xp INT NOT NULL
);
ALTER TABLE achievement_catalog ENABLE ROW LEVEL SECURITY;
INSERT INTO achievement_catalog (id, kind, threshold, xp) VALUES
    ('lib_10', 'lib', 10, 30),
    ('lib_25', 'lib', 25, 50),
    ('lib_50', 'lib', 50, 100),
    ('lib_100', 'lib', 100, 160),
    ('lib_250', 'lib', 250, 280),
    ('lib_500', 'lib', 500, 450),
    ('score_5', 'score', 5, 20),
    ('score_20', 'score', 20, 50),
    ('score_50', 'score', 50, 110),
    ('score_100', 'score', 100, 200),
    ('note_3', 'note', 3, 25),
    ('note_15', 'note', 15, 70),
    ('note_50', 'note', 50, 160),
    ('finish_5', 'finish', 5, 40),
    ('finish_25', 'finish', 25, 100),
    ('finish_50', 'finish', 50, 170),
    ('finish_100', 'finish', 100, 280),
    ('finish_250', 'finish', 250, 450),
    ('quiz_1', 'quiz', 1, 15),
    ('quiz_3', 'quiz', 3, 35),
    ('quiz_10', 'quiz', 10, 90),
    ('friend_1', 'friend', 1, 20),
    ('friend_5', 'friend', 5, 50),
    ('friend_10', 'friend', 10, 90),
    ('friend_20', 'friend', 20, 160),
    ('col_1', 'col', 1, 20),
    ('col_3', 'col', 3, 50)
ON CONFLICT (id) DO UPDATE SET kind = EXCLUDED.kind, threshold = EXCLUDED.threshold, xp = EXCLUDED.xp;

-- La colonne xp n'est modifiable que par les fonctions ci-dessous (ou l'admin)
CREATE OR REPLACE FUNCTION profiles_protect_xp() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF COALESCE(current_setting('gs.xp_write', true), '') = 'on'
     OR current_user IN ('postgres', 'supabase_admin')
     OR COALESCE(current_setting('request.jwt.claim.role', true), '') = 'service_role' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.xp := 0;
  ELSIF NEW.xp IS DISTINCT FROM OLD.xp THEN
    NEW.xp := OLD.xp;  -- ignoré sans erreur : les anciennes versions de l'app continuent de fonctionner
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS profiles_protect_xp ON profiles;
CREATE TRIGGER profiles_protect_xp BEFORE INSERT OR UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION profiles_protect_xp();

-- Ajout interne : n'est pas appelable par l'app
CREATE OR REPLACE FUNCTION _xp_add(uid UUID, p_reason TEXT, p_ref TEXT, amt INT) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n INT;
BEGIN
  INSERT INTO xp_events (user_id, reason, ref, amount) VALUES (uid, p_reason, p_ref, amt)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n = 0 OR amt = 0 THEN RETURN 0; END IF;
  PERFORM set_config('gs.xp_write', 'on', true);
  UPDATE profiles SET xp = COALESCE(xp, 0) + amt WHERE id = uid;
  PERFORM set_config('gs.xp_write', 'off', true);
  RETURN amt;
END $$;
REVOKE ALL ON FUNCTION _xp_add(UUID, TEXT, TEXT, INT) FROM PUBLIC, anon, authenticated;

-- XP par jeu (note 5, vibe 5, avis 15) et par quiz terminé (5), déduite des données.
-- Plafond : 60 attributions par type sur 24 h glissantes (anti-farm de faux jeux).
CREATE OR REPLACE FUNCTION sync_xp() RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid(); r RECORD; total INT; cap CONSTANT INT := 60;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  FOR r IN
    SELECT 'score' AS reason, game_id AS ref, 5 AS amt FROM user_games
     WHERE user_id = uid AND COALESCE(score, 0) > 0
    UNION ALL
    SELECT 'vibe', game_id, 5 FROM user_games
     WHERE user_id = uid AND vibe IS NOT NULL AND vibe::text NOT IN ('', '[]', 'null', '""', '{}')
    UNION ALL
    SELECT 'note', game_id, 15 FROM user_games
     WHERE user_id = uid AND COALESCE(btrim(notes), '') <> ''
    UNION ALL
    SELECT DISTINCT 'quiz', quiz_id, 5 FROM quiz_scores WHERE user_id = uid
  LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM xp_events e WHERE e.user_id = uid AND e.reason = r.reason AND e.ref = r.ref);
    CONTINUE WHEN (SELECT count(*) FROM xp_events e WHERE e.user_id = uid AND e.reason = r.reason
                     AND e.amount > 0 AND e.created_at > now() - interval '24 hours') >= cap;
    PERFORM _xp_add(uid, r.reason, r.ref, r.amt);
  END LOOP;
  SELECT xp INTO total FROM profiles WHERE id = uid;
  RETURN COALESCE(total, 0);
END $$;

-- Succès : payé une seule fois, et seulement si la condition est vraie en base
CREATE OR REPLACE FUNCTION award_achievement(p_ach TEXT) RETURNS INT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid UUID := auth.uid(); a achievement_catalog; cnt INT; total INT;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
  SELECT * INTO a FROM achievement_catalog WHERE id = p_ach;
  IF FOUND THEN
    cnt := CASE a.kind
      WHEN 'lib'    THEN (SELECT count(*) FROM user_games WHERE user_id = uid)
      WHEN 'score'  THEN (SELECT count(*) FROM user_games WHERE user_id = uid AND COALESCE(score, 0) > 0)
      WHEN 'note'   THEN (SELECT count(*) FROM user_games WHERE user_id = uid AND COALESCE(btrim(notes), '') <> '')
      WHEN 'finish' THEN (SELECT count(*) FROM user_games WHERE user_id = uid AND status IN ('finished', 'platine'))
      WHEN 'quiz'   THEN (SELECT count(DISTINCT quiz_id) FROM quiz_scores WHERE user_id = uid)
      WHEN 'friend' THEN (SELECT count(*) FROM friendships WHERE status = 'accepted' AND (requester_id = uid OR addressee_id = uid))
      WHEN 'col'    THEN (SELECT count(*) FROM collections WHERE user_id = uid)
      ELSE 0 END;
    IF cnt >= a.threshold THEN PERFORM _xp_add(uid, 'achievement', a.id, a.xp); END IF;
  END IF;
  SELECT xp INTO total FROM profiles WHERE id = uid;
  RETURN COALESCE(total, 0);
END $$;

-- Podium du quiz d'hier (parmi soi et ses amis) + série de 7 jours complets.
-- Jour = jour UTC, comme dans l'app ; un jour « complet » = 4 quiz différents.
CREATE OR REPLACE FUNCTION claim_quiz_rewards() RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  uid UUID := auth.uid();
  today INT := floor(extract(epoch FROM now()) / 86400)::INT;
  yday INT := today - 1;
  mine INT; n INT; rnk INT; amt INT; rank_xp INT := 0; streak_xp INT := 0; d INT; ok BOOLEAN; total INT;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;

  SELECT sum(score) INTO mine FROM quiz_scores WHERE user_id = uid AND day_index = yday;
  IF mine IS NOT NULL THEN
    WITH circle AS (
      SELECT uid AS id
      UNION SELECT CASE WHEN requester_id = uid THEN addressee_id ELSE requester_id END
        FROM friendships WHERE status = 'accepted' AND (requester_id = uid OR addressee_id = uid)
    ), totals AS (
      SELECT q.user_id, sum(q.score) AS pts FROM quiz_scores q JOIN circle c ON c.id = q.user_id
       WHERE q.day_index = yday GROUP BY q.user_id
    )
    SELECT count(*), 1 + count(*) FILTER (WHERE pts > mine) INTO n, rnk FROM totals;
    amt := CASE WHEN n >= 2 AND rnk <= 3 THEN (ARRAY[150, 50, 25])[rnk] ELSE 5 END;
    rank_xp := _xp_add(uid, 'quiz_rank', yday::TEXT, amt);
  END IF;

  -- Série : 7 jours complets consécutifs se terminant aujourd'hui ou hier,
  -- sans chevaucher une série déjà payée
  FOREACH d IN ARRAY ARRAY[today, yday] LOOP
    SELECT bool_and(c >= 4) AND count(*) = 7 INTO ok FROM (
      SELECT g AS day, (SELECT count(DISTINCT quiz_id) FROM quiz_scores
                         WHERE user_id = uid AND day_index = g) AS c
        FROM generate_series(d - 6, d) g) s;
    IF ok AND NOT EXISTS (SELECT 1 FROM xp_events WHERE user_id = uid AND reason = 'quiz_streak'
                            AND ref ~ '^[0-9]+$' AND ref::INT BETWEEN d - 6 AND d) THEN
      streak_xp := streak_xp + _xp_add(uid, 'quiz_streak', d::TEXT, 100);
    END IF;
  END LOOP;

  SELECT xp INTO total FROM profiles WHERE id = uid;
  RETURN jsonb_build_object('rank', rnk, 'participants', COALESCE(n, 0), 'rank_xp', rank_xp,
                            'streak_xp', streak_xp, 'xp', COALESCE(total, 0));
END $$;

DROP FUNCTION IF EXISTS submit_quiz_score(TEXT, BOOLEAN[]);
-- Score de quiz : calculé à partir des réponses, pour le jour courant, une seule fois.
-- (La colonne answers peut être jsonb ou boolean[] selon l'historique de la base.)
DO $do$
DECLARE t TEXT;
BEGIN
  SELECT data_type INTO t FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'quiz_scores' AND column_name = 'answers';
  EXECUTE format($f$
    CREATE OR REPLACE FUNCTION submit_quiz_score(p_quiz_id TEXT, p_answers BOOLEAN[], p_day INT DEFAULT NULL) RETURNS INT
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $b$
    DECLARE uid UUID := auth.uid(); s INT; n INT := COALESCE(array_length(p_answers, 1), 0);
            today INT := floor(extract(epoch FROM now()) / 86400)::INT; d INT := COALESCE(p_day, today);
    BEGIN
      IF uid IS NULL THEN RAISE EXCEPTION 'not signed in'; END IF;
      IF p_quiz_id !~ '^[A-Za-z0-9_-]{1,64}$' OR n NOT BETWEEN 1 AND 30 THEN RAISE EXCEPTION 'invalid quiz'; END IF;
      -- aujourd'hui, ou hier pour un quiz mis en pause puis finalisé au lancement suivant
      IF d NOT BETWEEN today - 1 AND today THEN RAISE EXCEPTION 'invalid day'; END IF;
      SELECT count(*) INTO s FROM unnest(p_answers) a WHERE a;
      INSERT INTO quiz_scores (user_id, quiz_id, score, total, day_index, answers)
      VALUES (uid, p_quiz_id, s, n, d, %s)
      ON CONFLICT (user_id, quiz_id, day_index) DO NOTHING;
      -- score réellement enregistré (le premier du jour), pas celui de cette tentative
      SELECT score INTO s FROM quiz_scores
       WHERE user_id = uid AND quiz_id = p_quiz_id AND day_index = d;
      RETURN s;
    END $b$;$f$,
    CASE WHEN t IN ('json', 'jsonb') THEN 'to_jsonb(p_answers)' ELSE 'p_answers' END);
END $do$;

-- Plus aucune écriture directe des scores par l'app
DROP POLICY IF EXISTS "quiz_scores_insert" ON quiz_scores;
DROP POLICY IF EXISTS "Users insert quiz_scores" ON quiz_scores;

-- Fonctions appelables par les joueurs connectés uniquement
REVOKE ALL ON FUNCTION sync_xp() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION award_achievement(TEXT) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION claim_quiz_rewards() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION submit_quiz_score(TEXT, BOOLEAN[], INT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION sync_xp() TO authenticated;
GRANT EXECUTE ON FUNCTION award_achievement(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION claim_quiz_rewards() TO authenticated;
GRANT EXECUTE ON FUNCTION submit_quiz_score(TEXT, BOOLEAN[], INT) TO authenticated;

-- L'ancienne fonction qui ajoutait un montant libre disparaît
DO $do$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace ns ON ns.oid = p.pronamespace
            WHERE ns.nspname = 'public' AND p.proname = 'increment_xp'
  LOOP EXECUTE format('DROP FUNCTION %s', f.sig); END LOOP;
END $do$;

-- Reprise de l'existant : ce qui a déjà été payé est marqué (montant 0) pour ne
-- jamais l'être deux fois. Joueurs dont la reprise d'XP a déjà tourné
-- (xp_backfilled) : jeux notés / vibes / avis / quiz. Tous : succès, podiums et
-- séries déjà enregistrés dans profiles.achievements.
INSERT INTO xp_events (user_id, reason, ref, amount)
SELECT ug.user_id, x.reason, ug.game_id, 0 FROM user_games ug
  JOIN profiles p ON p.id = ug.user_id AND COALESCE(p.xp_backfilled, FALSE)
  CROSS JOIN LATERAL (VALUES
    ('score', COALESCE(ug.score, 0) > 0),
    ('vibe',  ug.vibe IS NOT NULL AND ug.vibe::text NOT IN ('', '[]', 'null', '""', '{}')),
    ('note',  COALESCE(btrim(ug.notes), '') <> '')) AS x(reason, ok)
 WHERE x.ok
ON CONFLICT DO NOTHING;

INSERT INTO xp_events (user_id, reason, ref, amount)
SELECT DISTINCT q.user_id, 'quiz', q.quiz_id, 0 FROM quiz_scores q
  JOIN profiles p ON p.id = q.user_id AND COALESCE(p.xp_backfilled, FALSE)
ON CONFLICT DO NOTHING;

INSERT INTO xp_events (user_id, reason, ref, amount)
SELECT p.id,
       CASE WHEN k LIKE 'xp_qrank_%' THEN 'quiz_rank' WHEN k LIKE 'xp_qstreak_%' THEN 'quiz_streak' ELSE 'achievement' END,
       CASE WHEN k LIKE 'xp_q%' THEN regexp_replace(k, '^xp_q(rank|streak)_', '') ELSE k END,
       0
  FROM profiles p, jsonb_array_elements_text(COALESCE(to_jsonb(p.achievements), '[]'::jsonb)) AS k
 WHERE k ~ '^xp_q(rank|streak)_[0-9]+$' OR k IN (SELECT id FROM achievement_catalog)
ON CONFLICT DO NOTHING;

-- ── 15. RÉACTIONS, ABONNEMENTS, PROFILS PUBLICS, GAME PASS « QUITTE BIENTÔT » ──
-- Idempotent. Prérequis : sections 6, 11, 12, 13.

-- Abonnements : suivre un compte public sans amitié réciproque
CREATE TABLE IF NOT EXISTS follows (
  follower_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  followee_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (follower_id, followee_id),
  CHECK (follower_id <> followee_id)
);
ALTER TABLE follows ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS follows_followee_idx ON follows (followee_id);

CREATE OR REPLACE FUNCTION public.is_following(other UUID) RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM follows WHERE follower_id = auth.uid() AND followee_id = other);
$$;
REVOKE ALL ON FUNCTION public.is_following(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_following(UUID) TO anon, authenticated;

DROP POLICY IF EXISTS "follows_read" ON follows;
CREATE POLICY "follows_read" ON follows FOR SELECT USING (
  follower_id = auth.uid() OR followee_id = auth.uid() OR public.profile_is_public(followee_id));
DROP POLICY IF EXISTS "follows_insert_own" ON follows;
CREATE POLICY "follows_insert_own" ON follows FOR INSERT
  WITH CHECK (follower_id = auth.uid() AND public.profile_is_public(followee_id));
DROP POLICY IF EXISTS "follows_delete_own" ON follows;
CREATE POLICY "follows_delete_own" ON follows FOR DELETE USING (follower_id = auth.uid());

-- Réactions à l'avis d'un joueur sur un jeu (une par personne, modifiable)
CREATE TABLE IF NOT EXISTS game_reactions (
  reactor_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  owner_id   UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  game_id    TEXT NOT NULL CHECK (game_id ~ '^[A-Za-z0-9_:.-]{1,100}$'),
  reaction   TEXT NOT NULL CHECK (reaction IN ('agree', 'disagree', 'want', 'gg')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (reactor_id, owner_id, game_id),
  CHECK (reactor_id <> owner_id)
);
ALTER TABLE game_reactions ENABLE ROW LEVEL SECURITY;
CREATE INDEX IF NOT EXISTS game_reactions_owner_idx ON game_reactions (owner_id, game_id);

-- Visible par l'auteur, le propriétaire, ses amis et ses abonnés
DROP POLICY IF EXISTS "reactions_read" ON game_reactions;
CREATE POLICY "reactions_read" ON game_reactions FOR SELECT USING (
     reactor_id = auth.uid() OR owner_id = auth.uid()
  OR public.is_friend_of(owner_id) OR public.is_following(owner_id));
-- On ne réagit qu'à un jeu réellement présent chez un ami (ou un compte public suivi)
DROP POLICY IF EXISTS "reactions_write_own" ON game_reactions;
CREATE POLICY "reactions_write_own" ON game_reactions FOR INSERT WITH CHECK (
  reactor_id = auth.uid()
  AND (public.is_friend_of(owner_id) OR (public.is_following(owner_id) AND public.profile_is_public(owner_id)))
  AND EXISTS (SELECT 1 FROM user_games ug WHERE ug.user_id = owner_id AND ug.game_id = game_reactions.game_id));
DROP POLICY IF EXISTS "reactions_update_own" ON game_reactions;
CREATE POLICY "reactions_update_own" ON game_reactions FOR UPDATE
  USING (reactor_id = auth.uid()) WITH CHECK (reactor_id = auth.uid());
DROP POLICY IF EXISTS "reactions_delete_own" ON game_reactions;
CREATE POLICY "reactions_delete_own" ON game_reactions FOR DELETE USING (reactor_id = auth.uid());

-- Profils publics partageables (/u/pseudo) : la bibliothèque d'un compte public
-- devient lisible sans compte. Les comptes privés restent limités à leurs amis.
DROP POLICY IF EXISTS "user_games_read" ON user_games;
CREATE POLICY "user_games_read" ON user_games FOR SELECT USING (
     user_id = auth.uid()
  OR public.is_friend_of(user_id)
  OR public.profile_is_public(user_id)
);

-- Game Pass : jeux qui quittent bientôt le service
ALTER TABLE gamepass_catalog ADD COLUMN IF NOT EXISTS leaving JSONB NOT NULL DEFAULT '[]'::jsonb;
