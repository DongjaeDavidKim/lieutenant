defmodule Lieutenant.PhaseDetector do
  @moduledoc "Detect agent phase from transcript messages or tmux output."

  def from_transcript([]), do: "starting"

  def from_transcript(messages) do
    messages
    |> Enum.take(-5)
    |> Enum.reverse()
    |> Enum.find_value("working", &check_message/1)
  end

  defp check_message(msg) do
    content = get_in(msg, ["message", "content"])
    check_blocks(content)
  end

  defp check_blocks(blocks) when is_list(blocks) do
    Enum.find_value(blocks, fn
      %{"type" => "tool_use", "name" => name} = block ->
        check_tool(name, block)

      %{"type" => "text", "text" => text} ->
        lower = String.downcase(text)
        cond do
          String.contains?(lower, "error") or String.contains?(lower, "failed") -> "error"
          String.contains?(lower, "pr created") -> "done-pr"
          true -> nil
        end

      _ ->
        nil
    end)
  end

  defp check_blocks(_), do: nil

  defp check_tool(name, _block) when name in ~w(Edit Write NotebookEdit), do: "implementing"

  defp check_tool("Bash", block) do
    cmd = get_in(block, ["input", "command"]) || ""
    cond do
      String.contains?(cmd, "test") or String.contains?(cmd, "jest") or
          String.contains?(cmd, "pytest") ->
        "testing"

      String.contains?(cmd, "git push") ->
        "pushing"

      String.contains?(cmd, "gh pr create") ->
        "done-pr"

      true ->
        "executing"
    end
  end

  defp check_tool(name, _block) when name in ~w(Read Grep Glob), do: "analyzing"
  defp check_tool(_, _), do: nil

  def from_tmux(text) do
    recent = if String.length(text) > 3000, do: String.slice(text, -3000..-1//1), else: text
    lower = String.downcase(recent)

    cond do
      String.contains?(lower, "pr created") or String.contains?(lower, "gh pr create") ->
        "done-pr"

      String.contains?(lower, "git push") ->
        "pushing"

      true ->
        last_500 =
          if String.length(lower) > 500, do: String.slice(lower, -500..-1//1), else: lower

        cond do
          String.contains?(last_500, "error") or String.contains?(last_500, "failed") ->
            "error"

          String.contains?(lower, "yarn test") or String.contains?(lower, "jest") or
              String.contains?(lower, "pytest") ->
            "testing"

          String.contains?(lower, "edit(") or String.contains?(lower, "write(") ->
            "implementing"

          String.contains?(lower, "grep") or String.contains?(lower, "glob") or
              String.contains?(lower, "read(") ->
            "analyzing"

          true ->
            "working"
        end
    end
  end

  def validator_phase(text) do
    lower =
      if String.length(text) > 2000,
        do: text |> String.slice(-2000..-1//1) |> String.downcase(),
        else: String.downcase(text)

    cond do
      String.contains?(lower, "verdict:") or String.contains?(lower, "summary") ->
        cond do
          String.contains?(lower, "block") -> "verdict-block"
          String.contains?(lower, "pass") -> "verdict-pass"
          String.contains?(lower, "review") -> "verdict-review"
          true -> "verdict"
        end

      String.contains?(lower, "challenge:") or String.contains?(lower, "[wrong]") or
          String.contains?(lower, "[unverified]") ->
        "attacking"

      String.contains?(lower, "grep") or String.contains?(lower, "read(") or
          String.contains?(lower, "bash") ->
        "investigating"

      true ->
        "analyzing"
    end
  end
end
