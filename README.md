# Forgetful research sprite

A personal agent for [Hacksgiving 2026](https://fly.io/hacksgiving/): a public question goes in, a Tavily or Firecrawl lookup is proxied through a Sprites connector, notes stay on the Sprite at `/notes/brief.md`, and “Forget this.” wipes the notes and files a deletion receipt (removed paths, leftover hash, timestamp) via a GitHub or S3 connector — not the notes themselves.

Live demo: [hs26-forgetful-b4at6.sprites.app](https://hs26-forgetful-b4at6.sprites.app). The Sprite environment holds no provider keys. Ask and Forget need the connectors below to be granted in the Fly control plane.

Byline: Kent G Lau, PhD. No KYC. No retained PII.

## Connectors to grant

- **Tavily** (preferred lookup) or **Firecrawl** (fallback) — bring-your-own key in the Fly control plane.
- **GitHub** (OAuth) or **S3-compatible Object Store** — receipt store only.

Do **not** paste provider keys into the Sprite env, this repo, or logs. Only `CONNECTOR_*_ID` values (which are not secrets) belong on the Sprite, plus `SPRITE_ROOT=/` and `GATEWAY_BASE=https://api.sprites.dev`.

## Local demo (mock gateway)

The local e2e and UI talk to `scripts/mock_gateway.py`, which speaks the same URL shapes as `https://api.sprites.dev` and holds only fixtures — no provider keys.

```bash
./scripts/e2e.sh --ci
./scripts/serve.sh    # then open the printed URL
```

`./scripts/e2e.sh` has a menu, per-stage isolation, `--ci` / `--all`, `--stage N`, a pass/fail summary, a saved log under `logs/e2e-*`, and teardown as the last step. Logs are kept across teardown.

## Standing this up on a real Fly Sprite

1. Install the Sprites CLI (separate from `flyctl`):

   ```bash
   curl -fsSL https://sprites.dev/install.sh | sh
   # or install the checksum-verified linux-amd64 binary from
   # https://docs.fly.io/sprites/cli/installation
   sprite --version
   ```

2. Sign in with the existing Fly account `kentydotcom@gmail.com`:

   ```bash
   sprite login
   ```

   Approve the CLI in the browser. `sprite list` should then work. Creating Sprites stays on the Fly Free plan; do not upsize a machine without asking.

3. Create one Sprite, for example `hs26-forgetful`:

   ```bash
   sprite create hs26-forgetful
   sprite use hs26-forgetful
   ```

4. In the Fly dashboard: organization **kentydotcom** → **Sprites** → **Connectors** → **Add connector**. Default-deny; then grant this Sprite by name prefix (`hs26-`) or a label.

   OAuth (GitHub) opens a consent screen. Bring-your-own-key providers (Tavily, Firecrawl, S3) take the key in the **control plane**, not on the Sprite.

5. Copy the project onto the Sprite (no `.env` with secrets). Set `SPRITE_ROOT=/` so notes land at `/notes`. Set `GATEWAY_BASE=https://api.sprites.dev` and the `CONNECTOR_*_ID` values from the connector detail page (IDs are not secrets). Leave provider tokens unset.

6. Optional: `sprite url update --auth public` only when you want the demo URL open. The default Sprite URL is authenticated. The live demo above is already public.

Until those grants exist, `./scripts/e2e.sh --ci` is the checkable local demo, and the live site still shows the UI and a clean environment report.

## What this is not

- Does not contain the Fe contest submission code or any leftover gate password.
- Does not contain provider keys. Tokens stay in the Fly Sprites control plane.

## License

Copyright (c) 2026 Kent G Lau, PhD. See `LICENSE`.
