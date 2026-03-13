defmodule SymphonyElixir.PresenterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Codex.ReasoningLog
  alias SymphonyElixirWeb.Presenter

  test "issue payload includes the local reasoning log file path" do
    issue_id = "issue-presenter"
    issue_identifier = "MT-404"

    issue = %Issue{
      id: issue_id,
      identifier: issue_identifier,
      title: "Presenter reasoning log test",
      description: "Expose log path",
      state: "In Progress",
      url: "https://example.org/issues/MT-404"
    }

    orchestrator_name = Module.concat(__MODULE__, :PresenterOrchestrator)
    {:ok, pid} = Orchestrator.start_link(name: orchestrator_name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    initial_state = :sys.get_state(pid)
    reasoning_log_path = ReasoningLog.path_for_issue(issue_identifier)

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      workspace_path: "/tmp/MT-404",
      reasoning_log_path: reasoning_log_path,
      session_id: "thread-404-turn-1",
      codex_app_server_pid: nil,
      codex_input_tokens: 0,
      codex_output_tokens: 0,
      codex_total_tokens: 0,
      turn_count: 1,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
    end)

    assert {:ok, payload} = Presenter.issue_payload(issue_identifier, orchestrator_name, 1_000)
    assert get_in(payload, [:logs, :codex_session_logs]) == [%{label: "latest", path: reasoning_log_path, url: nil}]

    state_payload = Presenter.state_payload(orchestrator_name, 1_000)
    assert [%{reasoning_log_path: ^reasoning_log_path}] = state_payload.running
  end
end
