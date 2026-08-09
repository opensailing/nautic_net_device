defmodule RacingOrg.Tracker.Pro.DesiredState.OperationalGate.AuthorityRequest do
  @moduledoc false

  @spec new(term()) :: reference()
  def new(operation) do
    request_token = :ets.new(__MODULE__, [:set, :protected])
    true = :ets.insert_new(request_token, {:request, operation})
    request_token
  end

  @spec delete(reference()) :: :ok
  def delete(request_token) when is_reference(request_token) do
    :ets.delete(request_token)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @spec call(GenServer.server(), pid(), term(), timeout()) :: term()
  def call(server, principal_pid, operation, timeout \\ 5_000)

  def call(server, principal_pid, operation, timeout)
      when is_pid(principal_pid) and principal_pid == self() do
    request_token = new(operation)

    try do
      GenServer.call(
        server,
        {:authority_request, principal_pid, request_token, operation},
        timeout
      )
    after
      delete(request_token)
    end
  end

  def call(_server, _principal_pid, _operation, _timeout),
    do: {:error, :invalid_authority_principal}

  @spec valid?(reference(), pid(), term()) :: boolean()
  def valid?(request_token, principal_pid, operation)
      when is_reference(request_token) and is_pid(principal_pid) do
    Process.alive?(principal_pid) and
      :ets.info(request_token, :owner) == principal_pid and
      :ets.info(request_token, :protection) == :protected and
      :ets.lookup(request_token, :request) == [{:request, operation}] and
      :ets.info(request_token, :owner) == principal_pid and
      Process.alive?(principal_pid)
  rescue
    ArgumentError -> false
  end

  def valid?(_request_token, _principal_pid, _operation), do: false
end
