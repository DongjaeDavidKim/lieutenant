defmodule Lieutenant.AgentPoller do
  use GenServer
  require Logger

  @poll_interval 2_000
  @pubsub Lieutenant.PubSub
  @topic "agents"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    schedule_poll()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll()
    schedule_poll()
    {:noreply, state}
  end

  defp schedule_poll, do: Process.send_after(self(), :poll, @poll_interval)

  defp poll do
    windows = Lieutenant.Tmux.list_windows()
    {live_ids, window_data} =
      Enum.reduce(windows, {MapSet.new(), []}, fn w, {ids, data} ->
        session_id = Lieutenant.Claude.find_session_for_pane(w.pane_pid)
        w = Map.put(w, :session_id, session_id)

        cond do
          String.starts_with?(w.name, "se/") ->
            agent_id = "se:" <> String.replace_prefix(w.name, "se/", "")
            phase = if session_id do
              msgs = Lieutenant.Claude.read_transcript(session_id, 8)
              Lieutenant.PhaseDetector.from_transcript(msgs)
            else
              content = Lieutenant.Tmux.capture(w.name, 30)
              Lieutenant.PhaseDetector.from_tmux(content)
            end

            content = Lieutenant.Tmux.capture(w.name, 5)
            last_line = content
              |> String.trim()
              |> String.split("\n")
              |> Enum.filter(&(String.trim(&1) != ""))
              |> List.last("")
              |> String.slice(0, 80)

            attrs = %{
              name: w.name, phase: phase, last_line: last_line,
              session_id: session_id, window: w.name, alive: true
            }
            Lieutenant.AgentStore.update(agent_id, attrs)

            w = w |> Map.put(:phase, phase) |> Map.put(:last_line, last_line) |> Map.put(:alive, true)
            {MapSet.put(ids, agent_id), [w | data]}

          String.starts_with?(w.name, "val/") ->
            val_id = "val:" <> String.replace_prefix(w.name, "val/", "")
            content = Lieutenant.Tmux.capture(w.name, 30)
            val_phase = Lieutenant.PhaseDetector.validator_phase(content)

            last_line = content
              |> String.trim()
              |> String.split("\n")
              |> Enum.filter(&(String.trim(&1) != ""))
              |> List.last("")
              |> String.slice(0, 80)

            attrs = %{
              name: w.name, val_phase: val_phase, last_line: last_line,
              session_id: session_id, window: w.name, alive: true
            }
            Lieutenant.AgentStore.update(val_id, attrs)

            w = w |> Map.put(:val_phase, val_phase) |> Map.put(:last_line, last_line) |> Map.put(:alive, true)
            {MapSet.put(ids, val_id), [w | data]}

          true ->
            # orchestrator or other windows
            w = Map.put(w, :alive, true)
            {ids, [w | data]}
        end
      end)

    # Mark disappeared agents as finished
    all_agents = Lieutenant.AgentStore.get_all()
    for {id, info} <- all_agents,
        info[:alive] == true,
        not MapSet.member?(live_ids, id) do
      Lieutenant.AgentStore.mark_finished(id)
    end

    # Build windows list including finished agents (synthetic windows)
    all_agents = Lieutenant.AgentStore.get_all()
    finished_windows =
      for {id, info} <- all_agents,
          not MapSet.member?(live_ids, id) do
        %{
          index: -1, name: info[:name] || "", active: false, pane_pid: "",
          session_id: info[:session_id], phase: info[:phase] || "done",
          val_phase: info[:val_phase] || "done", last_line: info[:last_line] || "",
          alive: false
        }
      end

    all_windows = Enum.reverse(window_data) ++ finished_windows

    # Broadcast
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:agents_updated, all_windows})
  end

  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end
end
