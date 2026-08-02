# Security Policy

This repository is public. The landing page contact and signature are intentional public content, but member names, order history, room IDs, Supabase project details, and screenshots containing real data must not be committed.

## Rules

- The Supabase **publishable/anon** key and project URL MAY be committed in `CONFIG` on public `main` — they are not secrets. This is safe **only while strict RLS is enforced**: no anonymous direct `SELECT` on `orders`/`sessions`/`cells`, all private access through the narrow RPCs in `db-setup.sql`, and signup turned **OFF**. Never commit the **secret / service_role** key.
- Store real member lists only in Supabase, never in source files, docs, screenshots, or guides.
- Do not allow anonymous direct `SELECT` on `orders`, `sessions`, or `cells`.
- Access private app data only through narrow RPC functions that require the room/cell ID.
- Use fake data for demos, examples, and screenshots.
- Do not commit local tool settings such as `.claude/`.

## If Data Was Exposed

1. Revoke direct table access in Supabase and deploy the secure RPC SQL from `SETUP.md`.
2. Rotate the Supabase publishable key.
3. Remove exposed data from the current tree and rewrite public Git history if necessary.
4. Verify the deployed GitHub Pages HTML no longer contains exposed values.
5. Treat any previously public member/order data as already disclosed.

## Analytics (PostHog)

The app sends product analytics to PostHog (`us.i.posthog.com`). What is collected, and what is
deliberately not:

**Collected** — autocapture (clicks, pageviews), session replay, and 16 named product events
(`order_submitted`, `game_started`, `write_failed`, …). Event properties describe the *shape* of
an action: option counts, whether a note exists and how long it is, drink/skip counts, game kind,
duration. Members are identified by the app-generated member id only, and only after entering a
cell — anonymous visitors get no person profile (`person_profiles: 'identified_only'`).

**Never collected** — member names, note contents, custom menu text, or any free-text a user
typed. Session replay runs with `maskAllInputs: true`, so every input value is masked before it
leaves the browser.

**Known limitation** — names *already rendered on screen* (roster lists, result banners) are
visible in session replays; only inputs are masked. Masking them too would leave the replay a
field of grey boxes and defeat its purpose. Either add `data-pii` to those elements (it is already
wired to `maskTextSelector`) or turn replay off with `disable_session_recording: true`.

Tell the people using your cell that their interactions are recorded. The data lives in a
third-party service under the project owner's account.

## Reporting

Open a private security advisory on GitHub or contact the repository owner through the public landing page.
