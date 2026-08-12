defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry do
  @moduledoc "Durable identity and payload recovered from an outbox entry record."

  @enforce_keys [
    :stream,
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :sequence,
    :entry_id,
    :payload_hash,
    :payload_checksum,
    :payload,
    :priority,
    :encoded_size,
    :ordinal
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stream: atom(),
          device_id: <<_::128>>,
          credential_epoch: non_neg_integer(),
          storage_epoch: <<_::128>>,
          sequence: pos_integer(),
          entry_id: binary(),
          payload_hash: <<_::256>>,
          payload_checksum: <<_::256>>,
          payload: binary(),
          priority: 0..255,
          encoded_size: pos_integer(),
          ordinal: pos_integer()
        }
end
