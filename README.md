# mutare_oban

Mutation-testing mutators for [Oban](https://hexdocs.pm/oban), built as a plugin for
[Mutare](https://hexdocs.pm/mutare).

Oban worker code concentrates its *interesting* behaviour at two positions ordinary mutators
only graze:

- the **return value of `perform/1`** — the contract that decides whether a job completes,
  retries, cancels, or snoozes; and
- the **enqueue options** (`max_attempts:`, `unique:`, `schedule_in:`, …) — the retry / dedup /
  scheduling policy.

This plugin mints *well-formed-but-wrong* Oban programs at exactly those spots, so a **surviving**
mutant points at a precise gap in your suite — *no test asserts that this failed job retries, that
this job dedupes, that this snooze reschedules* — rather than merely crashing.

## Install

Add it (and Mutare) as dev/test dependencies:

```elixir
def deps do
  [
    {:mutare, "~> 0.1", only: [:dev, :test], runtime: false},
    {:mutare_oban, "~> 0.1", only: [:dev, :test], runtime: false}
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
mutators alone. Each records under its own report family — `:oban_worker_return` and
`:oban_enqueue` — so survivors are attributed precisely, and either can be enabled on its own:

```elixir
[mutators: [:builtins, Mutare.Oban.WorkerReturn]]   # just the perform/1 return swaps
```

Then run Mutare as usual:

```
mix mutare
```

## The mutations

### `Mutare.Oban.WorkerReturn` — `perform/1` return swaps

Behaviour-gated: fires **only** inside a module implementing `Oban.Worker` (or
`Oban.Pro.Worker`). Every swap is itself a *valid* Oban return, so the mutant runs as a
legitimate job that behaves differently — a survivor pinpoints unchecked semantics, not a crash.

| original             | mutant              | what a survivor means                        |
| -------------------- | ------------------- | -------------------------------------------- |
| `:ok` / `{:ok, v}`   | `{:error, :mutare}` | a completed job → retryable; success unchecked |
| `{:error, reason}`   | `:ok`               | ★ **a failure is silently swallowed**         |
| `{:error, reason}`   | `{:cancel, reason}` | a transient failure → permanent cancel        |
| `{:cancel, reason}`  | `{:error, reason}` / `:ok` | a permanent cancel → retry / quiet success |
| `{:snooze, seconds}` | `:ok`               | a reschedule is dropped                        |
| `{:discard, reason}` | `:ok` / `{:cancel, reason}` | (legacy discard) silently succeeds     |

The headline is **`{:error, reason}` → `:ok`**: if a test enqueues a job that should fail and
never asserts the job ends up `retryable`/`discarded`, that mutant lives.

Return tails are delivered through Mutare's `return_replacements/2` hook, so the swaps also reach
a worker that returns from a branch tail of a `case`/`cond`/`if`/`with` in tail position, not just
the clause body.

### `Mutare.Oban.Enqueue` — enqueue-option mutations

Matches a `MyWorker.new(args, opts)` call (direct, aliased, or piped) and rewrites its options:

| original                  | mutant            | what a survivor means          |
| ------------------------- | ----------------- | ------------------------------ |
| `max_attempts: n` (n ≠ 1) | `max_attempts: 1` | no retries — is the retry asserted? |
| `unique: [...]`           | *(dropped)*       | dedup removed — is the dupe caught? |
| `schedule_in: _`          | *(dropped)*       | runs now, not later — is the delay asserted? |
| `scheduled_at: _`         | *(dropped)*       |                                |

Each mutant carries a report note (what a survivor leaves unasserted), so a live mutant reads
as actionable guidance in `mix mutare`'s output.

## Ignoring one kind of mutant

Both families declare ignore-variant labels, so a `# mutare:ignore[family:label]` directive
can suppress one kind of mutant without silencing the whole family:

- `oban_worker_return` labels each swap by the return it **becomes**: `ok`, `error`, `cancel`.
- `oban_enqueue` labels each mutation by the option it **attacks**: `max_attempts`, `unique`,
  `schedule_in`, `scheduled_at`.

```elixir
# this job is best-effort: swallowing the failure is acceptable, keep the other swaps
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
**retryable** — that mutant **survives**, and the report tells you exactly which branch is
unguarded. Likewise, the `Charge.new(args, unique: [...])` at your call site loses its `unique:`
under `Mutare.Oban.Enqueue`: if no test asserts the job dedupes, that survives too.

## Deployment requirement

`Mutare.Oban.WorkerReturn` detects a worker through Mutare's `use`-expansion — `use Oban.Worker`
injects `@behaviour Oban.Worker`, which Mutare expands in-process. So **Oban must be loadable in
the Mutare process** when you run `mix mutare`. It is, by default: `mix mutare` runs with your
project's deps on the code path. (A direct `@behaviour Oban.Worker` is also detected, no expansion
needed.)

## What's deliberately out of scope

Two things are not runtime positions Mutare can splice a selector into, so they are left alone:

- **Static config in the `use` line** — `use Oban.Worker, max_attempts: 3` is compile-time, frozen
  before any mutant could activate. Only the *dynamic* `MyWorker.new(args, max_attempts: 3)`
  options are mutable (that's `Mutare.Oban.Enqueue`).
- **Cron schedules** — `Oban.Plugins.Cron`'s `crontab:` lives in `config/*.exs`, which Mutare never
  reads (it rewrites `lib/` source).

## Development

```
mix deps.get
mix test          # unit (diffs) + a live semantic check that a mutant actually changes perform/1
mix check         # format + credo
```

## License

Same as Mutare.
