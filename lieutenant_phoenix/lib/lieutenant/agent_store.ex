defmodule Lieutenant.AgentStore do
  use GenServer

  # State: %{id => %{name, phase, last_line, session_id, window, alive, val_phase, finished_at}}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  # Convenience functions
  def get_all, do: GenServer.call(__MODULE__, :get_all)
  def get(id), do: GenServer.call(__MODULE__, {:get, id})
  def update(id, attrs), do: GenServer.cast(__MODULE__, {:update, id, attrs})
  def mark_finished(id), do: GenServer.cast(__MODULE__, {:mark_finished, id})
  def update_batch(updates), do: GenServer.cast(__MODULE__, {:update_batch, updates})

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call(:get_all, _from, state), do: {:reply, state, state}

  @impl true
  def handle_call({:get, id}, _from, state), do: {:reply, Map.get(state, id), state}

  @impl true
  def handle_cast({:update, id, attrs}, state) do
    current = Map.get(state, id, %{})
    {:noreply, Map.put(state, id, Map.merge(current, attrs))}
  end

  @impl true
  def handle_cast({:mark_finished, id}, state) do
    case Map.get(state, id) do
      nil ->
        {:noreply, state}

      agent ->
        phase = agent[:phase] || "done"

        terminal_phase =
          cond do
            phase in ["pushing", "done-pr"] -> "done-pr"
            phase == "error" -> "error"
            true -> "done"
          end

        updated =
          agent
          |> Map.put(:alive, false)
          |> Map.put(:finished_at, System.system_time(:second))
          |> Map.put(:phase, terminal_phase)

        {:noreply, Map.put(state, id, updated)}
    end
  end

  @impl true
  def handle_cast({:update_batch, updates}, state) do
    new_state =
      Enum.reduce(updates, state, fn {id, attrs}, acc ->
        current = Map.get(acc, id, %{})
        Map.put(acc, id, Map.merge(current, attrs))
      end)

    {:noreply, new_state}
  end
end
