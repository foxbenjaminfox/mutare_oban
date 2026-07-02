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

  test "every mutant compiles (the single-build net)" do
    assert_metamutant_compiles(worker("def perform(_job), do: {:error, :boom}"), @mutators)
  end

  describe "ignore variants" do
    test "declares the swap-target vocabulary" do
      assert Mutare.Oban.WorkerReturn.variants() == ~w(ok error cancel)
    end

    test "each recorded site carries the label of the return it becomes" do
      src = worker("def perform(_job), do: {:error, :boom}")
      {_metamutant, sites, _next_id} = Mutare.transform_string(src, mutators: @mutators)

      labels = Map.new(sites, &{&1.mutated_code, &1.variant})

      assert labels[":ok"] == ["ok"]
      assert labels["{:cancel, :boom}"] == ["cancel"]
    end

    test "[oban_worker_return:ok] suppresses only the failure-swallowing swap" do
      src =
        worker("def perform(_job), do: {:error, :boom} # mutare:ignore[oban_worker_return:ok]")

      {_metamutant, sites, _next_id} = Mutare.transform_string(src, mutators: @mutators)

      ignored? = Map.new(sites, &{&1.mutated_code, &1.ignored})

      assert ignored?[":ok"] == true
      assert ignored?["{:cancel, :boom}"] == false
    end
  end
end
