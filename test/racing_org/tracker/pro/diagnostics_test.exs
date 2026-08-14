defmodule RacingOrg.Tracker.Pro.DiagnosticsTest do
  @moduledoc """
  The operator-facing diagnostics summary: a closed, sanitized projection of
  device state safe to read over a serial console or paste into a support
  ticket. Sections come from injectable readers; every section fails closed to
  `:unavailable`, and a defense-in-depth sanitizer redacts anything a reader
  leaks that is not an atom/number/boolean or a truncated hex identifier.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Diagnostics

  @sections [:boot, :desired_state, :firmware_validation, :gate, :outbox, :product, :session]

  defp readers(overrides \\ %{}) do
    Map.merge(
      %{
        product: fn -> %{product: :logger} end,
        boot: fn -> %{phase: :effective} end,
        session: fn -> %{live: true, generation: 3} end,
        outbox: fn -> %{pending: 2, quarantined: false} end,
        desired_state: fn -> %{recovery_error: nil} end,
        gate: fn -> %{open: true, authority_established: true, output_permitted: true} end,
        firmware_validation: fn -> %{processes: %{supervisor: :healthy}} end
      },
      overrides
    )
  end

  test "summary/1 returns the closed section key set" do
    summary = Diagnostics.summary(readers: readers())

    assert summary |> Map.keys() |> Enum.sort() == @sections
    assert summary.session == %{live: true, generation: 3}
    assert summary.gate.output_permitted == true
  end

  test "a raising or exiting section reader reports :unavailable without crashing" do
    summary =
      Diagnostics.summary(
        readers:
          readers(%{
            outbox: fn -> raise "store unreachable" end,
            session: fn -> GenServer.call(:no_such_diag_process, :status) end
          })
      )

    assert summary.outbox == :unavailable
    assert summary.session == :unavailable
    assert summary.gate.open == true
  end

  test "a missing or malformed reader reports :unavailable" do
    summary = Diagnostics.summary(readers: readers() |> Map.delete(:boot) |> Map.put(:outbox, :not_a_fun))

    assert summary.boot == :unavailable
    assert summary.outbox == :unavailable
  end

  test "leaked sensitive values are redacted, hex identifiers are truncated" do
    digest = :crypto.hash(:sha256, "device") |> Base.encode16(case: :lower)

    summary =
      Diagnostics.summary(
        readers:
          readers(%{
            boot: fn ->
              %{
                phase: :effective,
                hardware_identity: digest,
                psk: "hunter2-super-secret-passphrase",
                raw: :crypto.strong_rand_bytes(32),
                identity: %URI{host: "device.local"},
                on_disk: "/data/desired_state/store",
                callback: fn -> :boom end
              }
            end
          })
      )

    rendered = inspect(summary, limit: :infinity)

    assert summary.boot.hardware_identity == String.slice(digest, 0, 12)
    assert summary.boot.psk == :redacted
    assert summary.boot.raw == :redacted
    assert summary.boot.identity == :redacted
    assert summary.boot.on_disk == :redacted
    assert summary.boot.callback == :redacted
    refute rendered =~ "hunter2"
    refute rendered =~ "/data/"
    refute rendered =~ String.slice(digest, 12, 52)
  end

  test "nested structures are sanitized and depth-bounded" do
    deep = Enum.reduce(1..8, %{secret: "deep-plaintext-secret"}, fn _depth, acc -> %{inner: acc} end)

    summary =
      Diagnostics.summary(readers: readers(%{outbox: fn -> %{tree: deep, streams: [%{path: "/data/outbox"}, :ok]} end}))

    refute inspect(summary, limit: :infinity) =~ "deep-plaintext-secret"
    refute inspect(summary, limit: :infinity) =~ "/data/outbox"
    assert [%{path: :redacted}, :ok] = summary.outbox.streams
  end

  test "summary/0 with production readers never raises and keeps the closed key set" do
    summary = Diagnostics.summary()

    assert summary |> Map.keys() |> Enum.sort() == @sections

    for {_section, value} <- summary do
      assert value == :unavailable or is_map(value)
    end
  end
end
