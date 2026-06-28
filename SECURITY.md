# Security Policy

This repository is public. The landing page contact and signature are intentional public content, but member names, order history, room IDs, Supabase project details, and screenshots containing real data must not be committed.

## Rules

- Keep `CONFIG.SUPABASE_URL` and `CONFIG.SUPABASE_ANON_KEY` empty on the public `main` branch.
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

## Reporting

Open a private security advisory on GitHub or contact the repository owner through the public landing page.
