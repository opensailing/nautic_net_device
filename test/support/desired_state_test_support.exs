defmodule RacingOrg.Tracker.Pro.DesiredStateTestSupport do
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Manifest, Section}

  @device_id <<0x10::128>>
  @boot_id <<0x20::128>>
  @storage_epoch <<0x30::128>>

  def device_id, do: @device_id
  def boot_id, do: @boot_id
  def storage_epoch, do: @storage_epoch

  def generation_fixture(opts \\ []) do
    generation = Keyword.get(opts, :generation, 1)
    credential_epoch = Keyword.get(opts, :credential_epoch, 4)
    contents = Map.merge(default_contents(), Keyword.get(opts, :contents, %{}))
    tombstones = Keyword.get(opts, :tombstones, [:assignment, :polar])
    wifi_secrets = Keyword.get(opts, :wifi_secrets, [])

    sections =
      Enum.map(Contract.sections(), fn name ->
        cond do
          name in tombstones ->
            {:ok, section} = Section.tombstone(name)
            section

          name == :wifi ->
            {:ok, section} = Section.build(name, Map.fetch!(contents, name), secrets: wifi_secrets)
            section

          true ->
            {:ok, section} = Section.build(name, Map.fetch!(contents, name))
            section
        end
      end)

    attrs = %{
      device_id: Keyword.get(opts, :device_id, @device_id),
      credential_epoch: credential_epoch,
      generation: generation,
      minimum_firmware: Keyword.get(opts, :minimum_firmware),
      required_capabilities: Keyword.get(opts, :required_capabilities, []),
      sections: Enum.map(sections, &Section.descriptor/1)
    }

    {:ok, manifest_bytes} = Manifest.encode(attrs)
    {:ok, manifest} = Manifest.decode(manifest_bytes)

    binding = %{
      device_id: attrs.device_id,
      credential_epoch: credential_epoch,
      boot_id: Keyword.get(opts, :boot_id, @boot_id),
      storage_epoch: Keyword.get(opts, :storage_epoch, @storage_epoch),
      generation: generation,
      manifest_hash: manifest.hash
    }

    %{
      binding: binding,
      manifest: manifest,
      manifest_bytes: manifest_bytes,
      manifest_hash: manifest.hash,
      sections: sections,
      sections_by_name: Map.new(sections, &{&1.name, &1}),
      delivery: Map.merge(binding, %{manifest: manifest_bytes})
    }
  end

  def chunks(fixture) do
    fixture.sections
    |> Enum.reject(& &1.tombstone)
    |> Enum.flat_map(fn section -> chunks_for_section(fixture.binding, section) end)
  end

  def chunks_for_section(binding, section) do
    chunk_size = Contract.chunk_size()
    chunk_count = div(byte_size(section.content) + chunk_size - 1, chunk_size)

    for chunk_index <- 0..(chunk_count - 1) do
      offset = chunk_index * chunk_size
      length = min(chunk_size, byte_size(section.content) - offset)
      chunk = binary_part(section.content, offset, length)

      Map.merge(binding, %{
        section: section.name,
        section_schema_version: section.schema_version,
        section_hash: section.hash,
        total_content_length: section.content_length,
        chunk_index: chunk_index,
        chunk_count: chunk_count,
        chunk_offset: offset,
        chunk: chunk
      })
    end
  end

  def secret_descriptor do
    %{
      kind: :wifi_psk,
      digest_key_id: 9,
      ref: <<0x44::128>>,
      digest: :binary.copy(<<0x55>>, 32)
    }
  end

  def secret_delivery(fixture, secret \\ "synthetic-secret") do
    wifi = fixture.sections_by_name.wifi
    [descriptor] = wifi.secrets

    Map.merge(fixture.binding, %{
      section: :wifi,
      section_schema_version: wifi.schema_version,
      section_hash: wifi.hash,
      secret_kind: descriptor.kind,
      digest_key_id: descriptor.digest_key_id,
      secret_ref: descriptor.ref,
      secret_digest: descriptor.digest,
      secret: secret
    })
  end

  def default_contents do
    %{
      assignment: %{
        "schema_version" => 1,
        "assignment_id" => "assignment-1",
        "assignment_version" => 1,
        "boat_id" => "boat-1",
        "device_id" => "device-1",
        "race_id" => "race-1",
        "race_session_id" => "session-1",
        "official_start_at" => "2026-08-07T13:00:00Z",
        "start_line" => %{},
        "finish" => %{},
        "course_marks" => [],
        "shortened_course" => %{},
        "active_next_mark" => %{},
        "sampling_rules" => %{},
        "route" => %{}
      },
      calibration: %{
        "version" => 1,
        "parameters" => %{
          "awa_offset" => %{"mode" => "auto"},
          "awa_upwash" => %{"mode" => "auto"},
          "stw_scale" => %{"mode" => "auto"},
          "aws_scale" => %{"mode" => "shadow"}
        },
        "sensors" => []
      },
      clock_source: %{
        "version" => 1,
        "mode" => "tracker_receive_time",
        "fallback" => "tracker_receive_time",
        "sources" => []
      },
      computed_values: %{"version" => 1, "values" => []},
      polar: %{
        "schema_version" => 1,
        "command_type" => "polar_table",
        "polar_id" => "polar-1",
        "version" => 1,
        "rows" => [
          %{
            "tws_mps" => 5.0,
            "cells" => [
              %{"twa_deg" => 45.0, "boat_speed_mps" => 3.0},
              %{"twa_deg" => 90.0, "boat_speed_mps" => 4.0}
            ]
          }
        ],
        "optima" => []
      },
      tracking: %{
        "version" => 1,
        "states" => %{
          "pre_race" => %{"damping_seconds" => 0.0, "send_rate_hz" => 1.0},
          "starting" => %{"damping_seconds" => 0.0, "send_rate_hz" => 1.0},
          "race" => %{"damping_seconds" => 0.0, "send_rate_hz" => 1.0}
        },
        "deviation_threshold_meters" => 50.0
      },
      upstream: %{
        "version" => 1,
        "signals" => %{
          "heading" => true,
          "speed" => true,
          "velocity" => true,
          "wind" => true,
          "water_depth" => true,
          "attitude" => true
        }
      },
      wifi: %{"version" => 1, "enabled" => false, "ssid" => nil},
      wind_shift: %{
        "version" => 1,
        "windows" => %{"fast_s" => 30.0, "mid_s" => 300.0, "slow_s" => 1500.0, "envelope_s" => 1800.0},
        "alarms" => %{"new_extreme_margin_deg" => 2.0, "enabled" => true},
        "wally" => %{"mode" => "off"}
      }
    }
  end
end
