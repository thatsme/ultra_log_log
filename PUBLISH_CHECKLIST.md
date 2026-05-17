# Publish checklist — v0.2.0

> **Maintainer use only.** This file is deleted in the same commit
> that publishes the release. It exists during prep as a single
> source of truth for what has to be verified before
> `mix hex.publish`.

## Local verification

- [ ] All tests pass (full tier):
      `mix test --include reference_vectors --include statistical`
- [ ] Format is clean:
      `mix format --check-formatted`
- [ ] Dialyzer is clean (test env, due to the OTP 27+ float-match
      warning in the `:hyper` benchmark comparison dependency):
      `MIX_ENV=test mix dialyzer`
- [ ] `MIX_ENV=test mix docs` builds without warnings.
      (Test env, same reason as dialyzer / `hex.publish` / the
      v0.2 benchmark runner — see GH issue #2.)
- [ ] `MIX_ENV=test mix hex.build` builds the tarball without
      warnings. Confirm the file list includes
      `lib/ultra_log_log/concurrent.ex` and totals **11 files**
      (v0.1 shipped 10; the only addition is `concurrent.ex`).

## Content review

- [ ] README renders correctly on GitHub (preview).
- [ ] HexDocs renders correctly locally:
      `MIX_ENV=test mix docs && open doc/index.html`. Confirm the
      "Concurrent" module group is visible in the sidebar and
      `UltraLogLog.Concurrent` is reachable.
- [ ] CHANGELOG `[0.2.0]` entry has a real date (not the
      `YYYY-MM-DD` placeholder).
- [ ] All links in README resolve (spot-check the paper links,
      the Hash4j tag, the paper-repo recognition link, and the
      `docs/measurements/*.txt` links).
- [ ] No `TODO` / `FIXME` / `coming soon` / `placeholder` in any
      user-facing document (README, CHANGELOG, moduledocs).
- [ ] `mix.exs` version is exactly `"0.2.0"`.

## Architect actions (manual)

- [ ] Delete this checklist file in the same commit that ships
      the release.
- [ ] `git tag v0.2.0 && git push origin v0.2.0`.
- [ ] `MIX_ENV=test mix hex.publish` (same workaround as v0.1.0;
      use `MIX_ENV=test mix hex.docs publish` as a follow-up only
      if needed).
- [ ] Create a GitHub release from the `v0.2.0` tag; paste the
      CHANGELOG `[0.2.0]` entry as the release notes.
