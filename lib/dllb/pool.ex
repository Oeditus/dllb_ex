defmodule Dllb.Pool do
  @moduledoc """
  NimblePool-based connection pool for dllb TCP connections.

  Workers are raw `:gen_tcp` sockets managed through `Dllb.Connection`.
  Dead sockets are detected at checkout and transparently reconnected.
  """

  @behaviour NimblePool

  alias Dllb.Connection

  @doc """
  Returns a child spec for starting the pool under a supervisor.

  ## Options

    * `:host` - server hostname (default from app env or `"127.0.0.1"`)
    * `:port` - server port (default from app env or `3009`)
    * `:pool_size` - number of connections (default from app env or `5`)
    * `:outcome` - response format (default `:json`)
    * `:timeout` - connection/recv timeout in ms (default `30_000`)
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts \\ []) do
    pool_size = Keyword.get(opts, :pool_size, Application.get_env(:dllb, :pool_size, 5))

    %{
      id: __MODULE__,
      start:
        {NimblePool, :start_link,
         [[worker: {__MODULE__, opts}, pool_size: pool_size, name: __MODULE__]]}
    }
  end

  @doc """
  Executes a query through the connection pool.

  Checks out a socket, runs the query via `Dllb.Connection.query/3`,
  and checks the socket back in.

  ## Options

    * `:timeout` - recv timeout in ms (default `30_000`)

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @spec query(String.t(), Keyword.t()) :: {:ok, Dllb.Result.t()} | {:error, term()}
  def query(query_string, opts \\ []) do
    with_telemetry(:query, %{query: query_string}, fn ->
      NimblePool.checkout!(__MODULE__, :checkout, fn _from, socket ->
        result = Connection.query(socket, query_string, opts)
        {result, result}
      end)
    end)
  catch
    :exit, reason -> {:error, {:pool_error, reason}}
  end

  @doc """
  Executes multiple queries through a single pool checkout.

  Checks out one socket, sends all queries sequentially, then checks
  the socket back in. This amortises the pool checkout cost across
  many queries (e.g. bulk AST ingestion).

  Returns a list of `{:ok, result} | {:error, reason}` in the same
  order as the input query strings.
  """
  @spec batch([String.t()], Keyword.t()) :: [{:ok, Dllb.Result.t()} | {:error, term()}]
  def batch(query_strings, opts \\ []) when is_list(query_strings) do
    with_telemetry(:batch, %{queries: query_strings}, fn ->
      NimblePool.checkout!(__MODULE__, :checkout, fn _from, socket ->
        results = run_batch(socket, query_strings, opts)
        {results, results}
      end)
    end)
  catch
    :exit, reason ->
      Enum.map(query_strings, fn _ -> {:error, {:pool_error, reason}} end)
  end

  @doc """
  Executes multiple queries inside a `BEGIN BATCH ... END BATCH` block
  through a single pool checkout.

  All statements run in one server-side storage transaction. Returns a
  single `{:ok, result}` or `{:error, reason}`.
  """
  @spec batch_transaction([String.t()], Keyword.t()) ::
          {:ok, Dllb.Result.t()} | {:error, term()}
  def batch_transaction(query_strings, opts \\ []) when is_list(query_strings) do
    with_telemetry(:batch_transaction, %{queries: query_strings}, fn ->
      NimblePool.checkout!(__MODULE__, :checkout, fn _from, socket ->
        result = Connection.batch_transaction(socket, query_strings, opts)
        {result, result}
      end)
    end)
  catch
    :exit, reason -> {:error, {:pool_error, reason}}
  end

  # -- NimblePool callbacks --------------------------------------------------

  @impl NimblePool
  def init_worker(opts) do
    conn_opts = conn_opts_from_opts(opts)

    case Connection.connect(conn_opts) do
      {:ok, socket} ->
        {:ok, {:connected, socket}, opts}

      {:error, _reason} ->
        # Fail gracefully on startup, enabling lazy reconnection later
        {:ok, {:disconnected, conn_opts}, opts}
    end
  end

  @impl NimblePool
  def handle_checkout(:checkout, _from, {:connected, socket}, opts) do
    if Connection.alive?(socket) do
      {:ok, socket, {:connected, socket}, opts}
    else
      Connection.close(socket)
      conn_opts = conn_opts_from_opts(opts)

      case Connection.connect(conn_opts) do
        {:ok, new_socket} ->
          {:ok, new_socket, {:connected, new_socket}, opts}

        {:error, _reason} ->
          {:reply, {:error, :closed}, {:disconnected, conn_opts}, opts}
      end
    end
  end

  def handle_checkout(:checkout, _from, {:disconnected, conn_opts}, opts) do
    case Connection.connect(conn_opts) do
      {:ok, socket} ->
        {:ok, socket, {:connected, socket}, opts}

      {:error, _reason} ->
        {:reply, {:error, :closed}, {:disconnected, conn_opts}, opts}
    end
  end

  @impl NimblePool
  def handle_checkin(_checkin_result, _from, {:connected, socket}, opts) do
    if Connection.alive?(socket) do
      {:ok, {:connected, socket}, opts}
    else
      {:remove, :closed, opts}
    end
  end

  def handle_checkin(_checkin_result, _from, {:disconnected, _conn_opts} = state, opts) do
    {:ok, state, opts}
  end

  @impl NimblePool
  def handle_info(message, {:connected, socket} = state) do
    case message do
      {:tcp_closed, ^socket} -> {:remove, :closed}
      {:tcp_error, ^socket, _reason} -> {:remove, :tcp_error}
      _ -> {:ok, state}
    end
  end

  def handle_info(_message, {:disconnected, _conn_opts} = state) do
    {:ok, state}
  end

  @impl NimblePool
  def terminate_worker(_reason, {:connected, socket}, opts) do
    Connection.close(socket)
    {:ok, opts}
  end

  def terminate_worker(_reason, {:disconnected, _conn_opts}, opts) do
    {:ok, opts}
  end

  # -- Private Helpers --------------------------------------------------------

  defp conn_opts_from_opts(opts) do
    [
      host: Keyword.get(opts, :host, Application.get_env(:dllb, :host, "127.0.0.1")),
      port: Keyword.get(opts, :port, Application.get_env(:dllb, :port, 3009)),
      outcome: Keyword.get(opts, :outcome, Application.get_env(:dllb, :outcome, :json)),
      timeout: Keyword.get(opts, :timeout, Application.get_env(:dllb, :timeout, 30_000))
    ]
  end

  defp run_batch(socket, query_strings, opts) do
    Enum.map(query_strings, &Connection.query(socket, &1, opts))
  end

  defp with_telemetry(event, metadata, fun) do
    start_time = System.monotonic_time()

    :ok =
      :telemetry.execute([:dllb, event, :start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      duration = System.monotonic_time() - start_time

      :ok =
        :telemetry.execute(
          [:dllb, event, :stop],
          %{duration: duration},
          Map.put(metadata, :result, result)
        )

      result
    catch
      kind, reason ->
        duration = System.monotonic_time() - start_time
        stacktrace = __STACKTRACE__

        exception_metadata =
          metadata
          |> Map.put(:kind, kind)
          |> Map.put(:reason, reason)
          |> Map.put(:stacktrace, stacktrace)

        :ok =
          :telemetry.execute(
            [:dllb, event, :exception],
            %{duration: duration},
            exception_metadata
          )

        :erlang.raise(kind, reason, stacktrace)
    end
  end
end
