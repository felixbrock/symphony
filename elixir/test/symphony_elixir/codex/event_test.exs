defmodule SymphonyElixir.Codex.EventTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Codex.Event

  test "reasoning_update?/1 recognizes direct and wrapped reasoning events" do
    assert Event.reasoning_update?(%{payload: %{method: "item/reasoning/textDelta"}})
    assert Event.reasoning_update?(%{payload: %{method: "codex/event/agent_reasoning_delta"}})
    refute Event.reasoning_update?(%{payload: %{method: "codex/event/agent_message"}})
    refute Event.reasoning_update?(%{payload: %{method: "plain"}})
    refute Event.reasoning_update?(%{payload: "raw"})
    refute Event.reasoning_update?(:not_a_map)
  end

  test "agent_output_update?/1 recognizes direct and wrapped agent message events" do
    assert Event.agent_output_update?(%{payload: %{method: "item/agentMessage/delta"}})
    assert Event.agent_output_update?(%{payload: %{method: "codex/event/agent_message_content_delta"}})
    refute Event.agent_output_update?(%{payload: %{method: "item/reasoning/textDelta"}})
    refute Event.agent_output_update?(%{payload: %{method: 123}})
    refute Event.agent_output_update?(:not_a_map)
  end

  test "method/1 resolves explicit methods and wrapped codex event types" do
    assert Event.method(%{payload: %{method: "item/agentMessage/delta"}}) ==
             "item/agentMessage/delta"

    assert Event.method(%{payload: %{"params" => %{"msg" => %{"type" => "agent_message"}}}}) ==
             "codex/event/agent_message"

    assert Event.method(%{payload: %{params: %{msg: %{type: "agent_message_delta"}}}}) ==
             "codex/event/agent_message_delta"

    assert Event.method(%{payload: "raw"}) == nil
    assert Event.method(%{payload: %{params: %{msg: %{type: 123}}}}) == nil
    assert Event.method(:not_a_map) == nil
  end

  test "payload/1 prefers embedded payload maps and falls back to input" do
    assert Event.payload(%{payload: %{method: "x"}}) == %{method: "x"}
    assert Event.payload(%{"payload" => %{"method" => "x"}}) == %{"method" => "x"}
    assert Event.payload(%{method: "x"}) == %{method: "x"}
    assert Event.payload("raw") == "raw"
  end

  test "reasoning_text/1 normalizes strings, lists, maps, and wrapped payload paths" do
    assert Event.reasoning_text(%{payload: %{params: %{delta: " one\n two "}}}) == "one two"

    assert Event.reasoning_text(%{
             payload: %{
               params: %{
                 msg: %{payload: %{summary: [" first ", "", "second\nline"]}}
               }
             }
           }) == "first | second line"

    assert Event.reasoning_text(%{
             payload: %{
               "params" => %{"msg" => %{"payload" => %{"content" => %{step: "inspect"}}}}
             }
           }) =~ "%{step: \"inspect\"}"

    assert Event.reasoning_text(%{payload: %{params: %{summary: ["", "   "]}}}) == nil
    assert Event.reasoning_text(%{payload: %{params: %{reason: 123}}}) == nil
    assert Event.reasoning_text(%{payload: %{params: "not-a-map"}}) == nil
    assert Event.reasoning_text(%{payload: %{params: %{text: ""}}}) == nil
    assert Event.reasoning_text(:not_a_map) == nil
  end

  test "reasoning_preview/1 truncates long reasoning text and handles nil" do
    long_text = String.duplicate("a", 170)
    preview = Event.reasoning_preview(%{payload: %{params: %{text: long_text}}})

    assert String.length(preview) == 160
    assert String.ends_with?(preview, "...")
    assert Event.reasoning_preview(%{payload: %{params: %{text: "short"}}}) == "short"
    assert Event.reasoning_preview(%{payload: %{params: %{text: ""}}}) == nil
    assert Event.reasoning_preview(:not_a_map) == nil
  end

  test "agent_output_chunk/1 extracts visible output and removes carriage returns" do
    assert Event.agent_output_chunk(%{payload: %{params: %{delta: "hello\r\n"}}}) == "hello\n"

    assert Event.agent_output_chunk(%{
             payload: %{
               "params" => %{"msg" => %{"payload" => %{"content" => ["a", "", "b"]}}}
             }
           }) == "ab"

    assert Event.agent_output_chunk(%{payload: %{params: %{content: ["", ""]}}}) == nil
    assert Event.agent_output_chunk(%{payload: %{params: %{delta: ""}}}) == nil
    assert Event.agent_output_chunk(%{payload: %{params: %{delta: %{bad: true}}}}) == nil
    assert Event.agent_output_chunk(:not_a_map) == nil
  end

  test "agent_output_boundary/1 identifies message boundaries" do
    assert Event.agent_output_boundary(%{
             payload: %{
               method: "codex/event/item_started",
               params: %{msg: %{payload: %{type: "agent_message"}}}
             }
           }) == :message_start

    assert Event.agent_output_boundary(%{payload: %{method: "codex/event/agent_message"}}) ==
             :message_start

    assert Event.agent_output_boundary(%{
             payload: %{
               method: "codex/event/item_started",
               params: %{msg: %{payload: %{type: "reasoning"}}}
             }
           }) == nil

    assert Event.agent_output_boundary(%{
             payload: %{
               "method" => "codex/event/item_started",
               "params" => %{"msg" => %{"payload" => %{"type" => "agent_message"}}}
             }
           }) == :message_start

    assert Event.agent_output_boundary(%{payload: %{method: "item/agentMessage/delta"}}) == nil
    assert Event.agent_output_boundary(:not_a_map) == nil
  end

  test "reasoning_update?/1 returns false for unrelated wrapped events" do
    refute Event.reasoning_update?(%{payload: %{method: "codex/event/not_reasoning"}})
  end
end
