defmodule Mutare.Oban.WorkerReturnTest do
  use ExUnit.Case, async: true

  import Mutare.Test

  @mutators [Mutare.Oban.WorkerReturn]

  defp returns(src), do: diffs_for(src, @mutators, :oban_worker_return)
  defp mutateds(src), do: returns(src) |> Enum.map(fn {_original, mutated} -> mutated end)

  defp worker(body) do
    """
    defmodule MyApp.Worker do
      use Oban.Worker, queue: :default, max_attempts: 3
      @impl Oban.Worker
      #{body}
    end
    """
  end

  test "{:error, reason} swaps to :ok (the headline) and to {:cancel, reason}" do
    muts = mutateds(worker("def perform(_job), do: {:error, :boom}"))

    assert ":ok" in muts
    assert Enum.any?(muts, &(&1 =~ ~r/\{:cancel, :boom\}/))
    assert length(muts) == 2
  end

  test ":ok swaps to a sentinel error tuple" do
    muts = mutateds(worker("def perform(_job), do: :ok"))
    assert muts == ["{:error, :mutare}"]
  end

  test "{:ok, value} swaps to a sentinel error tuple (value dropped)" do
    muts = mutateds(worker("def perform(_job), do: {:ok, %{done: true}}"))
    assert muts == ["{:error, :mutare}"]
  end

  test "{:snooze, seconds} swaps to :ok (reschedule dropped)" do
    muts = mutateds(worker("def perform(_job), do: {:snooze, 30}"))
    assert muts == [":ok"]
  end

  test "{:cancel, reason} swaps to {:error, reason} and :ok" do
    muts = mutateds(worker("def perform(_job), do: {:cancel, :nope}"))

    assert Enum.any?(muts, &(&1 =~ ~r/\{:error, :nope\}/))
    assert ":ok" in muts
  end

  test "a bare :discard (the one valid bare legacy return) swaps to :ok" do
    assert mutateds(worker("def perform(_job), do: :discard")) == [":ok"]
  end

  test "a bare :cancel is left alone — not a member of Oban's result union" do
    # Oban logs an unknown return and completes the job anyway, so an :ok swap here
    # would differ only by a log line: an unkillable no-op.
    assert mutateds(worker("def perform(_job), do: :cancel")) == []
  end

  test "swaps each branch tail of a case in tail position" do
    body = """
    def perform(%Oban.Job{args: %{"id" => id}}) do
      case id do
        0 -> {:error, :zero}
        _ -> :ok
      end
    end
    """

    muts = mutateds(worker(body))

    # {:error, :zero} -> :ok / {:cancel, :zero}, and the :ok branch -> {:error, :mutare}
    assert ":ok" in muts
    assert Enum.any?(muts, &(&1 =~ ~r/\{:cancel, :zero\}/))
    assert "{:error, :mutare}" in muts
  end

  test "is inert outside an Oban worker (no use Oban.Worker, no @behaviour)" do
    plain = """
    defmodule Plain do
      def perform(_job), do: {:error, :boom}
    end
    """

    assert returns(plain) == []
  end

  test "fires on a direct @behaviour Oban.Worker, without use" do
    src = """
    defmodule MyApp.Bare do
      @behaviour Oban.Worker
      def perform(_job), do: {:error, :boom}
      def backoff(_job), do: 30
      def timeout(_job), do: :infinity
    end
    """

    assert ":ok" in Enum.map(diffs_for(src, @mutators, :oban_worker_return), &elem(&1, 1))
  end

  test "fires when the behaviour is declared through an alias" do
    src = """
    defmodule MyApp.Aliased do
      alias Oban.Worker
      @behaviour Worker
      def perform(_job), do: {:error, :boom}
    end
    """

    assert ":ok" in Enum.map(diffs_for(src, @mutators, :oban_worker_return), &elem(&1, 1))
  end

  test "fires inside an Oban.Pro.Worker (direct @behaviour, process/1)" do
    src = """
    defmodule MyApp.Pro do
      @behaviour Oban.Pro.Worker
      def process(_job), do: {:error, :boom}
    end
    """

    muts = Enum.map(diffs_for(src, @mutators, :oban_worker_return), &elem(&1, 1))

    assert ":ok" in muts
    assert Enum.any?(muts, &(&1 =~ ~r/\{:cancel, :boom\}/))
  end

  test "declares Oban.Worker as its deployment requirement (Pro deliberately excluded)" do
    assert Mutare.Oban.WorkerReturn.required_modules() == [Oban.Worker]
  end

  test "every mutant compiles (the single-build net)" do
    assert_metamutant_compiles(worker("def perform(_job), do: {:error, :boom}"), @mutators)
  end

  describe "ignore variants" do
    test "declares the swap-target vocabulary" do
      assert Mutare.Oban.WorkerReturn.variants() == ~w(ok error cancel)
    end

    test "each recorded site carries the label of the return it becomes" do
      src = worker("def perform(_job), do: {:error, :boom}")
      result = Mutare.transform_string(src, mutators: @mutators)

      labels = Map.new(result.mutants, &{&1.mutated_code, &1.variant})

      assert labels[":ok"] == ["ok"]
      assert labels["{:cancel, :boom}"] == ["cancel"]
    end

    test "an :ok tail's sentinel swap carries the \"error\" label" do
      src = worker("def perform(_job), do: :ok")
      result = Mutare.transform_string(src, mutators: @mutators)

      assert [%{mutated_code: "{:error, :mutare}", variant: ["error"]}] = result.mutants
    end

    test "[oban_worker_return:ok] suppresses only the failure-swallowing swap" do
      src =
        worker("def perform(_job), do: {:error, :boom} # mutare:ignore[oban_worker_return:ok]")

      result = Mutare.transform_string(src, mutators: @mutators)

      ignored? = Map.new(result.mutants, &{&1.mutated_code, &1.ignored})

      assert ignored?[":ok"] == true
      assert ignored?["{:cancel, :boom}"] == false
    end
  end
end
