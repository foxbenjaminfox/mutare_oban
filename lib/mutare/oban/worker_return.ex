defmodule Mutare.Oban.WorkerReturn do
  @moduledoc """
  Swaps the **return value of an Oban worker callback** (`perform/1`, and Pro's `process/1`)
  for a *different but still valid* Oban outcome — the higher-signal analogue of
  `Mutare.Mutators.ReturnValue`'s sentinel.

  It is **behaviour-gated**: it fires only inside a module that implements `Oban.Worker` (or
  `Oban.Pro.Worker`), read from the enclosing module's behaviour set
  (`context.behaviours`, gathered by Mutare from a `use Oban.Worker`'s injected
  `@behaviour`). Everywhere else it is inert.

  Because every swap is itself a **valid** Oban return, the mutant runs as a legitimate job
  that *behaves differently* — so a survivor pinpoints a precise gap: *no test checks this
  job's success / failure / retry / cancel / snooze semantics.*

  ## The swaps

      :ok                ->  {:error, :mutare}     a completed job is now retryable
      {:ok, value}       ->  {:error, :mutare}     a completed job is now retryable
      {:error, reason}   ->  :ok                   ★ a failure is silently swallowed
      {:error, reason}   ->  {:cancel, reason}     a transient failure becomes a permanent cancel
      {:cancel, reason}  ->  {:error, reason}      a permanent cancel becomes retryable
      {:cancel, reason}  ->  :ok                   a cancel becomes a quiet success
      {:snooze, seconds} ->  :ok                   a reschedule is dropped
      {:discard, reason} ->  :ok                   (legacy discard) silently succeeds
      {:discard, reason} ->  {:cancel, reason}

  The headline is **`{:error, reason}` → `:ok`**: the canonical Oban survivor-finder. If a
  test inserts a job that should fail and never asserts the job ends up `retryable` /
  `discarded`, that mutant lives.

  ## Ignore variants

  Each mutant is labelled by the Oban return it *becomes* — `ok`, `error`, or `cancel` — so a
  `# mutare:ignore[oban_worker_return:<label>]` directive can suppress one kind of swap
  without silencing the family:

      {:error, reason} # mutare:ignore[oban_worker_return:ok] best-effort, failure unasserted

  keeps the `{:error, reason}` → `{:cancel, reason}` mutant while dropping the
  failure-swallowing `:ok` swap on that line. See `Mutare.Ignore`.

  Each mutant reuses the original `reason` operand and injects only literal control atoms, so
  every one is a **valid return that compiles** — the single metamutant build is never at
  risk. Return tails are delivered by Mutare's structural `return_replacements/2` hook, so the
  swaps also reach a worker that returns from a branch tail of a `case`/`cond`/`if`/`with` in
  tail position, not just the clause body.

  ## Deliberately left alone

    * The `{:ok, value}`'s `value` and a `{:snooze, _}`'s `seconds` are dropped (they don't
      survive the tag change), never *rewritten* — a value/seconds swap is `Mutare.Mutators`
      territory and rarely an Oban-semantics question.
    * A bare `:ok` carries no payload to preserve, so its only swap is to a sentinel error.
  """

  @behaviour Mutare.Mutator
  @behaviour Mutare.Mutator.Structural

  alias Mutare.AST

  @impl Mutare.Mutator
  def name, do: :oban_worker_return

  @doc """
  The swap-target vocabulary for `# mutare:ignore[oban_worker_return:<label>]` — each mutant
  is labelled by the Oban return it becomes: `"ok"`, `"error"`, or `"cancel"`.
  """
  @impl Mutare.Mutator
  def variants, do: ~w(ok error cancel)

  @doc """
  Classifies an emitted swap by its replacement's return tag (`c:Mutare.Mutator.variant/2`).

  Every mutant this family produces is exactly one of `:ok`, `{:error, _}`, or `{:cancel, _}`,
  so the label reads directly off the mutated node.
  """
  @impl Mutare.Mutator
  def variant(_original, mutated) do
    case AST.unwrap_literal(mutated) do
      :ok -> "ok"
      {tag_node, _payload} -> tag_label(AST.key_atom(tag_node))
      _other -> nil
    end
  end

  defp tag_label(tag) when tag in [:error, :cancel], do: Atom.to_string(tag)
  defp tag_label(_other), do: nil

  @doc """
  Offer the alternative Oban return(s) for `tail`, but only inside a worker module (read from
  `context.behaviours`). The context-aware form of
  `c:Mutare.Mutator.Structural.return_replacements/1`.
  """
  @impl Mutare.Mutator.Structural
  def return_replacements(tail, %{behaviours: behaviours}) do
    # `AST.unwrap_literal/1` sees through the single-element block Sourceror anchors a scalar
    # atom literal in, so the bare-atom clauses below match; a tuple tail passes through.
    if worker?(behaviours), do: swaps(AST.unwrap_literal(tail)), else: []
  end

  defp worker?(behaviours),
    do: Enum.any?(Mutare.Oban.worker_behaviours(), &MapSet.member?(behaviours, &1))

  # Bare-atom tails.
  defp swaps(:ok), do: [error_tuple()]
  defp swaps(:discard), do: [ok()]
  defp swaps(:cancel), do: [ok()]

  # Two-tuple tails `{tag, payload}` — in AST a literal 2-tuple is the only thing that matches
  # this shape (everything else is a 3-element `{call, meta, args}` node), so reading the tag
  # atom off the first element is unambiguous. A non-Oban tag falls through to `[]`.
  defp swaps({tag_node, payload}), do: two_tuple(AST.key_atom(tag_node), payload)
  defp swaps(_other), do: []

  defp two_tuple(:ok, _value), do: [error_tuple()]
  defp two_tuple(:error, reason), do: [ok(), tuple(:cancel, reason)]
  defp two_tuple(:cancel, reason), do: [tuple(:error, reason), ok()]
  defp two_tuple(:snooze, _seconds), do: [ok()]
  defp two_tuple(:discard, reason), do: [ok(), tuple(:cancel, reason)]
  defp two_tuple(_tag, _payload), do: []

  defp ok, do: AST.literal(:ok)
  defp error_tuple, do: tuple(:error, AST.literal(AST.sentinel_atom()))

  # A literal 2-tuple node `{tag, payload}`: the tag as a clean-meta atom literal, the payload
  # reused verbatim. Renders `{:tag, payload}`.
  defp tuple(tag, payload), do: {AST.literal(tag), payload}
end
