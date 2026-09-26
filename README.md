# mutare_oban

[![Hex.pm](https://img.shields.io/hexpm/v/mutare_oban.svg)](https://hex.pm/packages/mutare_oban)
[![Hexdocs](https://img.shields.io/badge/hexdocs-docs-blue.svg)](https://hexdocs.pm/mutare_oban)
[![CI](https://github.com/foxbenjaminfox/mutare_oban/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/foxbenjaminfox/mutare_oban/actions/workflows/ci.yml)
[![License](https://img.shields.io/hexpm/l/mutare_oban.svg)](https://github.com/foxbenjaminfox/mutare_oban/blob/master/LICENSE)

Mutation-testing mutators for [Oban](https://hexdocs.pm/oban), built as a plugin for
[Mutare](https://hexdocs.pm/mutare).

This plugin targets two aspects of Oban worker behaviour that ordinary value mutations
do not directly test:

- the **return value of `perform/1`** — which determines whether a job completes,
  retries, cancels, or snoozes; and
- the **enqueue options** (`max_attempts:`, `unique:`, `schedule_in:`, …) — the retry / dedup /
  scheduling policy.

The mutations replace valid Oban returns with other valid returns and change enqueue options.
A **surviving** mutant indicates that the suite did not detect the changed behaviour — for
example, a failed job completing without a retry, a duplicate job, or a missing reschedule.

## Install

Add it (and Mutare) as dev/test dependencies:

```elixir
def deps do
  [
    {:mutare, "~> 0.4.1", only: [:dev, :test], runtime: false},
    {:mutare_oban, "~> 0.2", only: [:dev, :test], runtime: false}
  ]
end
```

(Oban itself is **not** a dependency of this plugin — it only ever names `Oban.Worker` as a
compile-time atom. Your own project already supplies Oban.)

## Enable

List the two mutators in `.mutare.exs`, alongside Mutare's built-ins:

```elixir
# .mutare.exs
[
  mutators: [:builtins] ++ Mutare.Oban.all()
]
```

`:builtins` keeps Mutare's default families and *adds* the Oban ones; drop it to run the Oban
mutators alone. Mutations are recorded under their respective report families —
`:oban_worker_return` and `:oban_enqueue` — and either mutator can be enabled on its own:

```elixir
[mutators: [:builtins, Mutare.Oban.WorkerReturn]]   # just the perform/1 return swaps
```

Then run Mutare as usual:

```
mix mutare
```

## The mutations

### `Mutare.Oban.WorkerReturn` — `perform/1` return swaps

Applies **only** inside a module implementing `Oban.Worker` (or `Oban.Pro.Worker`).
Every replacement is a *valid* Oban return with a different effect on the job's outcome.

| original             | mutant              | what a survivor means                        |
| -------------------- | ------------------- | -------------------------------------------- |
| `:ok` / `{:ok, v}`   | `{:error, :mutare}` | a completed job → retryable; success unchecked |
| `{:error, reason}`   | `:ok`               | **a failure is treated as success**           |
| `{:error, reason}`   | `{:cancel, reason}` | a transient failure → permanent cancel        |
| `{:cancel, reason}`  | `{:error, reason}` / `:ok` | a permanent cancel → retry / success       |
| `{:snooze, seconds}` | `:ok`               | a reschedule is dropped                        |
| `{:discard, reason}` | `:ok` / `{:cancel, reason}` | a legacy discard → success / cancel    |
| `:discard`           | `:ok`               | a legacy bare discard → success               |

For example, **`{:error, reason}` → `:ok`** can survive if a test enqueues a job that should
fail but never asserts that the job ends up `retryable`/`discarded`.

Mutare applies these swaps through its `return_replacements/2` hook, including returns from
branch tails of a `case`/`cond`/`if`/`with` in tail position as well as the clause body.

### `Mutare.Oban.Enqueue` — enqueue-option mutations

Matches a `MyWorker.new(args, opts)` call (direct, aliased, or piped) and rewrites its options:

| original                  | mutant            | what a survivor means          |
| ------------------------- | ----------------- | ------------------------------ |
| `max_attempts: n` (n ≠ 1) | `max_attempts: 1` | no retries — is the retry asserted? |
| `unique: [...]`           | *(dropped)*       | dedup removed — is the dupe caught? |
| `schedule_in: _`          | *(dropped)*       | runs now, not later — is the delay asserted? |
| `scheduled_at: _`         | *(dropped)*       |                                |

In `mix mutare`'s output, each mutant includes a report note describing an assertion that
could detect the changed behaviour.

## Ignoring one kind of mutant

Both families declare ignore-variant labels, so a `# mutare:ignore[family:label]` directive
can suppress one kind of mutant without excluding the whole family:

- `oban_worker_return` labels each swap by the return it **becomes**: `ok`, `error`, `cancel`.
- `oban_enqueue` labels each mutation by the option it **changes**: `max_attempts`, `unique`,
  `schedule_in`, `scheduled_at`.

```elixir
# this job is best-effort: treating failure as success is acceptable, keep the other swaps
{:error, reason} # mutare:ignore[oban_worker_return:ok] best-effort job

# the dedup window is exercised in staging, not unit tests
MyWorker.new(args, unique: [period: 60]) # mutare:ignore[oban_enqueue:unique]
```

## A worked example

```elixir
defmodule MyApp.Workers.Charge do
  use Oban.Worker, queue: :payments, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => id}}) do
    case Payments.charge(id) do
      {:ok, _receipt} -> :ok
      {:error, :card_declined} -> {:cancel, :card_declined}
      {:error, _transient} -> {:error, :retry_later}   # ← Mutare flips this to :ok
    end
  end
end
```

`Mutare.Oban.WorkerReturn` turns `{:error, :retry_later}` into `:ok`. If your suite only checks
the happy path and the declined card — but never asserts that a *transient* failure leaves the job
**retryable** — that mutant **survives**, and the report identifies the changed branch.
Likewise, `Mutare.Oban.Enqueue` removes `unique:` from `Charge.new(args, unique: [...])`:
if no test detects the duplicate job, that mutant survives too.

## Deployment requirement

`Mutare.Oban.WorkerReturn` detects a worker through Mutare's `use`-expansion — `use Oban.Worker`
injects `@behaviour Oban.Worker`, which Mutare expands in-process. So **Oban must be loadable in
the Mutare process** when you run `mix mutare`. It is, by default: `mix mutare` runs with your
project's deps on the code path. (A direct `@behaviour Oban.Worker` is also detected, no expansion
needed.) The requirement is declared via `required_modules/0`, so a run where Oban is *not*
loadable fails at startup with a `Mutare.EnvironmentError`.

## What's deliberately out of scope

Two things are not runtime positions Mutare can splice a selector into, so they are left alone:

- **Static config in the `use` line** — `use Oban.Worker, max_attempts: 3` is compile-time, frozen
  before any mutant can be activated. Only the *dynamic* `MyWorker.new(args, max_attempts: 3)`
  options are mutable (that's `Mutare.Oban.Enqueue`).
- **Cron schedules** — `Oban.Plugins.Cron`'s `crontab:` is configured in `config/*.exs`, which Mutare never
  reads (it rewrites `lib/` source).

## Development

```
mix deps.get
mix test          # unit (diffs) + a live semantic check that a mutant actually changes perform/1
mix check         # format + credo + dialyzer
```

## License

MIT — see [LICENSE](LICENSE).
