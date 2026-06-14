defmodule ElGraph.Sandbox.Command do
  @moduledoc """
  외부 인터프리터에 위임하는 `ElGraph.Sandbox` 어댑터.

  실제 격리는 호스트가 책임진다 — 이 어댑터는 컨테이너/제한된 사용자/마이크로VM 안에서
  구동될 것을 전제로 인터프리터 프로세스를 띄울 뿐, 자체적으로 격리를 보장하지 않는다.
  `:runner`(테스트 주입용, 기본 `System.cmd`)로 실행을 가로챌 수 있다.

  지원 언어: `"elixir"`, `"python"`, `"node"`, `"ruby"`, `"bash"`.
  """

  @behaviour ElGraph.Sandbox

  @interpreters %{
    "elixir" => {"elixir", "-e"},
    "python" => {"python", "-c"},
    "node" => {"node", "-e"},
    "ruby" => {"ruby", "-e"},
    "bash" => {"bash", "-c"}
  }

  @impl ElGraph.Sandbox
  def run(code, opts \\ []) when is_binary(code) do
    language = opts[:language] || "elixir"

    case Map.fetch(@interpreters, language) do
      {:ok, {cmd, flag}} -> exec(cmd, flag, code, opts)
      :error -> {:error, {:unsupported_language, language}}
    end
  end

  defp exec(cmd, flag, code, opts) do
    runner = opts[:runner] || (&default_runner/3)

    case runner.(cmd, [flag, code], stderr_to_stdout: true) do
      {output, 0} -> {:ok, %{stdout: output, exit_code: 0}}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp default_runner(cmd, args, opts), do: System.cmd(cmd, args, opts)
end
