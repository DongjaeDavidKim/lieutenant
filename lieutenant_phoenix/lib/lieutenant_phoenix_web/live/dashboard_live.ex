defmodule LieutenantWeb.DashboardLive do
  use LieutenantWeb, :live_view

  alias Lieutenant.{PlanStore, Formatter, Claude, Tmux, Artifacts}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Lieutenant.AgentPoller.subscribe()
    end

    socket =
      socket
      |> assign(:windows, [])
      |> assign(:agents, %{})
      |> assign(:validators, %{})
      |> assign(:selected_se, nil)
      |> assign(:selected_val, nil)
      |> assign(:se_view, "transcript")
      |> assign(:val_view, "transcript")
      |> assign(:plan_view, "plan")
      |> assign(:plan_html, "")
      |> assign(:plan_title, "Mission")
      |> assign(:se_body, "")
      |> assign(:val_body, "")
      |> assign(:top_meta, "")
      |> assign(:page_title, "Lieutenant")
      |> refresh_plan()

    {:ok, socket}
  end

  @impl true
  def handle_info({:agents_updated, windows}, socket) do
    socket = process_windows(socket, windows)
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_agent", %{"id" => id}, socket) do
    socket = select_item(socket, id)
    {:noreply, socket}
  end

  @impl true
  def handle_event("set_se_view", %{"view" => view}, socket) do
    socket =
      socket
      |> assign(:se_view, view)
      |> refresh_se_panel()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_val_view", %{"view" => view}, socket) do
    socket =
      socket
      |> assign(:val_view, view)
      |> refresh_val_panel()

    {:noreply, socket}
  end

  @impl true
  def handle_event("set_plan_view", %{"view" => view}, socket) do
    socket =
      socket
      |> assign(:plan_view, view)
      |> refresh_plan()

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_check", %{"line" => line, "checked" => checked}, socket) do
    line_num = String.to_integer(line)
    checked_bool = checked == "true"
    PlanStore.toggle_checkbox(line_num, checked_bool)
    {:noreply, refresh_plan(socket)}
  end

  @impl true
  def handle_event("send_to_se", %{"message" => msg}, socket) do
    case socket.assigns.selected_se do
      %{window: window, alive: true} when msg != "" ->
        Tmux.send_keys(window, msg)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("send_to_term", %{"command" => cmd}, socket) do
    case socket.assigns.selected_se do
      %{id: id, alive: true} when cmd != "" ->
        ticket = id |> String.split(":") |> List.last()
        Tmux.send_keys("term/#{ticket}", cmd)

      _ ->
        :ok
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("kill_agent", %{"id" => id}, socket) do
    agent = socket.assigns.agents[id] || socket.assigns.validators[id]

    if agent && !String.starts_with?(id, "orch:") do
      Tmux.kill_window(agent.window)
    end

    socket =
      if socket.assigns.selected_se && socket.assigns.selected_se.id == id do
        assign(socket, :selected_se, nil)
      else
        socket
      end

    {:noreply, socket}
  end

  # ── Private helpers ──

  defp process_windows(socket, windows) do
    {agents, validators} =
      Enum.reduce(windows, {%{}, %{}}, fn w, {ag, val} ->
        name = w[:name] || w.name

        cond do
          name == "orchestrator" ->
            id = "orch:orchestrator"

            {Map.put(ag, id, %{
               id: id,
               window: name,
               session_id: w[:session_id],
               phase: "orchestrator",
               alive: true
             }), val}

          String.starts_with?(name, "se/") ->
            ticket = String.replace_prefix(name, "se/", "")
            id = "se:" <> ticket

            {Map.put(ag, id, %{
               id: id,
               window: name,
               session_id: w[:session_id],
               phase: w[:phase] || "working",
               last_line: w[:last_line] || "",
               alive: w[:alive] != false
             }), val}

          String.starts_with?(name, "val/") ->
            ticket = String.replace_prefix(name, "val/", "")
            id = "val:" <> ticket

            {ag,
             Map.put(val, id, %{
               id: id,
               window: name,
               session_id: w[:session_id],
               val_phase: w[:val_phase] || "analyzing",
               last_line: w[:last_line] || "",
               alive: w[:alive] != false
             })}

          true ->
            {ag, val}
        end
      end)

    # Auto-select first SE agent if none selected
    selected_se = socket.assigns.selected_se

    selected_se =
      if selected_se == nil or not Map.has_key?(agents, selected_se.id) do
        agents
        |> Map.values()
        |> Enum.filter(&(&1.alive && String.starts_with?(&1.id, "se:")))
        |> List.first()
      else
        # Update with fresh data
        Map.get(agents, selected_se.id, selected_se)
      end

    # Auto-select matching validator
    selected_val =
      if selected_se do
        ticket = selected_se.id |> String.split(":") |> List.last()
        val_id = "val:" <> ticket
        Map.get(validators, val_id, socket.assigns.selected_val)
      else
        socket.assigns.selected_val
      end

    # Build top meta
    se_agents = agents |> Map.values() |> Enum.filter(&String.starts_with?(&1.id, "se:"))
    se_working = Enum.count(se_agents, & &1.alive)
    se_done = Enum.count(se_agents, &(!&1.alive))
    se_total = length(se_agents)

    phase_counts = se_agents |> Enum.map(& &1.phase) |> Enum.frequencies()

    phase_str =
      phase_counts |> Enum.map(fn {p, c} -> "#{c} #{p}" end) |> Enum.join(", ")

    val_list = Map.values(validators)
    val_count = length(val_list)

    val_phase_counts =
      val_list |> Enum.map(&(&1.val_phase || "analyzing")) |> Enum.frequencies()

    val_str =
      val_phase_counts |> Enum.map(fn {p, c} -> "#{c} #{p}" end) |> Enum.join(", ")

    top_meta =
      "#{se_total} agents (#{se_working} working, #{se_done} done)" <>
        if(phase_str != "", do: " — #{phase_str}", else: "") <>
        if(val_count > 0,
          do:
            " — #{val_count} validators" <>
              if(val_str != "", do: " (#{val_str})", else: ""),
          else: ""
        )

    socket
    |> assign(:windows, windows)
    |> assign(:agents, agents)
    |> assign(:validators, validators)
    |> assign(:selected_se, selected_se)
    |> assign(:selected_val, selected_val)
    |> assign(:top_meta, top_meta)
    |> refresh_plan()
    |> refresh_se_panel()
    |> refresh_val_panel()
  end

  defp select_item(socket, id) do
    [type | _] = String.split(id, ":")

    case type do
      t when t in ["se", "orch"] ->
        agent = socket.assigns.agents[id]

        if agent do
          ticket = id |> String.split(":") |> List.last()
          val_id = "val:" <> ticket

          selected_val =
            Map.get(socket.assigns.validators, val_id, socket.assigns.selected_val)

          socket
          |> assign(:selected_se, agent)
          |> assign(:selected_val, selected_val)
          |> assign(:se_view, "transcript")
          |> refresh_se_panel()
          |> refresh_val_panel()
        else
          socket
        end

      "val" ->
        validator = socket.assigns.validators[id]

        if validator do
          socket
          |> assign(:selected_val, validator)
          |> refresh_val_panel()
        else
          socket
        end

      _ ->
        socket
    end
  end

  defp refresh_plan(socket) do
    case socket.assigns.plan_view do
      "plan" ->
        {content, title, _path} = PlanStore.read()
        plan_html = Formatter.render_plan_markdown(content)
        assign(socket, plan_html: plan_html, plan_title: title || "Mission")

      "transcript" ->
        orch = socket.assigns.agents["orch:orchestrator"]

        html =
          if orch && orch.session_id do
            msgs = Claude.read_transcript(orch.session_id, 60)
            Formatter.format_transcript(msgs)
          else
            ~s[<span class="c-dim">(no orchestrator session)</span>]
          end

        assign(socket, plan_html: html, plan_title: "Orchestrator")
    end
  end

  defp refresh_se_panel(%{assigns: %{selected_se: nil}} = socket) do
    assign(
      socket,
      :se_body,
      ~s[<div class="empty">Select an agent to view its conversation</div>]
    )
  end

  defp refresh_se_panel(socket) do
    se = socket.assigns.selected_se
    view = socket.assigns.se_view

    html =
      case view do
        "transcript" ->
          if se.session_id do
            msgs = Claude.read_transcript(se.session_id, 60)
            result = Formatter.format_transcript(msgs)

            if result == "",
              do: ~s[<span class="c-dim">(no transcript yet)</span>],
              else: result
          else
            content = Tmux.capture(se.window, 200)
            ~s[<span class="c-dim">#{Formatter.esc(content)}</span>]
          end

        "tmux" ->
          ticket = se.id |> String.split(":") |> List.last()
          content = Tmux.capture("term/#{ticket}", 200)

          if content == "" do
            Formatter.esc("(no terminal — agent may not have a cage)")
          else
            Formatter.esc(content)
          end

        "diff" ->
          ticket = se.id |> String.split(":") |> List.last()

          case System.cmd("cage", ["exec", ticket, "--", "git", "diff", "--stat"],
                 stderr_to_stdout: true
               ) do
            {stat, 0} ->
              case System.cmd("cage", ["exec", ticket, "--", "git", "diff"],
                     stderr_to_stdout: true
                   ) do
                {diff, 0} -> Formatter.colorize_diff(stat <> "\n" <> diff)
                _ -> Formatter.colorize_diff(stat)
              end

            _ ->
              Formatter.esc("(could not get diff — cage may not exist)")
          end

        "artifacts" ->
          ticket = se.id |> String.split(":") |> List.last()
          data = Artifacts.collect(ticket)
          render_artifacts_html(data)
      end

    assign(socket, :se_body, html)
  end

  defp refresh_val_panel(%{assigns: %{selected_val: nil}} = socket) do
    assign(
      socket,
      :val_body,
      ~s[<div class="empty">Validator appears when an SE agent's work is challenged.</div>]
    )
  end

  defp refresh_val_panel(socket) do
    val = socket.assigns.selected_val
    view = socket.assigns.val_view

    html =
      case view do
        "transcript" ->
          if val.session_id do
            msgs = Claude.read_transcript(val.session_id, 60)
            result = Formatter.format_validator_transcript(msgs)

            if result == "",
              do: ~s[<span class="c-dim">(validator not started yet)</span>],
              else: result
          else
            content = Tmux.capture(val.window, 200)
            Formatter.colorize_validator_text(content)
          end

        "tmux" ->
          content = Tmux.capture(val.window, 200)
          Formatter.esc(content)
      end

    assign(socket, :val_body, html)
  end

  defp render_artifacts_html(data) do
    parts = []

    # Status
    parts =
      parts ++
        [
          ~s[<div style="margin-bottom:12px"><div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Status</div><div style="font-size:11px">#{Formatter.esc(data.status)}</div></div>]
        ]

    # PRs
    parts =
      if data.prs != [] do
        pr_html =
          Enum.map(data.prs, fn pr ->
            state_color =
              case pr.state do
                "MERGED" -> "var(--purple)"
                "OPEN" -> "var(--green)"
                _ -> "var(--red)"
              end

            ~s[<div style="margin-bottom:4px"><a href="#{Formatter.esc(pr.url)}" target="_blank" style="color:var(--accent);text-decoration:none">##{pr.number}</a> <span style="color:#{state_color};font-size:9px;text-transform:uppercase">#{Formatter.esc(pr.state)}</span> #{Formatter.esc(pr.title)}</div>]
          end)
          |> Enum.join()

        parts ++
          [
            ~s[<div style="margin-bottom:12px"><div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Pull Requests</div>#{pr_html}</div>]
          ]
      else
        parts
      end

    # Commits
    parts =
      if data.commits != [] do
        commit_html =
          Enum.map(data.commits, fn c ->
            ~s[<div style="margin-bottom:4px"><span class="c-yellow">#{Formatter.esc(c.hash)}</span> #{Formatter.esc(c.message)}</div>]
          end)
          |> Enum.join()

        parts ++
          [
            ~s[<div style="margin-bottom:12px"><div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Commits</div>#{commit_html}</div>]
          ]
      else
        parts
      end

    # Files changed
    parts =
      if data.files_changed != "" do
        parts ++
          [
            ~s[<div style="margin-bottom:12px"><div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Files Changed</div><div>#{Formatter.esc(data.files_changed)}</div></div>]
          ]
      else
        parts
      end

    # Diff stat
    parts =
      if data.diff_stat != "" do
        parts ++
          [
            ~s[<div style="margin-bottom:12px"><div style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;margin-bottom:4px">Diff Summary</div><div>#{Formatter.colorize_diff(data.diff_stat)}</div></div>]
          ]
      else
        parts
      end

    # Full diff
    parts =
      if data.diff != "" do
        parts ++
          [
            ~s[<div style="margin-bottom:12px"><details><summary style="font-weight:600;color:var(--accent);font-size:10px;text-transform:uppercase;cursor:pointer;margin-bottom:4px">Full Diff</summary><div style="margin-top:4px">#{Formatter.colorize_diff(data.diff)}</div></details></div>]
          ]
      else
        parts
      end

    if parts == [] do
      ~s[<span class="c-dim">(no artifacts yet)</span>]
    else
      Enum.join(parts)
    end
  end
end
