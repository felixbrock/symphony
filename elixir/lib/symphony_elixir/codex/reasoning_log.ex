defmodule SymphonyElixir.Codex.ReasoningLog do
  @moduledoc """
  Writes per-issue local logs with readable Codex agent output.
  """

  alias SymphonyElixir.{Codex.Event, LogFile}

  @current_log_name "current.log"

  @spec path_for_issue(String.t()) :: Path.t()
  def path_for_issue(issue_identifier) when is_binary(issue_identifier) do
    issue_identifier
    |> safe_identifier()
    |> then(fn safe_id -> Path.join([logs_root(), safe_id, @current_log_name]) end)
  end

  @spec reset_issue_log(String.t()) :: :ok | {:error, term()}
  def reset_issue_log(issue_identifier) when is_binary(issue_identifier) do
    path = path_for_issue(issue_identifier)
    :ok = File.mkdir_p(Path.dirname(path))
    File.write(path, "")
  end

  @spec delete_issue_log(String.t()) :: :ok | {:error, term()}
  def delete_issue_log(issue_identifier) when is_binary(issue_identifier) do
    issue_identifier
    |> path_for_issue()
    |> Path.dirname()
    |> File.rm_rf()
    |> case do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  @spec append_update(map(), map()) :: :ok | {:error, term()}
  def append_update(issue_metadata, update) when is_map(issue_metadata) and is_map(update) do
    issue_identifier = Map.get(issue_metadata, :issue_identifier)

    cond do
      !is_binary(issue_identifier) ->
        {:error, :missing_issue_identifier}

      is_nil(Event.agent_output_boundary(update)) and !Event.agent_output_update?(update) ->
        :ok

      true ->
        path = path_for_issue(issue_identifier)
        :ok = File.mkdir_p(Path.dirname(path))
        append_update_to_path(path, update)
    end
  end

  def append_update(_issue_metadata, _update), do: {:error, :invalid_arguments}

  defp logs_root do
    log_file = Application.get_env(:symphony_elixir, :log_file, LogFile.default_log_file())
    Path.join(Path.dirname(Path.expand(log_file)), "codex_sessions")
  end

  defp safe_identifier(identifier) do
    String.replace(identifier, ~r/[^a-zA-Z0-9._-]/, "_")
  end

  defp append_update_to_path(path, update) do
    case Event.agent_output_boundary(update) do
      :message_start ->
        append_separator(path)

      nil ->
        case Event.agent_output_chunk(update) do
          nil -> :ok
          chunk -> append_chunk(path, chunk)
        end
    end
  end

  defp append_chunk(path, chunk) when is_binary(path) and is_binary(chunk) do
    existing =
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, :enoent} -> ""
        {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
      end

    case novel_suffix(existing, chunk) do
      "" -> :ok
      suffix -> File.write(path, suffix, [:append])
    end
  end

  defp append_separator(path) when is_binary(path) do
    existing =
      case File.read(path) do
        {:ok, contents} -> contents
        {:error, :enoent} -> ""
        {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
      end

    cond do
      existing == "" ->
        :ok

      String.ends_with?(existing, "\n\n") ->
        :ok

      String.ends_with?(existing, "\n") ->
        File.write(path, "\n", [:append])

      true ->
        File.write(path, "\n\n", [:append])
    end
  end

  defp novel_suffix(existing, chunk) when is_binary(existing) and is_binary(chunk) do
    max_overlap = min(byte_size(existing), byte_size(chunk))

    overlap =
      Enum.find(max_overlap..0//-1, fn size ->
        size == 0 or
          String.ends_with?(existing, binary_part(chunk, 0, size))
      end)

    binary_part(chunk, overlap || 0, byte_size(chunk) - (overlap || 0))
  end
end
