defmodule ElTraceWeb.Router do
  use ElTraceWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {ElTraceWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", ElTraceWeb do
    pipe_through(:browser)

    live("/", TimelineLive, :index)
  end
end
