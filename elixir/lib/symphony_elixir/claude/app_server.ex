defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Claude agent backend using the Anthropic Messages API with a bash tool.

  Implements the same start_session/run_turn/stop_session interface as
  `SymphonyElixir.Codex.AppServer`, allowing the two providers to be
  used interchangeably by `AgentRunner`.
  """

  require Logger
  alias SymphonyElixir.Config

  @api_url "https://api.anthropic.com/v1/messages"
  @anthropic_version "2023-06-01"
  @bash_tool %{
    "name" => "bash",
    "description" => "Run a shell command in the workspace directory. Use this to read files, write files, run tests, execute git commands, and perform any other workspace operations.",
    "input_schema" => %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "Shell command to run in the workspace"
        }
      },
      "required" => ["command"]
    }
  }

  @type session :: %{
          api_key: String.t(),
          model: String.t(),
          max_tokens: pos_integer(),
          turn_timeout_ms: pos_integer(),
          workspace: Path.t(),
          worker_host: String.t() | nil,
          messages: [map()]
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    worker_host = Keyword.get(opts, :worker_host)
    claude_config = Config.settings!().claude

    case claude_config.api_key do
      nil ->
        {:error, :missing_anthropic_api_key}

      "" ->
        {:error, :missing_anthropic_api_key}

      api_key ->
        expanded_workspace = Path.expand(workspace)

        {:ok,
         %{
           api_key: api_key,
           model: claude_config.model,
           max_tokens: claude_config.max_tokens,
           turn_timeout_ms: claude_config.turn_timeout_ms,
           workspace: expanded_workspace,
           worker_host: worker_host,
           messages: []
         }}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, _issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    messages = session.messages ++ [%{"role" => "user", "content" => prompt}]

    deadline = System.monotonic_time(:millisecond) + session.turn_timeout_ms

    case agentic_loop(session, messages, on_message, deadline) do
      {:ok, final_messages} ->
        {:ok, %{session_id: generate_session_id(), messages: final_messages}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(_session), do: :ok

  defp agentic_loop(session, messages, on_message, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :turn_timeout}
    else
      request_body = %{
        "model" => session.model,
        "max_tokens" => session.max_tokens,
        "tools" => [@bash_tool],
        "messages" => messages
      }

      case call_api(session.api_key, request_body, min(remaining_ms, 120_000)) do
        {:ok, %{"stop_reason" => "end_turn", "content" => content}} ->
          text = extract_text(content)
          on_message.(%{type: "agent_response", content: text})
          Logger.info("Claude turn completed workspace=#{session.workspace}")
          {:ok, messages ++ [%{"role" => "assistant", "content" => content}]}

        {:ok, %{"stop_reason" => "tool_use", "content" => content}} ->
          on_message.(%{type: "tool_use", content: summarize_tool_calls(content)})
          updated_messages = messages ++ [%{"role" => "assistant", "content" => content}]

          case execute_tool_calls(content, session.workspace) do
            {:ok, tool_results} ->
              next_messages = updated_messages ++ [%{"role" => "user", "content" => tool_results}]
              agentic_loop(session, next_messages, on_message, deadline)

            {:error, reason} ->
              {:error, reason}
          end

        {:error, :credits_exhausted} ->
          {:error, :claude_credits_exhausted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp call_api(api_key, body, timeout_ms) do
    headers = [
      {"x-api-key", api_key},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"}
    ]

    case Req.post(@api_url, json: body, headers: headers, receive_timeout: timeout_ms) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: 402}} ->
        {:error, :credits_exhausted}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.error("Claude API error status=#{status} body=#{inspect(response_body)}")
        {:error, {:claude_api_error, status, response_body}}

      {:error, reason} ->
        Logger.error("Claude API request failed: #{inspect(reason)}")
        {:error, {:claude_request_failed, reason}}
    end
  end

  defp execute_tool_calls(content, workspace) do
    tool_uses = Enum.filter(content, fn block -> block["type"] == "tool_use" end)

    results =
      Enum.map(tool_uses, fn %{"id" => tool_use_id, "name" => "bash", "input" => %{"command" => command}} ->
        Logger.debug("Claude bash tool command=#{inspect(command)} workspace=#{workspace}")
        {output, exit_code} = System.cmd("bash", ["-c", command], cd: workspace, stderr_to_stdout: true)

        result_content =
          if exit_code == 0 do
            output
          else
            "Exit code #{exit_code}\n#{output}"
          end

        %{
          "type" => "tool_result",
          "tool_use_id" => tool_use_id,
          "content" => result_content
        }
      end)

    {:ok, results}
  rescue
    e ->
      {:error, {:tool_execution_error, Exception.message(e)}}
  end

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn block -> block["type"] == "text" end)
    |> Enum.map_join("\n", fn %{"text" => text} -> text end)
  end

  defp extract_text(_), do: ""

  defp summarize_tool_calls(content) when is_list(content) do
    content
    |> Enum.filter(fn block -> block["type"] == "tool_use" end)
    |> Enum.map_join(", ", fn %{"name" => name, "input" => input} ->
      cmd = Map.get(input, "command", "")
      truncated = if String.length(cmd) > 80, do: String.slice(cmd, 0, 80) <> "…", else: cmd
      "#{name}(#{truncated})"
    end)
  end

  defp summarize_tool_calls(_), do: ""

  defp generate_session_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
