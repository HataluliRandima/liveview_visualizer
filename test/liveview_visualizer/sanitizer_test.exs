defmodule LiveViewVisualizer.SanitizerTest do
  use ExUnit.Case, async: true

  alias LiveViewVisualizer.Sanitizer

  doctest Sanitizer

  defmodule User do
    defstruct [:email, :password_hash]
  end

  describe "redaction" do
    test "redacts sensitive keys case-insensitively, as atoms or strings, at any depth" do
      input = %{
        "Password" => "hunter2",
        session: %{"user_token" => "abc"},
        nested: %{params: %{"_csrf_token" => "xyz", "name" => "Ada"}},
        api_key: "k",
        cookie: "c",
        event: "save"
      }

      assert Sanitizer.sanitize(input) == %{
               "Password" => :redacted,
               session: :redacted,
               nested: %{params: %{"_csrf_token" => :redacted, "name" => "Ada"}},
               api_key: :redacted,
               cookie: :redacted,
               event: "save"
             }
    end

    test "redacts configured extra keys" do
      sanitizer = Sanitizer.new(redact_keys: [:ssn, "IBAN"])

      assert Sanitizer.sanitize(%{user_ssn: "123", iban: "DE00", name: "Ada"}, sanitizer) ==
               %{user_ssn: :redacted, iban: :redacted, name: "Ada"}
    end

    test "ignores empty extra keys instead of redacting everything" do
      sanitizer = Sanitizer.new(redact_keys: ["", :""])
      assert Sanitizer.sanitize(%{name: "Ada"}, sanitizer) == %{name: "Ada"}
    end
  end

  describe "structs" do
    test "are reduced to their module so application data is not stored" do
      user = %User{email: "ada@example.com", password_hash: "x"}

      assert Sanitizer.sanitize(%{user: user}) == %{user: {:struct, User}}
      assert Sanitizer.sanitize(URI.parse("https://u:p@example.com")) == {:struct, URI}
    end

    test "calendar structs are kept" do
      now = DateTime.utc_now()
      date = Date.utc_today()

      assert Sanitizer.sanitize(%{at: now, on: date}) == %{at: now, on: date}
    end
  end

  describe "size limits" do
    test "truncates long strings" do
      sanitizer = Sanitizer.new(max_string: 5)
      result = Sanitizer.sanitize(String.duplicate("a", 100), sanitizer)

      assert result == "aaaaa...(100 bytes)"
    end

    test "replaces non UTF-8 binaries and bitstrings with their size" do
      assert Sanitizer.sanitize(<<0xFF, 0xFE, 0x00>>) == {:binary, 3}
      assert Sanitizer.sanitize(<<1::3>>) == {:bitstring, 3}
    end

    test "truncates long lists with a marker" do
      sanitizer = Sanitizer.new(max_items: 3)
      assert Sanitizer.sanitize(Enum.to_list(1..10), sanitizer) == [1, 2, 3, {:truncated, 7}]
    end

    test "truncates large maps with a marker" do
      sanitizer = Sanitizer.new(max_items: 3)
      result = Sanitizer.sanitize(Map.new(1..10, &{&1, &1}), sanitizer)

      assert map_size(result) == 4
      assert result.__truncated__ == 7
    end

    test "truncates large tuples with a marker" do
      sanitizer = Sanitizer.new(max_items: 2)
      assert Sanitizer.sanitize({1, 2, 3, 4}, sanitizer) == {1, 2, {:truncated, 2}}
    end

    test "cuts deeply nested data" do
      sanitizer = Sanitizer.new(max_depth: 2)
      assert Sanitizer.sanitize(%{a: %{b: %{c: %{d: 1}}}}, sanitizer) == %{a: %{b: :truncated}}
      assert Sanitizer.sanitize([[[1]], :x], sanitizer) == [[:truncated], :x]
      assert Sanitizer.sanitize(%{a: "scalar"}, Sanitizer.new(max_depth: 1)) == %{a: "scalar"}
    end
  end

  describe "other terms" do
    test "keeps atoms, numbers, pids and references" do
      ref = make_ref()
      term = {:ok, 1, 2.5, self(), ref}

      assert Sanitizer.sanitize(term) == term
    end

    test "replaces functions so closures do not retain captured data" do
      secret = "s3cret"
      fun = fn -> secret end

      result = Sanitizer.sanitize(%{callback: fun})
      assert is_binary(result.callback)
      refute result.callback =~ secret
    end

    test "handles improper lists" do
      assert Sanitizer.sanitize([1, 2 | :tail]) == [1, 2, :tail]
    end

    test "never raises for unusual terms" do
      terms = [
        nil,
        [],
        %{},
        {},
        <<>>,
        [[[[[[[[[[1]]]]]]]]]],
        %{%{nested: :key} => [1 | 2]},
        %{<<0xFF>> => "invalid utf8 key"},
        Enum.to_list(1..100_000),
        :erlang.list_to_pid(~c"<0.0.1>"),
        hd(Port.list())
      ]

      for term <- terms, do: Sanitizer.sanitize(term)
    end
  end

  describe "sanitize_metadata/2" do
    test "returns an empty map for anything that is not a plain map" do
      assert Sanitizer.sanitize_metadata(nil) == %{}
      assert Sanitizer.sanitize_metadata(password: "x") == %{}
      assert Sanitizer.sanitize_metadata(%User{}) == %{}
    end
  end

  describe "sanitize_measurements/1" do
    test "keeps only numeric values with atom keys" do
      assert Sanitizer.sanitize_measurements(%{
               :duration => 10,
               :ratio => 0.5,
               :label => "x",
               "count" => 1
             }) == %{duration: 10, ratio: 0.5}

      assert Sanitizer.sanitize_measurements(:nope) == %{}
    end
  end
end
