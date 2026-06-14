defmodule ElTraceWeb.ErrorHTML do
  use ElTraceWeb, :html

  # "404.html" -> "Not Found", "500.html" -> "Internal Server Error" 등 상태 메시지로 렌더.
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
