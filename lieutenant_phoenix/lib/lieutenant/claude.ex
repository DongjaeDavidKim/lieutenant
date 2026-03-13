defmodule Lieutenant.Claude do
  @moduledoc "Session lookup and transcript reading from Claude's local files."

  @claude_sessions Path.expand("~/.claude/sessions")
  @claude_projects Path.expand("~/.claude/projects")

  def find_session_for_pid(pid) when is_binary(pid) do
    with true <- File.dir?(@claude_sessions) do
      @claude_sessions
      |> File.ls!()
      |> Enum.filter(&String.ends_with?(&1, ".json"))
      |> Enum.find_value(fn file ->
        path = Path.join(@claude_sessions, file)
        case File.read(path) do
          {:ok, data} ->
            case Jason.decode(data) do
              {:ok, %{"pid" => p, "sessionId" => sid}} when is_binary(sid) ->
                if to_string(p) == pid, do: sid, else: nil
              _ -> nil
            end
          _ -> nil
        end
      end)
    else
      _ -> nil
    end
  end

  def find_session_for_pane(pane_pid) when is_binary(pane_pid) and pane_pid != "" do
    case System.cmd("pgrep", ["-P", pane_pid], stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.trim()
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn child_pid ->
          find_session_for_pid(String.trim(child_pid))
        end)

      _ ->
        nil
    end
  end

  def find_session_for_pane(_), do: nil

  def find_transcript_file(nil), do: nil

  def find_transcript_file(session_id) do
    if File.dir?(@claude_projects) do
      @claude_projects
      |> File.ls!()
      |> Enum.find_value(fn dir ->
        candidate = Path.join([@claude_projects, dir, "#{session_id}.jsonl"])
        if File.exists?(candidate), do: candidate, else: nil
      end)
    end
  end

  def read_transcript(session_id, last_n \\ 50) do
    case find_transcript_file(session_id) do
      nil ->
        []

      path ->
        path
        |> File.stream!()
        |> Stream.reject(&(String.trim(&1) == ""))
        |> Stream.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, msg} -> [msg]
            _ -> []
          end
        end)
        |> Enum.to_list()
        |> Enum.take(-last_n)
    end
  end
end
