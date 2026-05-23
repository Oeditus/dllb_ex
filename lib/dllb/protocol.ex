defmodule Dllb.Protocol do
  @moduledoc """
  Encodes queries to dllb wire format and decodes responses.

  The dllb protocol is line-based text over TCP: each query is a string
  terminated by `\\n`, and each response is a JSON (or toon/csv) line
  terminated by `\\n`.
  """

  @type format :: :json | :toon | :csv

  @doc """
  Encodes a query string into wire format (iodata) by appending a newline.
  """
  @spec encode(String.t()) :: iodata()
  def encode(query) when is_binary(query), do: [query, ?\n]

  @doc """
  Decodes a response line received from the server.

  For `:json` format, parses the line using OTP's built-in `:json` module.
  For `:toon` and `:csv`, returns the raw string (trimmed) for now.

  Returns `{:ok, parsed}` or `{:error, reason}`.
  """
  @spec decode(String.t(), format()) :: {:ok, map() | String.t()} | {:error, term()}
  def decode(line, format \\ :json)

  def decode(line, :json) when is_binary(line) do
    trimmed = String.trim_trailing(line, "\n")

    case :json.decode(trimmed) do
      decoded when is_map(decoded) -> {:ok, decoded}
      other -> {:ok, other}
    end
  rescue
    e -> {:error, {:protocol_error, Exception.message(e)}}
  end

  def decode(line, format) when format in [:toon, :csv] and is_binary(line) do
    {:ok, String.trim_trailing(line, "\n")}
  end

  @doc """
  Returns the `OUTCOME` command to send upon connection to set the response format.
  """
  @spec outcome_command(format()) :: iodata()
  def outcome_command(:json), do: "OUTCOME json\n"
  def outcome_command(:toon), do: "OUTCOME toon\n"
  def outcome_command(:csv), do: "OUTCOME csv\n"
end
