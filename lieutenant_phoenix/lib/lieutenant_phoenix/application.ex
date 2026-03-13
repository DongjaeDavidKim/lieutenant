defmodule Lieutenant.Application do
  @moduledoc false
  use Application

  @lieutenant_dir Path.expand("~/.lieutenant")

  @impl true
  def start(_type, _args) do
    children = [
      LieutenantWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:lieutenant_phoenix, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Lieutenant.PubSub},
      Lieutenant.AgentStore,
      {Lieutenant.PlanStore, plan_path: System.get_env("LIEUTENANT_PLAN_PATH")},
      Lieutenant.AgentPoller,
      LieutenantWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Lieutenant.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Write .port file after endpoint starts (for se-agent discovery)
    case result do
      {:ok, _pid} -> write_port_file()
      _ -> :ok
    end

    result
  end

  @impl true
  def config_change(changed, _new, removed) do
    LieutenantWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp write_port_file do
    spawn(fn ->
      # Give Bandit time to bind
      Process.sleep(1000)
      port = get_port()
      if port do
        File.write!(Path.join(@lieutenant_dir, ".port"), to_string(port))
        IO.puts("Lieutenant → http://localhost:#{port}")
      end
    end)
  end

  def get_port do
    # Try Bandit server_info first, fall back to endpoint config
    case Bandit.PhoenixAdapter.server_info(LieutenantWeb.Endpoint, :http) do
      {:ok, info} ->
        # Bandit returns a map or struct with port
        cond do
          is_map(info) and Map.has_key?(info, :port) -> info.port
          true -> nil
        end

      _ ->
        # Fall back to configured port
        case Application.get_env(:lieutenant_phoenix, LieutenantWeb.Endpoint)[:http] do
          nil -> nil
          http_config -> Keyword.get(http_config, :port, 4000)
        end
    end
  end
end
