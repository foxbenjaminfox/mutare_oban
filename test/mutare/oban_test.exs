defmodule Mutare.ObanTest do
  # async: false — `with_active_mutant/2` flips a VM-wide :persistent_term selection slot.
  use ExUnit.Case, async: false

  import Mutare.Test

  describe "all/0" do
    test "lists both mutators" do
      assert Mutare.Oban.all() == [Mutare.Oban.WorkerReturn, Mutare.Oban.Enqueue]
    end
  end

  describe "the mutant is live (semantic check)" do
    @worker """
    defmodule MyApp.LiveWorker do
      use Oban.Worker, queue: :default
      @impl Oban.Worker
      def perform(%{args: %{"fail" => true}}), do: {:error, :boom}
      def perform(_job), do: :ok
    end
    """

    test "swapping {:error, :boom} -> :ok actually changes perform/1's result" do
      {[mod], sites} = compile_metamutant(@worker, [Mutare.Oban.WorkerReturn])

      failing = %{args: %{"fail" => true}}
      ok_job = %{args: %{}}

      # Baseline (mutant 0): the worker behaves as written.
      assert mod.perform(failing) == {:error, :boom}
      assert mod.perform(ok_job) == :ok

      # The {:error, :boom} -> :ok mutant: a failure now silently succeeds.
      swallow =
        site_by(sites, "error->ok", fn s ->
          s.mutator == :oban_worker_return and s.original_code =~ "error" and
            s.mutated_code == ":ok"
        end)

      assert with_active_mutant(swallow.id, fn -> mod.perform(failing) end) == :ok

      # Restored afterwards.
      assert mod.perform(failing) == {:error, :boom}
    end
  end
end
