# Publish checklist — v0.1.0

> **Maintainer use only.** This file is deleted in the same commit
> that flips the repository to public visibility. It exists during
> prep to serve as a single source of truth for what has to be
> verified before `mix hex.publish`.

## Local verification

- [ ] All tests pass (default tier):
      `mix test`
- [ ] All tests pass (full tier):
      `mix test --include reference_vectors --include statistical`
- [ ] Format is clean:
      `mix format --check-formatted`
- [ ] Dialyzer is clean (test env, due to OTP 27+ float-match warning
      in the `:hyper` benchmark comparison dependency):
      `MIX_ENV=test mix dialyzer`
- [ ] `MIX_ENV=test mix docs` builds without warnings.
      (Test env, same reason as dialyzer: the `:hyper` benchmark
      comparison dependency doesn't compile under OTP 27+. Will
      resolve when v0.2 moves `:hyper` to a dedicated `:bench`
      environment — see GH issue #2.)
- [ ] `mix hex.build` builds the tarball without warnings.

## Content review

- [ ] README renders correctly on GitHub (preview before flipping).
- [ ] HexDocs renders correctly locally:
      `mix docs && open doc/index.html`.
- [ ] CHANGELOG `[0.1.0]` entry has a real date (not a placeholder).
- [ ] All links in README resolve (no 404s). Spot-check the paper
      links, the Hash4j tag link, and the `docs/measurements/*.txt`
      links once the repo goes public.
- [ ] `LICENSE` file present and includes the project-level
      copyright line at the bottom.
- [ ] No `TODO` / `FIXME` / `coming soon` / `placeholder` in any
      user-facing document (README, CHANGELOG, moduledocs).
- [ ] No references to `v0.0.x` or `rc` versions remain in code,
      docs, or `mix.exs`.
- [ ] `mix.exs` version is exactly `"0.1.0"`.

## Architect actions (manual)

- [ ] Flip repository visibility to public on GitHub.
- [ ] Delete this checklist file in the same commit that flips
      visibility.
- [ ] Run `mix hex.publish` after the repo is public so the
      `:source_url` and other Hex.pm links resolve.
- [ ] Tag the commit: `git tag v0.1.0 && git push origin v0.1.0`.
- [ ] Create a GitHub release pointing at the tag; paste the
      CHANGELOG `[0.1.0]` entry as the release notes.
