defmodule RacingOrg.Tracker.Pro.SecureTransport.KATVectors do
  @moduledoc """
  Loader for the language-neutral Known-Answer-Test vectors at
  `priv/secure_transport/kat_vectors.json`.

  The JSON file is the canonical, dependency-light source of truth (sourced verbatim
  from RFC 5869, RFC 8032, RFC 7748, and RFC 8439) and is shared byte-identically with
  the server repo (OTP 27) so both implementations cross-check against the same bytes.
  This module decodes the hex fields into binaries for the KAT test suite (OTP 28).
  """

  @path Application.app_dir(:racing_org_tracker_pro, "priv/secure_transport/kat_vectors.json")
  @external_resource @path

  @doc "Path to the on-disk KAT JSON file."
  @spec path() :: String.t()
  def path, do: @path

  @doc "Load the raw decoded JSON map."
  @spec load() :: map()
  def load do
    @path
    |> File.read!()
    |> Jason.decode!()
  end

  @doc "HKDF-SHA256 cases with hex fields decoded to binaries."
  @spec hkdf_cases() :: [map()]
  def hkdf_cases do
    load()
    |> get_in(["hkdf_sha256", "cases"])
    |> Enum.map(fn c ->
      %{
        name: c["name"],
        ikm: hex(c["ikm"]),
        salt: hex(c["salt"]),
        info: hex(c["info"]),
        length: c["length"],
        prk: hex(c["prk"]),
        okm: hex(c["okm"])
      }
    end)
  end

  @doc "Ed25519 cases with hex fields decoded to binaries."
  @spec ed25519_cases() :: [map()]
  def ed25519_cases do
    load()
    |> get_in(["ed25519", "cases"])
    |> Enum.map(fn c ->
      %{
        name: c["name"],
        secret: hex(c["secret"]),
        public: hex(c["public"]),
        message: hex(c["message"]),
        signature: hex(c["signature"])
      }
    end)
  end

  @doc "X25519 cases with hex fields decoded to binaries."
  @spec x25519_cases() :: [map()]
  def x25519_cases do
    load()
    |> get_in(["x25519", "cases"])
    |> Enum.map(fn c ->
      %{
        name: c["name"],
        scalar: hex(c["scalar"]),
        u: hex(c["u"]),
        output: hex(c["output"])
      }
    end)
  end

  @doc "ChaCha20-Poly1305 AEAD cases with hex fields decoded to binaries."
  @spec chacha20_poly1305_cases() :: [map()]
  def chacha20_poly1305_cases do
    load()
    |> get_in(["chacha20_poly1305", "cases"])
    |> Enum.map(fn c ->
      %{
        name: c["name"],
        key: hex(c["key"]),
        nonce: hex(c["nonce"]),
        aad: hex(c["aad"]),
        plaintext: c["plaintext_utf8"],
        ciphertext: hex(c["ciphertext"]),
        tag: hex(c["tag"])
      }
    end)
  end

  defp hex(nil), do: <<>>
  defp hex(""), do: <<>>
  defp hex(s) when is_binary(s), do: Base.decode16!(s, case: :lower)
end
