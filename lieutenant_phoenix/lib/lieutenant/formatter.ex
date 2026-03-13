defmodule Lieutenant.Formatter do
  @moduledoc "Server-side HTML formatting for transcripts, plans, diffs, and validator output."

  import Phoenix.HTML, only: [html_escape: 1]

  def esc(text) when is_binary(text) do
    text
    |> html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
  def esc(nil), do: ""
  def esc(other), do: esc(to_string(other))

  # ── Transcript formatting ──

  def format_transcript(messages) do
    messages
    |> Enum.map(&format_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_message(%{"type" => "user", "message" => message}) do
    text = extract_text(message["content"])
    if String.trim(text) != "" do
      truncated = if String.length(text) > 500, do: String.slice(text, 0, 500) <> "\n... (truncated)", else: text
      ~s(<div class="mb mb-user"><div class="ml">USER</div>#{esc(truncated)}</div>)
    end
  end

  defp format_message(%{"message" => %{"role" => "assistant", "content" => content}}) when is_list(content) do
    {text_parts, tool_parts} = Enum.reduce(content, {[], []}, fn
      %{"type" => "text", "text" => t}, {texts, tools} ->
        if String.trim(t) != "", do: {[t | texts], tools}, else: {texts, tools}

      %{"type" => "tool_use", "name" => name, "input" => input}, {texts, tools} ->
        summary = summarize_tool(name, input)
        {texts, [~s(<div class="mb-tool">[#{esc(name)}] #{esc(summary)}</div>) | tools]}

      _, acc -> acc
    end)

    text_parts = Enum.reverse(text_parts)
    tool_parts = Enum.reverse(tool_parts)

    combined =
      (if text_parts != [], do: esc(Enum.join(text_parts, "\n")), else: "") <>
        (if tool_parts != [], do: Enum.join(tool_parts, "\n"), else: "")

    if String.trim(combined) != "" do
      ~s(<div class="mb mb-agent"><div class="ml">AGENT</div>#{combined}</div>)
    end
  end

  defp format_message(_), do: nil

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) and &1["type"] == "text"))
    |> Enum.map(& &1["text"])
    |> Enum.join("\n")
  end

  defp extract_text(_), do: ""

  defp summarize_tool("Read", input), do: input["file_path"] || "?"
  defp summarize_tool("Edit", input), do: input["file_path"] || "?"
  defp summarize_tool("Write", input), do: input["file_path"] || "?"
  defp summarize_tool("Bash", input) do
    cmd = input["command"] || "?"
    if String.length(cmd) > 140, do: String.slice(cmd, 0, 140) <> "...", else: cmd
  end
  defp summarize_tool("Grep", input), do: ~s(pattern="#{input["pattern"] || "?"}")
  defp summarize_tool("Glob", input), do: input["pattern"] || "?"
  defp summarize_tool(_, input) do
    s = inspect(input)
    if String.length(s) > 100, do: String.slice(s, 0, 100), else: s
  end

  # ── Validator transcript formatting ──

  def format_validator_transcript(messages) do
    messages
    |> Enum.map(&format_validator_message/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp format_validator_message(%{"type" => "user", "message" => message}) do
    text = extract_text(message["content"])
    if String.trim(text) != "" do
      truncated = if String.length(text) > 300, do: String.slice(text, 0, 300) <> "\n... (truncated)", else: text
      ~s(<div class="mb mb-user"><div class="ml">PROMPT</div>#{esc(truncated)}</div>)
    end
  end

  defp format_validator_message(%{"message" => %{"role" => "assistant", "content" => content}}) when is_list(content) do
    {text_parts, tool_parts} = Enum.reduce(content, {[], []}, fn
      %{"type" => "text", "text" => t}, {texts, tools} ->
        if String.trim(t) != "", do: {[colorize_validator_text(t) | texts], tools}, else: {texts, tools}

      %{"type" => "tool_use", "name" => name, "input" => input}, {texts, tools} ->
        summary = summarize_tool(name, input)
        {texts, [~s(<div class="mb-tool">[#{esc(name)}] #{esc(summary)}</div>) | tools]}

      _, acc -> acc
    end)

    text_parts = Enum.reverse(text_parts)
    tool_parts = Enum.reverse(tool_parts)

    combined =
      (if text_parts != [], do: Enum.join(text_parts, "\n"), else: "") <>
        (if tool_parts != [], do: Enum.join(tool_parts, "\n"), else: "")

    if String.trim(combined) != "" do
      ~s(<div class="mb mb-agent"><div class="ml">VALIDATOR</div>#{combined}</div>)
    end
  end

  defp format_validator_message(_), do: nil

  def colorize_validator_text(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      lt = String.trim(line)
      cond do
        Regex.match?(~r/^\[WRONG\]/i, lt) ->
          ~s(<span class="c-red" style="font-weight:600">#{esc(line)}</span>)
        Regex.match?(~r/^\[UNVERIFIED\]/i, lt) ->
          ~s(<span class="c-yellow" style="font-weight:600">#{esc(line)}</span>)
        Regex.match?(~r/^\[SUSPICIOUS\]/i, lt) ->
          ~s(<span class="c-yellow">#{esc(line)}</span>)
        Regex.match?(~r/^\[CONFIRMED\]/i, lt) ->
          ~s(<span class="c-green">#{esc(line)}</span>)
        Regex.match?(~r/^CHALLENGE:/i, lt) ->
          ~s(<span class="c-red" style="font-weight:600">#{esc(line)}</span>)
        Regex.match?(~r/^(VERDICT:|Risk assessment:)/i, lt) ->
          ~s(<span style="font-weight:700">#{esc(line)}</span>)
        Regex.match?(~r/^BLOCK/i, lt) ->
          ~s(<span class="c-red" style="font-weight:700;font-size:13px">#{esc(line)}</span>)
        Regex.match?(~r/^PASS/i, lt) ->
          ~s(<span class="c-green" style="font-weight:700;font-size:13px">#{esc(line)}</span>)
        Regex.match?(~r/^REVIEW/i, lt) ->
          ~s(<span class="c-yellow" style="font-weight:700;font-size:13px">#{esc(line)}</span>)
        Regex.match?(~r/^(FILE|CLAIM|ACTION|QUANTITATIVE EVIDENCE|QUALITATIVE NOTE):/i, lt) ->
          ~s(<span class="c-dim">#{esc(line)}</span>)
        Regex.match?(~r/^\[TIER/i, lt) ->
          ~s(<span class="c-purple" style="font-weight:600">#{esc(line)}</span>)
        true ->
          esc(line)
      end
    end)
    |> Enum.join("\n")
  end

  # ── Diff colorization ──

  def colorize_diff(text) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      cond do
        String.starts_with?(line, "+") and not String.starts_with?(line, "+++") ->
          ~s(<span class="c-green">#{esc(line)}</span>)
        String.starts_with?(line, "-") and not String.starts_with?(line, "---") ->
          ~s(<span class="c-red">#{esc(line)}</span>)
        String.starts_with?(line, "@@") ->
          ~s(<span class="c-purple">#{esc(line)}</span>)
        String.starts_with?(line, "diff ") or String.starts_with?(line, "index ") ->
          ~s(<span class="c-dim">#{esc(line)}</span>)
        true ->
          esc(line)
      end
    end)
    |> Enum.join("\n")
  end

  # ── Plan markdown rendering ──

  def render_plan_markdown(nil), do: ~s(<div class="empty">No plan loaded.</div>)

  def render_plan_markdown(text) do
    lines = String.split(text, "\n")
    {html_parts, in_list} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({[], false}, fn {line, idx}, {parts, in_list} ->
        trimmed = String.trim(line)
        cond do
          String.starts_with?(trimmed, "### ") ->
            close = if in_list, do: ["</ul>"], else: []
            {parts ++ close ++ ["<h3>#{esc(String.slice(trimmed, 4..-1//1))}</h3>"], false}

          String.starts_with?(trimmed, "## ") ->
            close = if in_list, do: ["</ul>"], else: []
            {parts ++ close ++ ["<h2>#{esc(String.slice(trimmed, 3..-1//1))}</h2>"], false}

          String.starts_with?(trimmed, "# ") ->
            close = if in_list, do: ["</ul>"], else: []
            {parts ++ close ++ ["<h1>#{esc(String.slice(trimmed, 2..-1//1))}</h1>"], false}

          String.starts_with?(trimmed, "- [x] ") or String.starts_with?(trimmed, "- [ ] ") ->
            checked = String.starts_with?(trimmed, "- [x]")
            label = String.slice(trimmed, 6..-1//1)
            cls = if checked, do: " checked", else: ""
            chk = if checked, do: " checked", else: ""
            close = if in_list, do: ["</ul>"], else: []
            {parts ++ close ++ [~s(<div class="cb-line#{cls}"><input type="checkbox" data-line="#{idx}"#{chk} phx-click="toggle_check" phx-value-line="#{idx}" phx-value-checked="#{!checked}">#{esc(label)}</div>)], false}

          String.starts_with?(trimmed, "- ") ->
            open = if in_list, do: [], else: ["<ul>"]
            {parts ++ open ++ ["<li>#{esc(String.slice(trimmed, 2..-1//1))}</li>"], true}

          in_list and trimmed == "" ->
            {parts ++ ["</ul>"], false}

          trimmed != "" ->
            escaped = esc(trimmed) |> inline_code()
            {parts ++ ["<div>#{escaped}</div>"], in_list}

          true ->
            {parts ++ ["<br>"], in_list}
        end
      end)

    close = if in_list, do: "</ul>", else: ""
    ~s(<div class="plan-content">#{Enum.join(html_parts, "\n")}#{close}</div>)
  end

  defp inline_code(text) do
    Regex.replace(~r/`([^`]+)`/, text, "<code>\\1</code>")
  end
end
