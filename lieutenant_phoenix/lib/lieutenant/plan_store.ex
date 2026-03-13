defmodule Lieutenant.PlanStore do
  use GenServer

  @lieutenant_dir Path.expand("~/.lieutenant")
  @swarm_base Path.expand("~/.micolash/swarm")

  def start_link(opts) do
    plan_path = Keyword.get(opts, :plan_path)
    GenServer.start_link(__MODULE__, plan_path, name: __MODULE__)
  end

  # Convenience functions
  def read, do: GenServer.call(__MODULE__, :read)
  def set_path(path), do: GenServer.call(__MODULE__, {:set_path, path})
  def toggle_checkbox(line, checked), do: GenServer.call(__MODULE__, {:toggle, line, checked})
  def resolve_path, do: GenServer.call(__MODULE__, :resolve_path)

  @impl true
  def init(plan_path), do: {:ok, %{plan_path: plan_path}}

  @impl true
  def handle_call(:read, _from, state) do
    path = resolve(state.plan_path)
    state = %{state | plan_path: path}

    case path && File.read(path) do
      {:ok, content} ->
        title =
          content
          |> String.split("\n")
          |> Enum.find_value("", fn line ->
            trimmed = String.trim(line)
            if String.starts_with?(trimmed, "# "), do: String.slice(trimmed, 2..-1//1)
          end)

        {:reply, {content, title, path}, state}

      _ ->
        {:reply, {nil, nil, nil}, state}
    end
  end

  @impl true
  def handle_call({:set_path, path}, _from, state) do
    if path && File.exists?(path) do
      {:reply, :ok, %{state | plan_path: path}}
    else
      {:reply, :error, state}
    end
  end

  @impl true
  def handle_call({:toggle, line_num, checked}, _from, state) do
    path = resolve(state.plan_path)

    result =
      if path do
        case File.read(path) do
          {:ok, content} ->
            lines = String.split(content, "\n")

            if line_num >= 0 and line_num < length(lines) do
              line = Enum.at(lines, line_num)

              new_line =
                if checked do
                  String.replace(line, "- [ ]", "- [x]", global: false)
                else
                  String.replace(line, "- [x]", "- [ ]", global: false)
                end

              new_lines = List.replace_at(lines, line_num, new_line)
              File.write!(path, Enum.join(new_lines, "\n"))
              :ok
            else
              :error
            end

          _ ->
            :error
        end
      else
        :error
      end

    {:reply, result, %{state | plan_path: path}}
  end

  @impl true
  def handle_call(:resolve_path, _from, state) do
    path = resolve(state.plan_path)
    {:reply, path, %{state | plan_path: path}}
  end

  defp resolve(explicit) do
    cond do
      explicit && File.exists?(explicit) ->
        explicit

      true ->
        plan_ptr = Path.join(@lieutenant_dir, ".plan_path")

        cond do
          File.exists?(plan_ptr) ->
            p = plan_ptr |> File.read!() |> String.trim()
            if File.exists?(p), do: p, else: check_state_md()

          true ->
            check_state_md()
        end
    end
  end

  defp check_state_md do
    state_file = Path.join(@lieutenant_dir, "state.md")

    cond do
      File.exists?(state_file) ->
        case state_file
             |> File.read!()
             |> String.split("\n")
             |> Enum.find_value(fn line ->
               if String.contains?(line, "**plan:**") do
                 case Regex.run(~r/`([^`]+)`/, line) do
                   [_, path] when path != "none" ->
                     if File.exists?(path), do: path

                   _ ->
                     nil
                 end
               end
             end) do
          nil -> check_swarm_today()
          path -> path
        end

      true ->
        check_swarm_today()
    end
  end

  defp check_swarm_today do
    today =
      Path.join([
        @swarm_base,
        Calendar.strftime(DateTime.utc_now(), "%Y%m%d"),
        "plan.md"
      ])

    default = Path.join(@lieutenant_dir, "plan.md")

    cond do
      File.exists?(today) -> today
      File.exists?(default) -> default
      true -> nil
    end
  end
end
