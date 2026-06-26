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
