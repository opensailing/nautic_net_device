defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1KATPinTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.KATVectors

  @frozen_sha256 "3973265021ae78274938883ee9169ecdfd2cb291a4e02f4ec24856f8fa19055a"

  test "desired_state_v1_kat.json is byte-frozen at the shared cross-repository sha" do
    actual =
      KATVectors.path()
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert actual == @frozen_sha256,
           """
           priv/secure_transport/desired_state_v1_kat.json is FROZEN.

           Its SHA-256 no longer matches the pinned cross-repository value:

             pinned:  #{@frozen_sha256}
             actual:  #{actual}

           This file is a shared known-answer vector consumed byte-for-byte by both
           the tracker and the backend (website/backend keeps an identical copy).
           Any change to it is a cross-repo wire-contract break: regenerating or
           editing the vectors silently allows the two codecs to drift apart.

           If a contract change is truly intended, it must be coordinated across
           both repositories (new vector file plus matching sha pins on both
           sides), not made by editing this frozen file in one repo.
           """
  end
end
