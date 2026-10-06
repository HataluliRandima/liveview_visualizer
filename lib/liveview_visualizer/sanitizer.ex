defmodule LiveViewVisualizer.Sanitizer do
  @default_redact ~w(password passwd secret token csrf api_key apikey private_key auth cookie session credential)

  @moduledoc """
  Makes arbitrary terms safe and cheap to keep in the event store.

  Observed metadata can contain anything: sessions, CSRF tokens, passwords in
  form params, large assigns or whole structs from the host application. The
  sanitizer is the last line of defence before data is stored:

    * Values under keys that look sensitive are replaced with `:redacted`. A key
      matches if, lowercased, it contains any of `#{inspect(@default_redact)}`, or
      any extra key configured through `:redact_keys` (see `LiveViewVisualizer.Config`).
      Matching is deliberately broad: over-redacting is preferred to leaking.
    * Structs are reduced to `{:struct, Module}` so application records (users,
      changesets, sockets) are never stored. Calendar structs are kept as they are.
    * Strings longer than `:max_string` bytes are cut to `:max_string` characters.
      Binaries that are not valid UTF-8 are replaced with `{:binary, byte_size}`.
    * Lists and tuples with more than `:max_items` elements are cut and end with a
      `{:truncated, remaining}` marker. Oversized maps are cut and get a
      `:__truncated__ => remaining` entry.
    * Maps, lists and tuples nested more than `:max_depth` levels deep become
      `:truncated`.
    * Anonymous functions are replaced with their inspected form, so captured
      variables are not retained in memory.

  This module never raises for any input term.
  """

  @plain_structs [Date, DateTime, NaiveDateTime, Time]

  @type t :: %__MODULE__{
          redact: [String.t()],
          max_depth: pos_integer(),
          max_items: pos_integer(),
          max_string: pos_integer()
        }

  defstruct redact: @default_redact, max_depth: 4, max_items: 25, max_string: 256

  @doc """
  Builds sanitizer options.

  ## Options

    * `:redact_keys` - extra keys to redact, in addition to the built-in list
    * `:max_depth` - maximum number of nested container levels kept (default `4`)
    * `:max_items` - maximum elements kept per map, list or tuple (default `25`)
    * `:max_string` - maximum string length in bytes (default `256`)

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    {extra, opts} = Keyword.pop(opts, :redact_keys, [])

    extra =
      extra
      |> Enum.map(&(&1 |> to_string() |> String.downcase()))
      |> Enum.reject(&(&1 == ""))

    struct!(%__MODULE__{redact: Enum.uniq(@default_redact ++ extra)}, opts)
  end

  @doc """
  Sanitizes a metadata map. Non-map input yields an empty map.

  ## Examples

      iex> LiveViewVisualizer.Sanitizer.sanitize_metadata(%{event: "save", user_token: "abc"})
      %{event: "save", user_token: :redacted}

  """
  @spec sanitize_metadata(term(), t()) :: map()
  def sanitize_metadata(metadata, sanitizer \\ %__MODULE__{})

  def sanitize_metadata(metadata, %__MODULE__{} = sanitizer)
      when is_map(metadata) and not is_struct(metadata) do
    sanitize(metadata, sanitizer)
  end

  def sanitize_metadata(_metadata, _sanitizer), do: %{}

  @doc """
  Keeps only numeric measurements with atom keys.

  ## Examples

      iex> LiveViewVisualizer.Sanitizer.sanitize_measurements(%{duration: 10, note: "x"})
      %{duration: 10}

  """
  @spec sanitize_measurements(term()) :: %{optional(atom()) => number()}
  def sanitize_measurements(measurements) when is_map(measurements) do
    for {key, value} <- measurements,
        is_atom(key) and is_number(value),
        into: %{},
        do: {key, value}
  end

  def sanitize_measurements(_measurements), do: %{}

  @doc """
  Sanitizes any term according to the rules described in the module documentation.
  """
  @spec sanitize(term(), t()) :: term()
  def sanitize(term, sanitizer \\ %__MODULE__{}), do: do_sanitize(term, sanitizer, 0)

  # Only containers are cut, so scalar values and map keys survive at any depth.
  defp do_sanitize(term, %{max_depth: max}, depth)
       when depth >= max and (is_map(term) or is_list(term) or is_tuple(term)),
       do: :truncated

  defp do_sanitize(%module{} = struct, _sanitizer, _depth) when module in @plain_structs,
    do: struct

  defp do_sanitize(%module{}, _sanitizer, _depth), do: {:struct, module}

  defp do_sanitize(map, sanitizer, depth) when is_map(map) do
    {kept, rest} = map |> Map.to_list() |> take(sanitizer.max_items)

    sanitized =
      Map.new(kept, fn {key, value} ->
        safe_key = do_sanitize(key, sanitizer, depth + 1)

        if redact?(key, sanitizer),
          do: {safe_key, :redacted},
          else: {safe_key, do_sanitize(value, sanitizer, depth + 1)}
      end)

    if rest > 0, do: Map.put(sanitized, :__truncated__, rest), else: sanitized
  end

  defp do_sanitize(list, sanitizer, depth) when is_list(list),
    do: sanitize_list(list, sanitizer, depth, sanitizer.max_items, [])

  defp do_sanitize(tuple, sanitizer, depth) when is_tuple(tuple) do
    {kept, rest} = tuple |> Tuple.to_list() |> take(sanitizer.max_items)
    kept = Enum.map(kept, &do_sanitize(&1, sanitizer, depth + 1))

    if rest > 0,
      do: List.to_tuple(kept ++ [{:truncated, rest}]),
      else: List.to_tuple(kept)
  end

  defp do_sanitize(binary, sanitizer, _depth) when is_binary(binary) do
    cond do
      not String.valid?(binary) -> {:binary, byte_size(binary)}
      byte_size(binary) > sanitizer.max_string -> truncate_string(binary, sanitizer.max_string)
      true -> binary
    end
  end

  defp do_sanitize(bitstring, _sanitizer, _depth) when is_bitstring(bitstring),
    do: {:bitstring, bit_size(bitstring)}

  defp do_sanitize(fun, _sanitizer, _depth) when is_function(fun), do: inspect(fun)

  # Atoms, numbers, pids, ports and references carry no application data.
  defp do_sanitize(term, _sanitizer, _depth), do: term

  # Handles improper lists without raising.
  defp sanitize_list([], _sanitizer, _depth, _remaining, acc), do: Enum.reverse(acc)

  defp sanitize_list([_ | _] = list, _sanitizer, _depth, 0, acc),
    do: Enum.reverse([{:truncated, proper_length(list, 0)} | acc])

  defp sanitize_list([head | tail], sanitizer, depth, remaining, acc),
    do:
      sanitize_list(tail, sanitizer, depth, remaining - 1, [
        do_sanitize(head, sanitizer, depth + 1) | acc
      ])

  defp sanitize_list(improper_tail, sanitizer, depth, _remaining, acc),
    do: Enum.reverse([do_sanitize(improper_tail, sanitizer, depth + 1) | acc])

  defp proper_length([_ | tail], count), do: proper_length(tail, count + 1)
  defp proper_length(_tail, count), do: count

  defp take(list, max) do
    case Enum.split(list, max) do
      {kept, []} -> {kept, 0}
      {kept, rest} -> {kept, length(rest)}
    end
  end

  defp truncate_string(binary, max) do
    String.slice(binary, 0, max) <> "...(#{byte_size(binary)} bytes)"
  end

  defp redact?(key, sanitizer) when is_atom(key) and not is_nil(key),
    do: redact?(Atom.to_string(key), sanitizer)

  defp redact?(key, %{redact: patterns}) when is_binary(key),
    do: :binary.match(String.downcase(key), patterns) != :nomatch

  defp redact?(_key, _sanitizer), do: false
end
