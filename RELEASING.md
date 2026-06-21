# Releasing & Maintenance

This project is built to maintain and release itself with as little manual work
as possible. This document explains the pipeline and the **one-time setup** you
need to do.

## How the automation works

```
   you push Conventional Commits to `main`
                 │
                 ▼
   ┌───────────────────────────────┐     CI (ci.yml) runs on every push/PR:
   │ release-please (release-please.yml)  │       • mix test on an Elixir/OTP matrix
   │  keeps an open "release PR"   │       • differential parity vs supported PHP
   │  that bumps mix.exs + CHANGELOG│      • mix format check
   └───────────────────────────────┘
                 │  you review + merge the release PR
                 ▼
   release-please tags vX.Y.Z + creates a GitHub Release
                 │
                 ▼
   ┌───────────────────────────────┐
   │ provenance (_release-build.yml)│  isolated VM, NO Hex key:
   │   build → attest → upload tar │    build + sign provenance (SLSA L3)
   │ publish (release-please.yml)   │  inline `hex-publish` env (key here only):
   │   verify → POST exact tar     │    upload the attested bytes; docs separately
   └───────────────────────────────┘
                 │
                 ▼
            hex.pm + hexdocs.pm
```

Separately, **`drift.yml`** runs weekly and fails if PHP changes the upstream
regex (see the bottom of this doc).

**Versioning is automatic.** You never edit the version by hand. release-please
derives the next version from your commit messages:

| Commit prefix | Effect (while < 1.0.0) |
| --- | --- |
| `fix: …` | patch bump (0.1.0 → 0.1.1) |
| `feat: …` | minor bump (0.1.0 → 0.2.0) |
| `feat!: …` or a `BREAKING CHANGE:` footer | minor bump pre-1.0 (and major once ≥ 1.0) |
| `docs:`, `chore:`, `test:`, `refactor:`, `ci:` | no release on their own |

Use [Conventional Commits](https://www.conventionalcommits.org/). The first
release (`0.1.0`) is cut automatically the first time release-please sees a
`feat:`/`fix:` history on `main`.

---

## One-time setup

Do these once. Steps 1–4 are required; step 5 is recommended.

### 1. Create the GitHub repository and push

```bash
git init
git branch -M main
git config user.name  "Daniel Dent"
git config user.email "DanielDent@users.noreply.github.com"
git add -A
git commit -m "feat: initial release of elixir_php_email_validator

Bug-for-bug compatible port of PHP filter_var(FILTER_VALIDATE_EMAIL),
with a differential test suite and an upstream drift detector."
gh repo create DanielDent/elixir_php_email_validator --public --source=. --remote=origin --push
```

> Everything uses one canonical name: the GitHub repo, the Hex package, the OTP
> app (`:elixir_php_email_validator`), the directory, and the module
> (`ElixirPhpEmailValidator`).

### 2. Authenticate to Hex and create a least-privilege CI key

On your own machine (the Hex CLI uses an OAuth device-flow login — a browser
prompt, no password stored):

```bash
mix hex.user auth                              # one-time interactive login
mix hex.user key generate \
  --key-name elixir_php_email_validator-ci \
  --permission api:write                       # least privilege needed to publish
```

Copy the key it prints **once**. `api:write` is the minimum permission Hex
offers for publishing (Hex API keys are account-scoped — they can't yet be
scoped to a single package), which is exactly why the next step locks it inside
a protected environment.

### 3. Store the key in a protected GitHub Environment

On GitHub: **Settings → Environments → New environment**, name it exactly
**`hex-publish`** (the workflow references this name).

- Under **Environment secrets**, add `HEX_API_KEY` = the key from step 2.
- Under **Deployment branches and tags**, choose **Selected branches and tags**
  and add `main` (and optionally the tag pattern `v*`). This guarantees the
  secret is only ever available to the real release job running off `main` —
  never to a pull request, a fork, or any other workflow.

Because the secret lives in an environment (not a plain repo secret), it is
unavailable to PR/fork builds, and GitHub masks it in all logs. It is never
publicly exposed.

> Optional extra gate: add yourself as a **Required reviewer** on the
> environment if you want a manual "approve deployment" click before each
> publish. Since you already gate by merging the release PR, this is usually
> redundant — leave it off for one-click releases.

### 4. Protect `main` and enable auto-merge

- **Settings → Branches → Add rule** for `main`: require pull requests and
  require the **CI** status checks to pass. Require status checks, but do **not**
  require pull-request approvals — that way Dependabot's safe PRs can auto-merge
  on green, while you stay the one who deliberately merges (i.e. "approves") each
  release PR.
- **Settings → General → Pull Requests → Allow auto-merge.** This is what lets
  the Dependabot auto-merge workflow queue a merge that completes once CI passes.

With this, your routine manual surface is: **merge release PRs** (the release),
and the occasional **major GitHub Actions bump** (everything else Dependabot
proposes auto-merges after its cooldown + CI).

### 5. Turn on 2FA for your Hex account (recommended)

`mix hex.user` / the Hex website → enable two-factor auth. With the CI key
locked in the environment and 2FA on your account, a leaked key alone cannot be
used to take over the package interactively.

---

## Cutting a release (the normal flow)

1. Merge feature/fix PRs to `main` using Conventional Commit messages.
2. release-please opens/updates a **"chore(main): release X.Y.Z"** PR. Review the
   proposed version bump and generated CHANGELOG.
3. **Merge it.** That tags `vX.Y.Z`, creates the GitHub Release, and the
   `publish` job pushes the package + docs to Hex automatically.

That's the entire release process: merge a PR.

### Manual / emergency publish

If you ever need to publish the current `main` without going through a release
PR, run the **Release** workflow via **Actions → Release → Run workflow**
(`workflow_dispatch`). It runs the same gated `publish` job.

---

## When Hex ships OIDC "trusted publishing"

Hex.pm has trusted publishing (keyless OIDC, no stored credential) on its
roadmap but it is **not generally available as of June 2026**. When it ships:

1. On hex.pm, configure a **trusted publisher** for `elixir_php_email_validator`:
   repository `DanielDent/elixir_php_email_validator`, environment `hex-publish`,
   and the workflow that runs `mix hex.publish` — the top-level `release-please.yml`
   (the inline `publish` job runs the publish, so its `job_workflow_ref` is
   `release-please.yml`, not the reusable `_release-build.yml`).
2. In `.github/workflows/release-please.yml`, remove the `HEX_API_KEY` env line from
   the `publish` step and add `id-token: write` to the `publish` job's `permissions:`.
3. Delete the `HEX_API_KEY` environment secret and revoke the key
   (`mix hex.user key revoke --key-name elixir_php_email_validator-ci`).

No other restructuring is needed — the publish path is already isolated for this.

---

## Supply-chain notes

**Every** third-party action across the pipeline (CI, drift, release) is pinned
to an immutable **commit SHA** with a `# vX.Y.Z` comment, so a moved tag can never
swap in malicious code — most critically on the `publish` job, the only one that
can see the Hex credential. Dependabot reads the version from the comment and
bumps the SHA and the comment together, so pinning adds no manual upkeep.

The GitHub-hosted **runner image** is intentionally left as `ubuntu-latest`. The
pinning policy here is "pin only what Dependabot keeps current on a cooldown," and
**Dependabot does not manage `runs-on` labels** — so pinning to a specific LTS
(`ubuntu-24.04`) would just create a manual, un-cooled pin that goes stale, the
opposite of the goal. `ubuntu-latest` stays auto-current via GitHub's gradual
`-latest` migration; the runner is GitHub-built and already inside the trust
boundary you accept by using GitHub Actions, so it is not a third-party
supply-chain surface (unlike actions, where SHA-pinning guards a *different*
boundary). If you ever want the build environment itself **pinned _and_
auto-updated on a cooldown**, note that a `container:` digest placed directly in a
workflow is **not** Dependabot-managed (Dependabot tracks `uses:` actions and
Dockerfiles / k8s manifests — not workflow `container:`/`services:` keys; see
dependabot-core #5819). The only Dependabot-cooled path is a **builder Dockerfile**
(`FROM image:tag@sha256:…`, tracked by `package-ecosystem: docker`) whose image the
release job runs in — ideally mirrored to a registry you control. That's the right
tool for an infra/release repo with audit requirements; for this
zero-runtime-dependency library it is overkill.

Dependabot keeps those pins (and the dev-only `mix` deps) current, but on a
**cooldown** (`.github/dependabot.yml`): it waits 7 days (30 for majors) after a
release before opening the bump PR, giving the community time to catch a
malicious release first. Known-CVE security updates bypass the cooldown.

By the time a Dependabot PR appears it has already aged, so the auto-merge
workflow (`.github/workflows/dependabot-automerge.yml`) merges the safe ones
once CI passes — any dev/test dependency, and any non-major GitHub Actions bump.
Only a **major** GitHub Actions bump (a release-infra change) waits for your
review.

### Build provenance (attestation)

The `provenance` reusable workflow (`_release-build.yml`) builds the tarball with
`mix hex.build`, then `actions/attest-build-provenance` records a **Sigstore-signed
[SLSA](https://slsa.dev) Build L3 provenance attestation** — keyless, via the
public-good Fulcio CA and the Rekor transparency log, with no stored signing key —
and uploads that exact tarball as an artifact. The inline `publish` job `needs:` the
`provenance` job (a failed attestation blocks the publish, fail-closed), then
**downloads that tarball, re-verifies it against the attestation, and POSTs those
exact bytes to Hex's release API**. So the published package *is* the attested
package by construction — no rebuild, no reproducibility assumption. (`mix hex.publish`
always rebuilds the tarball in memory, so it is not used for the package; docs are a
separate, unattested tarball published on their own.) Anyone can verify a release
(needs the `gh` CLI):

```bash
mix hex.package fetch elixir_php_email_validator VERSION --output epev.tar
gh attestation verify epev.tar \
  --repo DanielDent/elixir_php_email_validator \
  --signer-workflow DanielDent/elixir_php_email_validator/.github/workflows/_release-build.yml
```

The attestation lives in GitHub's attestation store + Rekor, **not** on Hex.pm
(Hex serves no provenance yet — it's on the
[EEF roadmap](https://security.erlef.org/aegis/roadmap/hex-build-provenance.html)),
so verification is out-of-band and `mix deps.get` does not check it. Because the
publish job uploads the **exact attested tarball**, the bytes Hex serves are the
attested bytes byte-for-byte, so `gh attestation verify` on a tarball fetched from
Hex passes. (Hex builds are deterministic too — verified: two `mix hex.build` runs
give the same sha256 — but we don't rely on that; we ship the attested file.)

### SLSA Build L3 (how the attestation is isolated)

L3 adds two requirements over L2: builds are **isolated** (each GitHub-hosted job
is a fresh ephemeral VM — always true here) and the provenance signing material is
**unforgeable**, i.e. inaccessible to the user-defined build steps. An *inline*
publish job is only L2, because `mix hex.build`/`mix test` and the attest step
would share one runner VM and its OIDC signing identity — a compromised build step
could in principle mint that identity and forge provenance.

So **build + attest** live in a **reusable workflow**
(`.github/workflows/_release-build.yml`), invoked by the `provenance` job in
`release-please.yml` via `jobs.<id>.uses:`. The reusable workflow runs on its own
isolated, ephemeral VM the caller's steps can't reach, so the signing identity is
unreachable from the build steps — GitHub's documented path to Build L3. It stays
compatible with the same-run requirement above (a reusable workflow runs inside the
same triggering run, not a separately-dispatched one). Because the signer is the
reusable workflow, consumers verify with `--signer-workflow …/_release-build.yml`
(see the package README's verification section).

**Publishing is kept separate, inline**, in the `publish` job — the only job that
declares the `hex-publish` environment, where its `HEX_API_KEY` secret + the
"restrict to `main`" rule attach. This is deliberate: an environment secret does
**not** resolve inside a reusable workflow unless the caller forwards it with
`secrets: inherit`, which would push the key into the build/attest VM. Keeping
publish inline keeps the key **out** of that VM entirely (the reusable workflow
holds no credential) while preserving the L3 attestation. The package itself is
uploaded by a raw API `POST` of the exact attested bytes, so **no dependency code
runs beside the key** for the package; the only step that does is the separate,
unattested **docs** publish (`mix hex.publish docs`, which runs `ex_doc`). That
residual (a build-time dependency reading the key) is inherent to any stored-key
publish and disappears when Hex ships OIDC trusted publishing.

**Honest payoff.** For this package the L2→L3 delta is mostly a compliance/label
gain today: Hex stores no provenance and essentially no one runs
`gh attestation verify` on Hex tarballs, so the extra "can't forge provenance
mid-build" guarantee protects a threat almost no consumer is positioned to check
yet. It costs little to keep and it future-proofs for if/when Hex ships native
provenance verification. (We use a GitHub-native reusable workflow rather than
`slsa-framework/slsa-github-generator`: same `gh attestation verify` UX, and the
generic generator wouldn't isolate the *build* for a mix package anyway — there is
no Elixir-specific SLSA builder.)

---

## What maintains itself

The project is built to notice the things it tracks, without anyone watching:

- **New PHP versions** — CI's differential matrix is discovered from
  endoflife.date (`/api/php.json`), so a freshly-released series is tested
  automatically and an EOL one drops off; the drift detector watches the same set
  of php-src branches. That endpoint is the one external dependency of this
  self-discovery: if it is ever retired or changes shape, discovery falls back to
  a pinned list and a *scheduled* run opens a tracking issue so the freeze is not
  silent — migrate to the v1 API (`/api/v1/products/php`, shape
  `result.releases[].name` / `.isEol`).
- **New PHP behaviour** (patch releases, PCRE changes) — CI also runs weekly, so
  a behavioural change is caught even with no commits.
- **Upstream regex changes** — the weekly drift detector opens an issue.
- **New Elixir / OTP releases** — a weekly canary runs the suite on the newest
  stable *Elixir* (on current-stable OTP), and a weekly *newest-OTP watch* runs
  the differential-vs-live-PHP suite on the newest stable *OTP* — the project's
  #1 long-term divergence vector, since a new OTP ships its own PCRE2 with newer
  Unicode tables. Either opens a tracking issue on regression. Promoting a new OTP
  **major** into the required `ci.yml` matrix is the one deliberate manual bump
  (see the checklist below).
- **Toolchain / action / dev-dep updates** — Dependabot, on a cooldown, with the
  safe ones auto-merged.

Scheduled failures open a tracking issue, so the only things that reach you are:
**approve a release**, the occasional **major action bump**, and an issue when
something genuinely needs a human (PHP changed its regex, or a new Elixir/PHP
release broke parity).

---

## Maintenance tasks reference

| Task | Command / action |
| --- | --- |
| Run the full local quality gate (mirrors the CI `quality` job) | `mix check` |
| Run the no-PHP regression suite | `mix test` |
| Run live parity + fuzz vs your PHP | `mix test --include php` |
| Regenerate golden from your PHP | `mix php.golden` |
| Check for upstream PHP regex drift | `mix php.drift` |
| Re-vendor the regex from php-src | `mix php.extract <ref>` then `mix php.test` |
| Build docs locally | `mix docs` |

### If the drift detector goes red

The weekly **Upstream drift detector** (`drift.yml`) fetches `logical_filters.c`
from php-src for each supported branch and fails if the regex changed. If it
fails:

1. Inspect the upstream change to `ext/filter/logical_filters.c`.
2. `mix php.extract PHP-8.x` to re-vendor, review `git diff priv/php`.
3. `mix php.golden && mix test --include php` to see how behaviour changed.
4. Commit with an appropriate Conventional Commit (`fix:` if it changes
   verdicts) and let the pipeline cut a release that notes the new PHP baseline.

### If a single PHP version's parity job goes red

The `differential vs PHP 8.x` CI job is red but the others are green. Because the
regex and the 320-byte gate are byte-identical across all supported PHP versions
(see §8 of `COMPATIBILITY.md`), the PHP version only changes the **PCRE engine**,
so the realistic cause is an engine/Unicode-table difference on the unicode path.
To reproduce and pin it locally:

1. Install **that exact PHP version** (e.g. `shivammathur/setup-php` with the
   matrix version, or your distro / `asdf` equivalent) so `php -v` matches the
   red job. This is the one piece the other runbooks don't cover.
2. `mix php.golden` to regenerate that version's golden from its `filter_var`.
3. `mix test --include php` — `php_live_test.exs` prints each diverging input with
   its mode and the `php=… elixir=…` verdicts.
4. See `COMPATIBILITY.md` §6 ("Unicode table drift" — the #1 long-term divergence
   vector) for the likely root cause; a shrunk failing input should become a
   permanent regression case in `test/fixtures/corpus.exs`.

### When a new OTP major ships

The newest-OTP watch (`ci.yml`) already exercises it weekly and opens an issue on
any divergence, but the required gate matrix is pinned. To **adopt** a new OTP
major into the gate: bump the `otp` entries in `ci.yml` (the `test` matrix, the
`quality`/`differential`/`canary`/`drift`/publish jobs) and re-run `mix test
--include php` to confirm unicode parity under the new OTP's PCRE2, then commit.

---

## Licensing

`mix.exs` declares `licenses: ["MIT", "PHP-3.01"]`: **MIT** covers the original
Elixir code, tests, tooling, and docs; **PHP-3.01** covers the php-src material
vendored under `priv/php` (`logical_filters.c` and the regex bytes derived from
it). The Michael Rushton attribution the regex additionally carries is preserved
in `NOTICE`, which ships in the package. If you ever stop vendoring the PHP regex,
drop `PHP-3.01` and remove `priv/php` from the package `files`.
