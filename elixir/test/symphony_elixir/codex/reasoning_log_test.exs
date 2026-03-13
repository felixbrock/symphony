defmodule SymphonyElixir.Codex.ReasoningLogTest do
  use ExUnit.Case

  alias SymphonyElixir.Codex.ReasoningLog

  setup do
    log_root =
      Path.join(System.tmp_dir!(), "symphony-reasoning-log-test-#{System.unique_integer([:positive])}")

    log_file = Path.join(log_root, "symphony.log")
    previous_log_file = Application.get_env(:symphony_elixir, :log_file)
    Application.put_env(:symphony_elixir, :log_file, log_file)

    on_exit(fn ->
      if is_nil(previous_log_file) do
        Application.delete_env(:symphony_elixir, :log_file)
      else
        Application.put_env(:symphony_elixir, :log_file, previous_log_file)
      end

      File.rm_rf(log_root)
    end)

    %{log_root: log_root}
  end

  test "path_for_issue/1 sanitizes identifiers under codex_sessions", %{log_root: log_root} do
    assert ReasoningLog.path_for_issue("MT/303 weird") ==
             Path.join([log_root, "codex_sessions", "MT_303_weird", "current.log"])
  end

  test "reset_issue_log/1 creates and truncates the readable log", %{log_root: log_root} do
    path = Path.join([log_root, "codex_sessions", "MT-303", "current.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "existing")

    assert :ok = ReasoningLog.reset_issue_log("MT-303")
    assert File.read!(path) == ""
  end

  test "append_update/2 validates metadata and ignores non-output events" do
    assert ReasoningLog.append_update(:bad, %{}) == {:error, :invalid_arguments}

    assert ReasoningLog.append_update(%{}, %{payload: %{method: "item/agentMessage/delta"}}) ==
             {:error, :missing_issue_identifier}

    assert ReasoningLog.append_update(
             %{issue_identifier: "MT-303"},
             %{payload: %{method: "item/reasoning/textDelta", params: %{delta: "ignored"}}}
           ) == :ok
  end

  test "append_update/2 appends readable output, deduplicates prefixes, and inserts separators", %{
    log_root: log_root
  } do
    path = Path.join([log_root, "codex_sessions", "MT-303", "current.log"])
    metadata = %{issue_identifier: "MT-303"}

    assert :ok =
             ReasoningLog.append_update(metadata, %{
               payload: %{method: "item/agentMessage/delta", params: %{delta: "I"}}
             })

    assert :ok =
             ReasoningLog.append_update(metadata, %{
               payload: %{method: "item/agentMessage/delta", params: %{delta: "I’m inspecting"}}
             })

    assert :ok =
             ReasoningLog.append_update(metadata, %{payload: %{method: "codex/event/agent_message"}})

    assert :ok =
             ReasoningLog.append_update(metadata, %{
               payload: %{method: "item/agentMessage/delta", params: %{delta: "Next block"}}
             })

    assert File.read!(path) == "I’m inspecting\n\nNext block"
  end

  test "append_update/2 ignores empty output chunks and exact duplicate chunks", %{log_root: log_root} do
    path = Path.join([log_root, "codex_sessions", "MT-308", "current.log"])
    metadata = %{issue_identifier: "MT-308"}

    assert :ok =
             ReasoningLog.append_update(metadata, %{
               payload: %{method: "item/agentMessage/delta", params: %{delta: ""}}
             })

    assert File.read(path) == {:error, :enoent}

    assert :ok =
             ReasoningLog.append_update(metadata, %{
               payload: %{method: "item/agentMessage/delta", params: %{delta: "stable"}}
             })

    assert :ok =
             ReasoningLog.append_update(metadata, %{
               payload: %{method: "item/agentMessage/delta", params: %{delta: "stable"}}
             })

    assert File.read!(path) == "stable"
  end

  test "append_update/2 does not prepend separators to an empty file", %{log_root: log_root} do
    path = Path.join([log_root, "codex_sessions", "MT-304", "current.log"])

    assert :ok =
             ReasoningLog.append_update(
               %{issue_identifier: "MT-304"},
               %{payload: %{method: "codex/event/agent_message"}}
             )

    assert File.read(path) == {:error, :enoent}
  end

  test "append_update/2 extends a trailing newline into a blank-line separator", %{log_root: log_root} do
    path = Path.join([log_root, "codex_sessions", "MT-305", "current.log"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "Existing line\n")

    assert :ok =
             ReasoningLog.append_update(
               %{issue_identifier: "MT-305"},
               %{payload: %{method: "codex/event/agent_message"}}
             )

    assert File.read!(path) == "Existing line\n\n"
  end

  test "append_update/2 raises on unexpected read errors for chunks", %{log_root: log_root} do
    path = Path.join([log_root, "codex_sessions", "MT-306", "current.log"])
    File.mkdir_p!(path)

    assert_raise File.Error, fn ->
      ReasoningLog.append_update(
        %{issue_identifier: "MT-306"},
        %{payload: %{method: "item/agentMessage/delta", params: %{delta: "hello"}}}
      )
    end
  end

  test "append_update/2 raises on unexpected read errors for separators", %{log_root: log_root} do
    path = Path.join([log_root, "codex_sessions", "MT-307", "current.log"])
    File.mkdir_p!(path)

    assert_raise File.Error, fn ->
      ReasoningLog.append_update(
        %{issue_identifier: "MT-307"},
        %{payload: %{method: "codex/event/agent_message"}}
      )
    end
  end
end
