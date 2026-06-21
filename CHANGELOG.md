# Changelog

## [1.0.6](https://github.com/DanielDent/elixir_php_email_validator/compare/v1.0.5...v1.0.6) (2026-06-21)


### Miscellaneous Chores

* release 1.0.6 ([60b0add](https://github.com/DanielDent/elixir_php_email_validator/commit/60b0addd1c959d46d8ab2fd0c0f6ba160d345f7f))

## [1.0.5](https://github.com/DanielDent/elixir_php_email_validator/compare/v1.0.3...v1.0.5) (2026-06-21)


### Miscellaneous Chores

* release 1.0.5 ([#16](https://github.com/DanielDent/elixir_php_email_validator/issues/16)) ([42f2d2b](https://github.com/DanielDent/elixir_php_email_validator/commit/42f2d2b03bd071855691d7e1d95ac313875b725c))

## 1.0.4 — not released (2026-06-21)

> The release pipeline failed at build + attest before publish; v1.0.4 was never
> tagged or published to Hex. Superseded by 1.0.5.

## [1.0.3](https://github.com/DanielDent/elixir_php_email_validator/compare/v1.0.2...v1.0.3) (2026-06-21)


### Continuous Integration

* harden release pipeline with SHA pinning and SLSA L3 build provenance ([a558908](https://github.com/DanielDent/elixir_php_email_validator/commit/a558908985d6cfde9bb99cd9c358e6caa85a7278))

## [1.0.2](https://github.com/DanielDent/elixir_php_email_validator/compare/v1.0.1...v1.0.2) (2026-06-20)


### Miscellaneous Chores

* release 1.0.2 ([#5](https://github.com/DanielDent/elixir_php_email_validator/issues/5)) ([0a529af](https://github.com/DanielDent/elixir_php_email_validator/commit/0a529afd2005b726e5131bc9cd8ca98e49ce2544))

## [1.0.1](https://github.com/DanielDent/elixir_php_email_validator/compare/v1.0.0...v1.0.1) (2026-06-20)


### Bug Fixes

* drop unsupported semver-major-days cooldown for github-actions ([4836149](https://github.com/DanielDent/elixir_php_email_validator/commit/4836149147e92bbdc41ba732f3d0b791fd0d2846))

## 1.0.0 (2026-06-20)


### Features

* initial release of elixir_php_email_validator ([da84a11](https://github.com/DanielDent/elixir_php_email_validator/commit/da84a1139e00595edc8b106aacb72ac859e06aa9))

## Changelog

This file is maintained automatically by
[release-please](https://github.com/googleapis/release-please) from
[Conventional Commits](https://www.conventionalcommits.org/). Please do not edit
it by hand — write good commit messages instead (see `RELEASING.md`).

Each release also notes which php-src state the vendored regex was verified
against, since this library's behaviour intentionally tracks PHP's
`filter_var(FILTER_VALIDATE_EMAIL)`.
