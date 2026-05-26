defmodule Dllb.Connection do
  @moduledoc """
  Raw TCP socket operations for communicating with a dllb server.

  This module is **not** a GenServer. It provides stateless functions
  that operate on a `:gen_tcp` socket, suitable for use inside a
  connection pool or standalone.
  """

  alias Dllb.{Protocol, Result}

  @default_host ~c"127.0.0.1"
  @default_port 3009
  @default_outcome :json
  @default_timeout 30_000

  @type opts :: [
          host: String.t() | charlist(),
          port: :inet.port_number(),
          outcome: Protocol.format(),
          timeout: timeout()
        ]

  @doc """
  Opens a TCP connection to the dllb server and sends the `OUTCOME` command.

  ## Options

    * `:host` - server hostname (default `"127.0.0.1"`)
    * `:port` - server port (default `3009`)
    * `:outcome` - response format, one of `:json`, `:toon`, `:csv` (default `:json`)
    * `:timeout` - connection and recv timeout in ms (default `30_000`)

  Returns `{:ok, socket}` or `{:error, reason}`.
  """
  @spec connect(opts()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(opts \\ []) do
    host = resolve_host(Keyword.get(opts, :host, @default_host))
    port = Keyword.get(opts, :port, @default_port)
    outcome = Keyword.get(opts, :outcome, @default_outcome)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    tcp_opts = [:binary, active: false, packet: :line]

    with {:ok, socket} <- :gen_tcp.connect(host, port, tcp_opts, timeout),
         :ok <- :gen_tcp.send(socket, Protocol.outcome_command(outcome)),
         {:ok, _response} <- :gen_tcp.recv(socket, 0, timeout) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends a query over an established socket and returns the parsed result.

  ## Options

    * `:timeout` - recv timeout in ms (default `30_000`)
    * `:outcome` - response format (default `:json`)

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec query(:gen_tcp.socket(), String.t(), Keyword.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def query(socket, query_string, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    outcome = Keyword.get(opts, :outcome, @default_outcome)

    # Drain any residual data left in the socket buffer from a previous
    # response that spanned multiple lines (the dllb server may send
    # multi-line output for certain operations).  Without this, the
    # next recv would read stale data and produce {:invalid_byte, _}.
    drain_socket(socket)

    with :ok <- :gen_tcp.send(socket, Protocol.encode(query_string)),
         {:ok, line} <- recv_full_line(socket, timeout),
         {:ok, decoded} <- Protocol.decode(line, outcome),
         {:ok, result} <- parse_result(decoded, outcome) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sends multiple queries wrapped in a `BEGIN BATCH ... END BATCH` block
  and returns the single aggregated result.

  All statements execute in a single server-side storage transaction,
  eliminating per-statement write-commit overhead.

  ## Options

    * `:timeout` - recv timeout in ms (default `30_000`)
    * `:outcome` - response format (default `:json`)

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec batch_transaction(:gen_tcp.socket(), [String.t()], Keyword.t()) ::
          {:ok, Result.t()} | {:error, term()}
  def batch_transaction(socket, query_strings, opts \\ []) when is_list(query_strings) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    outcome = Keyword.get(opts, :outcome, @default_outcome)

    drain_socket(socket)

    payload =
      IO.iodata_to_binary([
        "BEGIN BATCH\n",
        Enum.map(query_strings, &[&1, "\n"]),
        "END BATCH\n"
      ])

    with :ok <- :gen_tcp.send(socket, payload),
         {:ok, line} <- recv_full_line(socket, timeout),
         {:ok, decoded} <- Protocol.decode(line, outcome),
         {:ok, result} <- parse_result(decoded, outcome) do
      {:ok, result}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Closes the TCP socket.
  """
  @spec close(:gen_tcp.socket()) :: :ok
  def close(socket), do: :gen_tcp.close(socket)

  @doc """
  Checks whether the socket is still open.

  Uses `:inet.peername/1` to determine connectivity without
  consuming data from the socket.
  """
  @spec alive?(:gen_tcp.socket()) :: boolean()
  def alive?(socket) do
    match?({:ok, _}, :inet.peername(socket))
  end

  # -- Private ---------------------------------------------------------------

  # Non-blocking drain: reads and discards any bytes sitting in the socket
  # receive buffer.  Uses `{active, false}` + 0-byte recv with 0 timeout.
  defp drain_socket(socket) do
    # Temporarily switch to raw packet mode so we can read arbitrary bytes
    :inet.setopts(socket, [{:packet, :raw}])
    drain_loop(socket)
    :inet.setopts(socket, [{:packet, :line}])
  end

  defp drain_loop(socket) do
    case :gen_tcp.recv(socket, 0, 0) do
      {:ok, _data} -> drain_loop(socket)
      {:error, :timeout} -> :ok
      {:error, _} -> :ok
    end
  end

  # Reads a complete line (terminated by \n) from the socket, accumulating
  # partial chunks when the response is larger than the internal line buffer.
  # In {:packet, :line} mode, gen_tcp may return a chunk without a trailing
  # \n when the full line hasn't arrived yet.
  defp recv_full_line(socket, timeout) do
    recv_full_line(socket, timeout, [])
  end

  defp recv_full_line(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, chunk} ->
        if String.ends_with?(chunk, "\n") do
          {:ok, IO.iodata_to_binary(Enum.reverse([chunk | acc]))}
        else
          recv_full_line(socket, timeout, [chunk | acc])
        end

      {:error, _} = err ->
        err
    end
  end

  defp resolve_host(host) when is_binary(host), do: String.to_charlist(host)
  defp resolve_host(host) when is_list(host), do: host

  defp parse_result(decoded, :json) when is_map(decoded), do: Result.parse(decoded)
  defp parse_result(raw, _format), do: {:ok, raw}
end
