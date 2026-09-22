# Morning Tape

A daily eight-round markets game with Google sign-in (restricted to @iu.edu), a shared leaderboard, and an admin page for posting each day's puzzle.

- `public/index.html` is the game
- `public/admin.html` is where you paste and publish each morning's puzzle
- `public/config.js` holds your Supabase keys
- `supabase/schema.sql` sets up the database, scoring and security
- `puzzles/` keeps a copy of each puzzle JSON (optional, but handy as an archive)

Answers never reach the browser before a player locks in. Scoring and the round timer both run in the database, so the leaderboard can't be gamed from dev tools.

## Setup (about 45 minutes, all free tiers)

### 1. Supabase
1. Create a project at supabase.com.
2. Open **SQL Editor**, paste all of `supabase/schema.sql`, and run it.
3. Go to **Project Settings > API** and copy the Project URL and the `anon` public key into `public/config.js`.

### 2. Google sign-in
1. In Google Cloud Console, create a project, then **APIs & Services > Credentials > Create credentials > OAuth client ID** (type: Web application). You'll be asked to set up the consent screen first; choose External and fill in the basics.
2. Under **Authorized redirect URIs**, add `https://YOUR-PROJECT.supabase.co/auth/v1/callback`.
3. In Supabase, go to **Authentication > Providers > Google**, turn it on, and paste the client ID and secret.

### 3. Deploy on Vercel
1. Push this folder to a GitHub repo.
2. In Vercel, **Add New > Project**, import the repo, set Framework to **Other** and Output Directory to `public`, then deploy.
3. Back in Supabase, **Authentication > URL Configuration**: set Site URL to your Vercel URL and add `https://your-site.vercel.app/**` to Redirect URLs. Add your custom domain too if you buy one.

### 4. Make yourself admin
Sign in on the live site once, then run this in the Supabase SQL Editor:

```sql
insert into public.admins (user_id)
select id from auth.users where email = 'you@iu.edu';
```

### 5. Post the first puzzle
Open `/admin.html`, paste `puzzles/2026-09-22.json` (or a fresh one), click **Check puzzle**, then **Publish**. The game shows the latest puzzle dated today or earlier, in Indiana time, so you can also post the night before.

## Daily routine
1. In the Claude project, say "load today's puzzle for the website."
2. Copy the JSON Claude gives you.
3. Paste it into `/admin.html`, check, publish.

Re-publishing the same date overwrites that puzzle. Runs already played keep their scores, so fix mistakes before classmates start playing.

## Puzzle format

```json
{
  "date": "2026-09-23",
  "title": "Short headline for the day",
  "blurb": "One sentence on what the tape covers.",
  "rounds": [
    { "type": "choice", "kind": "Headline match", "prompt": "…", "clue": "optional",
      "options": ["A", "B", "C", "D"], "answer": 1, "explain": "…" },
    { "type": "number", "kind": "Guess the move", "prompt": "…",
      "min": -5, "max": 20, "step": 0.5, "start": 5, "unit": "%", "signed": true,
      "answer": 10, "scale": 3, "explain": "…" },
    { "type": "year", "kind": "Guess the year", "prompt": "…",
      "min": 2005, "max": 2025, "start": 2015, "answer": 2022, "window": 8,
      "chart": { "type": "line", "points": [4766, 4516], "xLabels": ["", "Jan"] },
      "explain": "…" }
  ]
}
```

- `answer` for choice rounds is the option's position, starting at 0.
- `scale` controls partial credit on number rounds (smaller is stricter).
- `window` is how many years off still earns points on year rounds.
- Any round can carry a `chart`: `{"type":"bar","unit":"%","bars":[{"label":"A","value":1.5}]}` or a line chart as above.

## Changing the allowed domain
Edit `ALLOWED_DOMAIN` in `config.js` and the `'%@iu.edu'` pattern in `is_allowed()` in `schema.sql`, then re-run that function in the SQL Editor.

## Data note
Don't use FactSet or S&P Capital IQ data in puzzles on a public site; university licenses generally prohibit redistribution. Public news and index levels are fine.
