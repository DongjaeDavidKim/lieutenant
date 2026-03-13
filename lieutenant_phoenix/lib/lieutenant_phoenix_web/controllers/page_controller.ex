defmodule LieutenantWeb.PageController do
  use LieutenantWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
