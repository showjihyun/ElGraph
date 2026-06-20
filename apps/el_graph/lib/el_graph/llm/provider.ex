defmodule ElGraph.LLM.Provider do
  @moduledoc """
  벤더별 LLM 어댑터가 구현하는 behaviour — `ElGraph.LLM.Driver`가 구동한다.

  Provider는 **진짜 가변인 것만** 공급한다: 요청 형태(`request_spec/4`), 응답 파싱
  (`parse_response/1`), 청크→delta/usage 디코딩(`decode_deltas/2`·`decode_usage/1`).
  전송(Req)·SSE 프레이밍·delta 실시간 방출·응답 fold·usage 병합·telemetry는 Driver에
  **한 번** 산다. 공개 인터페이스 `ElGraph.LLM`(chat/3·stream_chat/3)은 그대로 유지되며,
  각 Provider는 그 두 함수를 Driver로 위임한다.
  """

  alias ElGraph.LLM

  @typedoc "비스트림(:chat)과 스트림(:stream)은 url/body/플래그가 달라질 수 있다."
  @type mode :: :chat | :stream

  @typedoc "한 모델 호출의 요청 명세. model은 telemetry용(body에 없을 수도 있어 분리)."
  @type request :: %{
          url: String.t(),
          headers: [{String.t(), String.t()}],
          body: map(),
          model: String.t()
        }

  @typedoc "청크에서 추출한 부분 usage — Driver가 필드별로 병합한다."
  @type usage_delta :: %{
          optional(:input_tokens) => non_neg_integer(),
          optional(:output_tokens) => non_neg_integer()
        }

  @doc "모드별 요청 명세(url·headers·body·model)를 만든다."
  @callback request_spec(config :: term(), [LLM.message()], opts :: keyword(), mode()) ::
              request()

  @doc "비스트림 응답 바디를 중립 응답으로 파싱한다."
  @callback parse_response(body :: term()) :: {:ok, LLM.response()} | {:error, term()}

  @doc "스트림 디코딩의 초기 상태(예: index→id 매핑). 무상태 Provider는 임의 값."
  @callback init_stream_state() :: term()

  @doc """
  SSE 청크 하나를 delta 목록으로 디코딩하고 다음 상태를 반환한다.

  delta 문법은 무손실이라 Driver가 이 delta들로 (a) 실시간 방출과 (b) 최종 응답 fold를
  모두 수행한다 — 별도 누적 파서가 필요 없다. 상태는 청크 간 정보(OpenAI tool index→id 등)
  를 잇기 위함이다.
  """
  @callback decode_deltas(chunk :: map(), state :: term()) :: {[LLM.delta()], term()}

  @doc "청크에서 부분 usage를 추출한다(없으면 nil). Driver가 누적 병합한다."
  @callback decode_usage(chunk :: map()) :: usage_delta() | nil
end
