defmodule LieutenantWeb.Router do
  use LieutenantWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {LieutenantWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", LieutenantWeb do
    pipe_through :browser

    live "/", DashboardLive
  end

  # Backward-compatible REST API for se-agent and other tools
  scope "/api", LieutenantWeb do
    pipe_through :api

    get "/agents", ApiController, :agents
    get "/plan", ApiController, :plan
    post "/plan/check", ApiController, :plan_check
    post "/plan/set", ApiController, :plan_set
    get "/transcript/:session_id", ApiController, :transcript
    get "/capture/*window", ApiController, :capture
    get "/diff/:ticket", ApiController, :diff
    get "/artifacts/:ticket", ApiController, :artifacts
    post "/send/*window", ApiController, :send_keys
    post "/kill/*window", ApiController, :kill
  end
end
