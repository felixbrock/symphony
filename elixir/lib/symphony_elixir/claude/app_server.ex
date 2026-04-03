defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Claude Code CLI backend using `--print --output-format stream-json --verbose`.

  Spawns `claude --print` per Symphony turn and resumes the session via
  `--resume <session_id>` when a prior turn exists, preserving conversation
  context across Symphony turns without managing message history manually.

  Implements the same start_session/run_turn/stop_session interface as
  `SymphonyElixir.Codex.AppServer`.
  """

  require Logger
  alias SymphonyElixir.Config

  @port_line_bytes 1_048_576

  @type session :: %{
          session_agent: pid(),
          workspace: Path.t(),
          command: String.t(),
          api_key: String.t() | nil,
          turn_timeout_ms: pos_integer()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, _opts \\ []) do
    claude_config = Config.settings!().claude
    {:ok, agent} = Agent.start_link(fn -> nil end)

    {:ok,
     %{
       session_agent: agent,
       workspace: Path.expand(workspace),
       command: claude_config.command,
       api_key: claude_config.api_key,
       turn_timeout_ms: claude_config.turn_timeout_ms
     }}
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    on_message = Keyword.get(opts, :on_message, fn _msg -> :ok end)
    prior_session_id = Agent.get(session.session_agent, & &1)

    {executable, args} = build_command(session.command, prior_session_id)
    env = build_env(session.api_key)

    Logger.info(
      "Claude CLI starting for #{issue_context(issue)} workspace=#{session.workspace} resume=#{inspect(prior_session_id)}"
    )

    case run_cli(executable, args ++ [prompt], env, session.workspace, session.turn_timeout_ms, on_message) do
      {:ok, new_session_id, result} ->
        Agent.update(session.session_agent, fn _ -> new_session_id end)

        Logger.info(
          "Claude CLI completed for #{issue_context(issue)} session_id=#{new_session_id}"
        )

        {:ok, %{result: result, session_id: new_session_id}}

      {:error, reason} ->
        Logger.warning("Claude CLI failed for #{issue_context(issue)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{session_agent: agent}) do
    Agent.stop(agent)
    :ok
  end

  # --- private ---

  defp build_command(command_str, nil) do
    [executable | args] = String.split(command_str)
    {executable, args}
  end

  defp build_command(command_str, session_id) do
    {executable, args} = build_command(command_str, nil)
    {executable, args ++ ["--resume", session_id]}
  end

  defp build_env(nil), do: []
  defp build_env(""), do: []
  defp build_env(api_key), do: [{"ANTHROPIC_API_KEY", api_key}]

  defp run_cli(executable, args, env, workspace, timeout_ms, on_message) do
    resolved = System.find_executable(executable) || executable

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(resolved)},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          {:args, Enum.map(args, &String.to_charlist/1)},
          {:cd, String.to_charlist(workspace)},
          {:env, Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)},
          {:line, @port_line_bytes}
        ]
      )

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_output(port, %{session_id: nil, result: nil, partial: ""}, deadline, on_message)
  end

  defp collect_output(port, acc, deadline, on_message) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Port.close(port)
      {:error, :turn_timeout}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          full_line = acc.partial <> line
          acc = process_line(full_line, %{acc | partial: ""}, on_message)
          collect_output(port, acc, deadline, on_message)

        {^port, {:data, {:noeol, chunk}}} ->
          collect_output(port, %{acc | partial: acc.partial <> chunk}, deadline, on_message)

        {^port, {:exit_status, 0}} ->
          case acc.session_id do
            nil -> {:error, :no_session_id_in_output}
            id -> {:ok, id, acc.result || ""}
          end

        {^port, {:exit_status, code}} ->
          {:error, {:cli_exit_code, code}}
      after
        min(remaining, 30_000) ->
          collect_output(port, acc, deadline, on_message)
      end
    end
  end

  defp process_line(line, acc, on_message) do
    case Jason.decode(line) do
      {:ok, event} -> handle_event(event, acc, on_message)
      _ -> acc
    end
  end

  defp handle_event(%{"type" => "system", "session_id" => id}, acc, _on_message) do
    %{acc | session_id: id}
  end

  defp handle_event(%{"type" => "assistant", "message" => %{"content" => content}}, acc, on_message) do
    text = extract_text(content)
    if text != "", do: on_message.(%{type: "agent_response", content: text})
    acc
  end

  defp handle_event(%{"type" => "result", "result" => result}, acc, _on_message) do
    %{acc | result: result}
  end

  defp handle_event(_event, acc, _on_message), do: acc

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end

  defp extract_text(_), do: ""

  defp issue_context(%{identifier: id}) when is_binary(id), do: "issue_identifier=#{id}"
  defp issue_context(_), do: "issue=unknown"
end
