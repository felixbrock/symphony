defmodule SymphonyElixir.Codex.Event do
  @moduledoc """
  Helpers for classifying and extracting structured Codex event details.
  """

  @reasoning_methods MapSet.new([
                       "item/reasoning/summaryTextDelta",
                       "item/reasoning/summaryPartAdded",
                       "item/reasoning/textDelta"
                     ])

  @reasoning_wrapper_suffixes MapSet.new([
                                "agent_reasoning_delta",
                                "reasoning_content_delta",
                                "agent_reasoning",
                                "agent_reasoning_section_break"
                              ])

  @agent_output_methods MapSet.new([
                          "item/agentMessage/delta"
                        ])

  @agent_output_wrapper_suffixes MapSet.new([
                                   "agent_message_delta",
                                   "agent_message_content_delta"
                                 ])

  @type update :: map()

  @spec reasoning_update?(update()) :: boolean()
  def reasoning_update?(update) when is_map(update) do
    case method(update) do
      method when is_binary(method) ->
        reasoning_method?(method)

      _ ->
        false
    end
  end

  def reasoning_update?(_update), do: false

  @spec agent_output_update?(update()) :: boolean()
  def agent_output_update?(update) when is_map(update) do
    case method(update) do
      method when is_binary(method) ->
        agent_output_method?(method)

      _ ->
        false
    end
  end

  def agent_output_update?(_update), do: false

  @spec method(update()) :: String.t() | nil
  def method(update) when is_map(update) do
    payload = payload(update)
    payload_method = map_value(payload, ["method", :method])
    wrapped_type = extract_first_path(payload, [["params", "msg", "type"], [:params, :msg, :type]])

    cond do
      is_binary(payload_method) ->
        payload_method

      is_binary(wrapped_type) ->
        "codex/event/" <> wrapped_type

      true ->
        nil
    end
  end

  def method(_update), do: nil

  @spec payload(update()) :: map() | term()
  def payload(update) when is_map(update) do
    Map.get(update, :payload) || Map.get(update, "payload") || update
  end

  def payload(update), do: update

  @spec reasoning_text(update()) :: String.t() | nil
  def reasoning_text(update) when is_map(update) do
    value =
      payload(update)
      |> extract_first_path(reasoning_paths())

    normalize_text(value)
  end

  def reasoning_text(_update), do: nil

  @spec reasoning_preview(update()) :: String.t() | nil
  def reasoning_preview(update) when is_map(update) do
    update
    |> reasoning_text()
    |> truncate(160)
  end

  def reasoning_preview(_update), do: nil

  @spec agent_output_chunk(update()) :: String.t() | nil
  def agent_output_chunk(update) when is_map(update) do
    value =
      payload(update)
      |> extract_first_path(agent_output_paths())

    normalize_chunk(value)
  end

  def agent_output_chunk(_update), do: nil

  @spec agent_output_boundary(update()) :: :message_start | nil
  def agent_output_boundary(update) when is_map(update) do
    case method(update) do
      "codex/event/item_started" ->
        if wrapper_payload_type(payload(update)) == "agent_message", do: :message_start, else: nil

      "codex/event/agent_message" ->
        :message_start

      _ ->
        nil
    end
  end

  def agent_output_boundary(_update), do: nil

  defp reasoning_method?(method) when is_binary(method) do
    MapSet.member?(@reasoning_methods, method) or
      reasoning_wrapper_method?(method)
  end

  defp reasoning_wrapper_method?(<<"codex/event/", suffix::binary>>) do
    MapSet.member?(@reasoning_wrapper_suffixes, suffix)
  end

  defp reasoning_wrapper_method?(_method), do: false

  defp agent_output_method?(method) when is_binary(method) do
    MapSet.member?(@agent_output_methods, method) or
      agent_output_wrapper_method?(method)
  end

  defp agent_output_wrapper_method?(<<"codex/event/", suffix::binary>>) do
    MapSet.member?(@agent_output_wrapper_suffixes, suffix)
  end

  defp agent_output_wrapper_method?(_method), do: false

  defp normalize_text(value) when is_binary(value) do
    trimmed =
      value
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_text(values) when is_list(values) do
    values
    |> Enum.map(&normalize_text/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      normalized -> Enum.join(normalized, " | ")
    end
  end

  defp normalize_text(%{} = value) do
    value
    |> inspect(pretty: false, limit: 20)
    |> normalize_text()
  end

  defp normalize_text(_value), do: nil

  defp normalize_chunk(value) when is_binary(value) do
    chunk = String.replace(value, "\r", "")
    if chunk == "", do: nil, else: chunk
  end

  defp normalize_chunk(values) when is_list(values) do
    values
    |> Enum.map(&normalize_chunk/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      normalized -> Enum.join(normalized)
    end
  end

  defp normalize_chunk(_value), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) and is_integer(max) do
    if String.length(text) > max do
      String.slice(text, 0, max - 3) <> "..."
    else
      text
    end
  end

  defp reasoning_paths do
    [
      ["params", "reason"],
      [:params, :reason],
      ["params", "summaryText"],
      [:params, :summaryText],
      ["params", "summary"],
      [:params, :summary],
      ["params", "text"],
      [:params, :text],
      ["params", "msg", "reason"],
      [:params, :msg, :reason],
      ["params", "msg", "summaryText"],
      [:params, :msg, :summaryText],
      ["params", "msg", "summary"],
      [:params, :msg, :summary],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "reason"],
      [:params, :msg, :payload, :reason],
      ["params", "msg", "payload", "summaryText"],
      [:params, :msg, :payload, :summaryText],
      ["params", "msg", "payload", "summary"],
      [:params, :msg, :payload, :summary],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content],
      ["params", "delta"],
      [:params, :delta],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "outputDelta"],
      [:params, :outputDelta],
      ["params", "msg", "outputDelta"],
      [:params, :msg, :outputDelta]
    ]
  end

  defp agent_output_paths do
    [
      ["params", "delta"],
      [:params, :delta],
      ["params", "textDelta"],
      [:params, :textDelta],
      ["params", "text"],
      [:params, :text],
      ["params", "content"],
      [:params, :content],
      ["params", "msg", "delta"],
      [:params, :msg, :delta],
      ["params", "msg", "textDelta"],
      [:params, :msg, :textDelta],
      ["params", "msg", "text"],
      [:params, :msg, :text],
      ["params", "msg", "content"],
      [:params, :msg, :content],
      ["params", "msg", "payload", "delta"],
      [:params, :msg, :payload, :delta],
      ["params", "msg", "payload", "textDelta"],
      [:params, :msg, :payload, :textDelta],
      ["params", "msg", "payload", "text"],
      [:params, :msg, :payload, :text],
      ["params", "msg", "payload", "content"],
      [:params, :msg, :payload, :content]
    ]
  end

  defp wrapper_payload_type(payload) do
    extract_first_path(payload, [
      ["params", "msg", "payload", "type"],
      [:params, :msg, :payload, :type]
    ])
  end

  defp extract_first_path(payload, paths) do
    Enum.find_value(paths, fn path -> map_path(payload, path) end)
  end

  defp map_path(data, [key | rest]) when is_map(data) do
    case fetch_map_key(data, key) do
      {:ok, value} when rest == [] -> value
      {:ok, value} -> map_path(value, rest)
      :error -> nil
    end
  end

  defp map_path(_data, _path), do: nil

  defp map_value(data, keys) when is_map(data) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case fetch_map_key(data, key) do
        {:ok, value} -> value
        :error -> nil
      end
    end)
  end

  defp map_value(_data, _keys), do: nil

  defp fetch_map_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error when is_atom(key) ->
        Map.fetch(map, Atom.to_string(key))

      :error when is_binary(key) ->
        fetch_atom_string_key(map, key)
    end
  end

  defp fetch_atom_string_key(map, key) when is_map(map) and is_binary(key) do
    Enum.find_value(map, :error, fn
      {map_key, value} when is_atom(map_key) ->
        if Atom.to_string(map_key) == key, do: {:ok, value}, else: false

      _entry ->
        false
    end)
  end
end
