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
