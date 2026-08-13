defmodule RacingOrg.Tracker.Pro.WiFiManager.ReconnectConfirmation do
  @moduledoc """
  Authenticated reconnect confirmation for the bounded Wi-Fi trial.

  A trialed Wi-Fi configuration is confirmed only by post-apply evidence that
  the secure transport works over it: either an authenticated control receipt
  round trip recorded after the trial started, or a replacement authenticated
  session going live (the session generation advanced past the pre-trial
  baseline). Anything else times out inside the trial's own deadline and the
  WiFiManager rolls the configuration back.
  """

  alias RacingOrg.Tracker.Pro.FirmwareValidation.ReceiptEvidence
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @default_deadline_ms 12_000
  @default_poll_ms 250

  @doc "Block until authenticated reconnect evidence appears or the deadline lapses."
  @spec confirm(keyword()) :: :ok | {:error, :wifi_reconnect_unconfirmed}
  def confirm(opts \\ []) when is_list(opts) do
    holder = Keyword.get(opts, :session_holder, SessionHolder)
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    poll_ms = Keyword.get(opts, :poll_ms, @default_poll_ms)
    started_at_ms = Keyword.get_lazy(opts, :started_at_ms, &now_ms/0)
    evidence_opts = evidence_opts(opts)
    baseline_generation = current_generation(holder)

    poll(
      holder,
      baseline_generation,
      started_at_ms,
      started_at_ms + deadline_ms,
      poll_ms,
      evidence_opts
    )
  end

  defp poll(holder, baseline_generation, started_at_ms, deadline_at_ms, poll_ms, evidence_opts) do
    cond do
      ReceiptEvidence.recorded_after?(:control, started_at_ms, evidence_opts) ->
        :ok

      replacement_session_live?(holder, baseline_generation) ->
        :ok

      now_ms() >= deadline_at_ms ->
        {:error, :wifi_reconnect_unconfirmed}

      true ->
        Process.sleep(poll_ms)
        poll(holder, baseline_generation, started_at_ms, deadline_at_ms, poll_ms, evidence_opts)
    end
  end

  defp replacement_session_live?(holder, baseline_generation) do
    live? = safe(fn -> SessionHolder.live?(holder) end, false)
    generation = current_generation(holder)

    live? and is_integer(generation) and
      (is_nil(baseline_generation) or generation > baseline_generation)
  end

  defp current_generation(holder) do
    safe(fn -> SessionHolder.generation(holder) end, nil)
  end

  defp evidence_opts(opts) do
    case Keyword.fetch(opts, :receipt_evidence_key) do
      {:ok, key} -> [key: key]
      :error -> []
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp safe(fun, default) do
    fun.()
  rescue
    _exception -> default
  catch
    :exit, _reason -> default
    _kind, _reason -> default
  end
end
