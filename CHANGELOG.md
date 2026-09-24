# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Mutare 0.4.0 or newer is required** (`{:mutare, "~> 0.4.0"}`). Mutare now hands a
  piped `args |> MyWorker.new(opts)` to the enqueue family as the direct call it is sugar
  for, so both spellings are matched by one path; the mutants, their variants and their
  notes are unchanged.

## [0.1.0] - 2026-09-07

Initial release.

### Added

- `Mutare.Oban.WorkerReturn` (`:oban_worker_return`) — swaps `perform/1`
  return values for other *valid* Oban returns (`:ok`/`{:ok, v}` →
  `{:error, :mutare}`; `{:error, reason}` → `:ok` / `{:cancel, reason}`;
  `{:cancel, reason}` → `{:error, reason}` / `:ok`; `{:snooze, s}` → `:ok`;
  legacy `{:discard, reason}` → `:ok` / `{:cancel, reason}` and bare
  `:discard` → `:ok`). Applies only inside `Oban.Worker` /
  `Oban.Pro.Worker` modules, including branch tails via
  `return_replacements`. Declares `required_modules/0`, so a run where Oban
  is not loadable fails at startup with a `Mutare.EnvironmentError`.
- `Mutare.Oban.Enqueue` (`:oban_enqueue`) — rewrites `MyWorker.new(args, opts)`
  enqueue options (direct, aliased, or piped): `max_attempts: n` → `1` (n ≠ 1),
  and drops `unique:`, `schedule_in:`, and `scheduled_at:`.
- Report notes on every mutant describing assertions that could detect the changed behaviour.
- Ignore-variant labels on both families, so
  `# mutare:ignore[oban_worker_return:ok]` /
  `# mutare:ignore[oban_enqueue:unique]` can suppress one kind of mutant.
- `Mutare.Oban.all/0` for splicing both families into a `:mutators` list.

[Unreleased]: https://github.com/foxbenjaminfox/mutare_oban/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/foxbenjaminfox/mutare_oban/releases/tag/v0.1.0
