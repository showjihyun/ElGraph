defmodule ElTraceWeb do
  @moduledoc """
  ElTrace의 웹 인터페이스(Phoenix) 진입점. `use ElTraceWeb, :live_view` 같은 형태로
  컨트롤러/라이브뷰/HTML에 공통 설정을 주입한다 (Phoenix 1.7 컨벤션, 린 버전).
  """

  def static_paths, do: ~w(assets favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:html],
        layouts: [html: ElTraceWeb.Layouts]

      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {ElTraceWeb.Layouts, :app}
      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      import Phoenix.Controller, only: [get_csrf_token: 0]
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      alias Phoenix.LiveView.JS
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ElTraceWeb.Endpoint,
        router: ElTraceWeb.Router,
        statics: ElTraceWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
