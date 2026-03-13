defmodule Lieutenant.Tmux do
  @moduledoc "Shell-out wrappers for tmux commands targeting the 'swarm' session."

  @session "swarm"
  # tmux format strings use #{...} which conflicts with Elixir interpolation
  @list_fmt "\#{window_index}|\#{window_name}|\#{window_active}|\#{pane_pid}"
  @list_cwd_fmt "\#{window_name}\t\#{pane_pid}\t\#{pane_current_path}"

  def list_windows do
    case System.cmd("tmux", [
           "list-windows", "-t", @session, "-F", @list_fmt
         ], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          parts = String.split(line, "|")
          case Integer.parse(Enum.at(parts, 0, "")) do
            {idx, _} ->
              [%{
                index: idx,
                name: Enum.at(parts, 1, ""),
                active: Enum.at(parts, 2, "0") == "1",
                pane_pid: Enum.at(parts, 3, "")
              }]
            :error ->
              []
          end
        end)

      _ ->
        []
    end
  end

  def list_windows_with_cwd do
    case System.cmd("tmux", [
           "list-windows", "-t", @session, "-F",
           @list_cwd_fmt
         ], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.map(fn line ->
          case String.split(line, "\t") do
            [name, pid, cwd | _] -> %{name: name, pane_pid: pid, cwd: cwd}
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  def capture(window_name, lines \\ 80) do
    case System.cmd("tmux", [
           "capture-pane", "-t", "#{@session}:#{window_name}",
           "-p", "-S", "-#{lines}"
         ], stderr_to_stdout: true) do
      {out, 0} -> out
      _ -> ""
    end
  end

  def send_keys(window_name, message) do
    case System.cmd("tmux", [
           "send-keys", "-t", "#{@session}:#{window_name}", message, "Enter"
         ], stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :error
    end
  end

  def kill_window(window_name) do
    # Send Ctrl-C, then /exit, then kill
    System.cmd("tmux", ["send-keys", "-t", "#{@session}:#{window_name}", "C-c", ""],
      stderr_to_stdout: true)
    Process.sleep(500)
    System.cmd("tmux", ["send-keys", "-t", "#{@session}:#{window_name}", "/exit", "Enter"],
      stderr_to_stdout: true)
    Process.sleep(1500)
    System.cmd("tmux", ["kill-window", "-t", "#{@session}:#{window_name}"],
      stderr_to_stdout: true)

    # Also kill companion terminal window
    case String.split(window_name, "/", parts: 2) do
      [_, ticket] ->
        System.cmd("tmux", ["kill-window", "-t", "#{@session}:term/#{ticket}"],
          stderr_to_stdout: true)
      _ -> :ok
    end

    :ok
  end
end
