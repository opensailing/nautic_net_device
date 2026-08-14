defmodule RacingOrg.Tracker.Pro.Diagnostics do
  @moduledoc """
  Operator-facing device diagnostics: a closed, sanitized summary safe to read
  over the serial console or paste into a support ticket.

  Each section comes from an injectable zero-arity reader (production readers
  by default) and fails closed to `:unavailable` on any fault — a dead
  collaborator never breaks the rest of the summary. A defense-in-depth
  sanitizer then redacts anything a reader leaks that is not an atom, number,
  or hex identifier: hex identifiers are truncated to #{12} characters,
  structs/pids/functions/paths/free-text collapse to `:redacted`, and depth
  and list size are bounded. Plaintext secrets, key material, session
  identifiers, and filesystem paths can therefore never ride out through
  diagnostics even if a collaborator's status shape regresses.
  """

  alias RacingOrg.Tracker.Pro.DesiredState.Manager
  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Owner, as: OutboxOwner
  alias RacingOrg.Tracker.Pro.FirmwareValidation
  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @sections [:product, :boot, :session, :outbox, :desired_state, :gate, :firmware_validation]
  @max_depth 4
  @max_list 16
  @hex_prefix 12

  @doc """
  The sanitized device summary. `:readers` overrides the production section
  readers (`%{section => (-> map())}`) for tests and partial deployments.
  """
  @spec summary(keyword()) :: %{required(atom()) => map() | :unavailable}
  def summary(opts \\ []) do
    readers = Keyword.get(opts, :readers, production_readers())
    Map.new(@sections, fn section -> {section, section_value(readers, section)} end)
  end

  defp section_value(readers, section) do
    case Map.fetch(readers, section) do
      {:ok, reader} when is_function(reader, 0) -> read_section(reader)
      _missing_or_malformed -> :unavailable
    end
  end

  defp read_section(reader) do
    case sanitize(reader.(), 0) do
      %{} = section -> section
      _not_a_map -> :unavailable
    end
  rescue
    _exception -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  defp sanitize(_term, depth) when depth > @max_depth, do: :redacted

  defp sanitize(term, _depth) when is_atom(term) or is_integer(term) or is_float(term), do: term

  defp sanitize(term, _depth) when is_binary(term), do: sanitize_binary(term)

  defp sanitize(%_struct{}, _depth), do: :redacted

  defp sanitize(term, depth) when is_map(term) do
    for {key, value} <- term, is_atom(key), into: %{}, do: {key, sanitize(value, depth + 1)}
  end

  defp sanitize(term, depth) when is_list(term) do
    term |> Enum.take(@max_list) |> Enum.map(&sanitize(&1, depth + 1))
  end

  defp sanitize(term, depth) when is_tuple(term) and tuple_size(term) in 1..4 do
    term |> Tuple.to_list() |> Enum.map(&sanitize(&1, depth + 1)) |> List.to_tuple()
  end

  defp sanitize(_term, _depth), do: :redacted

  # Only lowercase-hex identifiers survive as strings, truncated to a short
  # prefix (a full digest identifies; a prefix merely correlates). Everything
  # else — free text, paths, raw bytes — is categorically redacted.
  defp sanitize_binary(binary) do
    if String.valid?(binary) and String.match?(binary, ~r/^[0-9a-f]{8,}$/) do
      String.slice(binary, 0, @hex_prefix)
    else
      :redacted
    end
  end

  defp production_readers do
    %{
      product: fn -> %{product: product_atom(Application.get_env(:racing_org_tracker_pro, :product))} end,
      boot: fn -> BootProvisioner.status() end,
      session: fn ->
        %{live: SessionHolder.live?(SessionHolder), generation: SessionHolder.generation(SessionHolder)}
      end,
      outbox: fn -> OutboxOwner.status(OutboxOwner) end,
      desired_state: fn -> Manager.status() end,
      gate: fn ->
        %{
          open: OperationalGate.open?(),
          authority_established: OperationalGate.authority_established?(),
          output_permitted: OperationalGate.output_permitted?()
        }
      end,
      firmware_validation: fn ->
        %{
          processes: FirmwareValidation.RequiredProcesses.status(),
          receipts: %{
            control: FirmwareValidation.ReceiptEvidence.status(:control),
            telemetry: FirmwareValidation.ReceiptEvidence.status(:telemetry)
          }
        }
      end
    }
  end

  defp product_atom("logger"), do: :logger
  defp product_atom("uplink"), do: :uplink
  defp product_atom(_unexpected), do: :unknown
end
