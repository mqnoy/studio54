defmodule Studio54.Starter do
  @moduledoc """
    This is the base module


  """
  use GenServer
  require Logger
  alias Studio54.Worker, as: Worker
  alias Studio54.Db, as: Db
  # @delivery_webhook Application.get_env(:studio54, :delivery_webhook)

  def start_link(args) do
    pid =
      case GenServer.start(__MODULE__, args, name: __MODULE__) do
        {:error, {:already_started, pid}} ->
          pid

        {:ok, pid} ->
          pid
      end

    {:ok, pid}
  end

  @impl true
  def init(_) do
    # basic state
    worker_initial_state =
      case Db.get_state() do
        {:error, :not_found} ->
          %{history: [], state_agent: nil, worker: nil}

        {:ok, state} ->
          state
      end

    # start an agent for state 
    {:ok, state_agant_pid} = Agent.start(fn -> worker_initial_state end)
    # update and set it's pid in it's state
    new_state = worker_initial_state |> Map.put(:state_agent, state_agant_pid)
    Db.set_state(new_state)

    Agent.update(state_agant_pid, fn _ ->
      new_state
    end)

    {:ok, _} = Registry.start_link(keys: :unique, name: Studio54.Processes)
    {:ok, _} = Registry.register(Studio54.Processes, "worker_state", new_state)
    {:ok, _} = Registry.register(Studio54.Processes, "state_agent", state_agant_pid)
    GenServer.cast(__MODULE__, {:start_monitor})
    {:ok, %{state_agent: state_agant_pid}}
  end

  @impl true
  def handle_cast({:start_monitor}, state) do
    {:ok, worker_state} = Db.get_state()

    {:ok, worker} = Worker.start(worker_state)
    Logger.info("Studio54 core worker started.")
    Process.monitor(worker)
    Worker.start_saver(worker)
    :ok = Registry.unregister(Studio54.Processes, "worker")
    {:ok, _} = Registry.register(Studio54.Processes, "worker", worker)
    {:noreply, state |> Map.put(:worker, worker)}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _worker, _reason}, state) do
    Logger.warn("Studio54 message core worker went down! Starting again after 1 second.")
    _time = Process.send_after(self(), {:"$gen_cast", {:start_monitor}}, 1_000)

    {:noreply, state}
  end

  @impl true
  def terminate(_, state) do
    Db.set_state(state)
  end
end
