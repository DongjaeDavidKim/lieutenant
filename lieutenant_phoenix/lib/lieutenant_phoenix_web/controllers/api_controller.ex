defmodule LieutenantWeb.ApiController do
  use LieutenantWeb, :controller

  alias Lieutenant.{AgentStore, PlanStore, Claude, Tmux, Artifacts, Formatter}

  def agents(conn, _params) do
    # Return current agent state from AgentStore
    all = AgentStore.get_all()
    windows = Enum.map(all, fn {_id, info} ->
      Map.take(info, [:name, :session_id, :phase, :val_phase, :last_line, :alive, :index, :active, :pane_pid])
      |> Map.put_new(:index, -1)
      |> Map.put_new(:active, false)
      |> Map.put_new(:pane_pid, "")
    end)
    json(conn, %{windows: windows})
  end

  def plan(conn, _params) do
    {content, title, path} = PlanStore.read()
    json(conn, %{content: content, title: title, path: path || ""})
  end

  def plan_check(conn, %{"line" => line, "checked" => checked}) do
    ok = PlanStore.toggle_checkbox(line, checked)
    json(conn, %{ok: ok == :ok})
  end

  def plan_set(conn, %{"path" => path}) do
    case PlanStore.set_path(path) do
      :ok -> json(conn, %{ok: true, path: path})
      :error -> json(conn, %{ok: false, error: "file not found"})
    end
  end

  def transcript(conn, %{"session_id" => session_id} = params) do
    last_n = String.to_integer(Map.get(params, "last", "50"))
    is_validator = Map.get(params, "validator", "0") == "1"
    messages = Claude.read_transcript(session_id, last_n)
    formatted = if is_validator do
      Formatter.format_validator_transcript(messages)
    else
      Formatter.format_transcript(messages)
    end
    json(conn, %{formatted: formatted, count: length(messages)})
  end

  def capture(conn, %{"window" => window_parts}) do
    window = Enum.join(window_parts, "/")
    content = Tmux.capture(window, 200)
    json(conn, %{content: content})
  end

  def diff(conn, %{"ticket" => ticket}) do
    result = case System.cmd("cage", ["exec", ticket, "--", "git", "diff", "--stat"],
                   stderr_to_stdout: true) do
      {stat, 0} ->
        case System.cmd("cage", ["exec", ticket, "--", "git", "diff"],
                 stderr_to_stdout: true) do
          {d, 0} -> stat <> "\n" <> d
          _ -> stat
        end
      _ ->
        "(could not get diff — cage may not exist)"
    end
    json(conn, %{diff: result})
  end

  def artifacts(conn, %{"ticket" => ticket}) do
    result = Artifacts.collect(ticket)
    json(conn, result)
  end

  def send_keys(conn, %{"window" => window_parts} = params) do
    window = Enum.join(window_parts, "/")
    message = get_in(params, ["message"]) || ""
    ok = Tmux.send_keys(window, message) == :ok
    json(conn, %{ok: ok})
  end

  def kill(conn, %{"window" => window_parts}) do
    window = Enum.join(window_parts, "/")
    Tmux.kill_window(window)
    json(conn, %{ok: true})
  end
end
