defmodule Lieutenant.Artifacts do
  @moduledoc "Collect PR, commit, diff, and test result artifacts for a ticket."

  @cages_dir Path.expand("~/.micolash/cages")

  def collect(ticket) do
    result = %{
      status: "unknown",
      commits: [],
      files_changed: "",
      diff_stat: "",
      diff: "",
      prs: [],
      test_results: ""
    }

    case find_cage_workspace(ticket) do
      nil ->
        %{result | status: "no cage found"}

      workspace ->
        result
        |> get_branch(workspace)
        |> get_commits(workspace)
        |> get_diff_stat(workspace)
        |> get_files_changed(workspace)
        |> get_full_diff(workspace)
        |> get_prs(workspace)
    end
  end

  defp find_cage_workspace(ticket) do
    exact = Path.join([@cages_dir, ticket, "workspace"])

    if File.dir?(exact) do
      exact
    else
      case File.ls(@cages_dir) do
        {:ok, dirs} ->
          Enum.find_value(dirs, fn dir ->
            ws = Path.join([@cages_dir, dir, "workspace"])
            if String.contains?(String.downcase(dir), String.downcase(ticket)) and File.dir?(ws),
              do: ws,
              else: nil
          end)

        _ ->
          nil
      end
    end
  end

  defp git(workspace, args) do
    case System.cmd("git", ["-C", workspace | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, out}
    end
  end

  defp get_branch(result, workspace) do
    case git(workspace, ["branch", "--show-current"]) do
      {:ok, branch} when branch != "" -> %{result | status: "branch: #{branch}"}
      _ -> %{result | status: "detached HEAD"}
    end
  end

  defp with_base(_workspace, fun) do
    Enum.find_value(~w(main master development), fn base ->
      case fun.(base) do
        {:ok, val} when val != "" -> val
        _ -> nil
      end
    end)
  end

  defp get_commits(result, workspace) do
    case with_base(workspace, fn base -> git(workspace, ["log", "#{base}..HEAD", "--oneline", "--no-decorate"]) end) do
      nil ->
        result

      log ->
        commits =
          log
          |> String.split("\n", trim: true)
          |> Enum.take(20)
          |> Enum.map(fn line ->
            %{hash: String.slice(line, 0, 7), message: String.slice(line, 8..-1//1)}
          end)

        %{result | commits: commits}
    end
  end

  defp get_diff_stat(result, workspace) do
    case with_base(workspace, fn base -> git(workspace, ["diff", "--stat", "#{base}..HEAD"]) end) do
      nil -> result
      stat -> %{result | diff_stat: stat}
    end
  end

  defp get_files_changed(result, workspace) do
    case with_base(workspace, fn base -> git(workspace, ["diff", "--name-only", "#{base}..HEAD"]) end) do
      nil -> result
      files -> %{result | files_changed: files}
    end
  end

  defp get_full_diff(result, workspace) do
    case with_base(workspace, fn base -> git(workspace, ["diff", "#{base}..HEAD"]) end) do
      nil ->
        result

      diff ->
        uncommitted = case git(workspace, ["diff"]) do
          {:ok, u} when u != "" -> "\n# --- Uncommitted changes ---\n" <> u
          _ -> ""
        end

        %{result | diff: diff <> uncommitted}
    end
  end

  defp get_prs(result, workspace) do
    branch = case git(workspace, ["branch", "--show-current"]) do
      {:ok, b} -> b
      _ -> nil
    end

    if branch do
      case System.cmd("gh", [
             "pr", "list", "--head", branch,
             "--json", "number,title,url,state", "--limit", "5"
           ], cd: workspace, stderr_to_stdout: true) do
        {out, 0} ->
          case Jason.decode(out) do
            {:ok, prs} when is_list(prs) ->
              mapped = Enum.map(prs, fn p ->
                %{
                  number: p["number"],
                  title: p["title"],
                  url: p["url"],
                  state: p["state"]
                }
              end)
              %{result | prs: mapped}

            _ ->
              result
          end

        _ ->
          result
      end
    else
      result
    end
  end
end
