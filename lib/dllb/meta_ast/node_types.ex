defmodule Dllb.MetaAST.NodeTypes do
  @moduledoc """
  Compile-time mapping of all 45 Metastatic node types plus the wildcard.

  This module is the single source of truth for node type classification
  in the Elixir adapter. Types are organized into four layers: core,
  extended, structural, and native.
  """

  @core_types [
    :literal,
    :variable,
    :binary_op,
    :unary_op,
    :function_call,
    :conditional,
    :early_return,
    :throw,
    :block,
    :list,
    :map,
    :pair,
    :tuple,
    :assignment,
    :inline_match,
    :range,
    :string_interpolation,
    :bin_segment,
    :comment
  ]

  @extended_types [
    :loop,
    :lambda,
    :collection_op,
    :pattern_match,
    :match_arm,
    :exception_handling,
    :async_operation,
    :yield,
    :comprehension,
    :generator,
    :filter,
    :pipe,
    :pin,
    :assert_type
  ]

  @structural_types [
    :container,
    :function_def,
    :param,
    :attribute_access,
    :augmented_assignment,
    :property,
    :import,
    :type_annotation,
    :decorator,
    :record_update,
    :child_spec
  ]

  @native_types [:language_specific]

  @all_types @core_types ++ @extended_types ++ @structural_types ++ @native_types

  @type_to_layer_map for(t <- @core_types, into: %{}, do: {t, :core})
                     |> Map.merge(for t <- @extended_types, into: %{}, do: {t, :extended})
                     |> Map.merge(for t <- @structural_types, into: %{}, do: {t, :structural})
                     |> Map.merge(for t <- @native_types, into: %{}, do: {t, :native})

  @valid_set MapSet.new(@all_types)

  @string_to_atom_map for t <- @all_types, into: %{}, do: {Atom.to_string(t), t}

  @doc """
  Returns all 45 node types.
  """
  @spec all() :: [atom()]
  def all, do: @all_types

  @doc """
  Returns the 19 core node types.
  """
  @spec core() :: [atom()]
  def core, do: @core_types

  @doc """
  Returns the 14 extended node types.
  """
  @spec extended() :: [atom()]
  def extended, do: @extended_types

  @doc """
  Returns the 11 structural node types.
  """
  @spec structural() :: [atom()]
  def structural, do: @structural_types

  @doc """
  Returns the native node types.
  """
  @spec native() :: [atom()]
  def native, do: @native_types

  @doc """
  Returns `true` if the given atom is a valid Metastatic node type.

  ## Examples

      iex> Dllb.MetaAST.NodeTypes.valid?(:function_def)
      true

      iex> Dllb.MetaAST.NodeTypes.valid?(:bogus)
      false

  """
  @spec valid?(atom()) :: boolean()
  def valid?(type) when is_atom(type), do: MapSet.member?(@valid_set, type)

  @doc """
  Returns the layer (`:core`, `:extended`, `:structural`, or `:native`)
  for the given node type atom.

  Raises `ArgumentError` if the type is not valid.

  ## Examples

      iex> Dllb.MetaAST.NodeTypes.layer(:literal)
      :core

      iex> Dllb.MetaAST.NodeTypes.layer(:container)
      :structural

  """
  @spec layer(atom()) :: :core | :extended | :structural | :native
  def layer(type) when is_atom(type) do
    case Map.fetch(@type_to_layer_map, type) do
      {:ok, l} -> l
      :error -> raise ArgumentError, "unknown node type: #{inspect(type)}"
    end
  end

  @doc """
  Converts a node type atom to the string used in dllb's `kind` field.

  ## Examples

      iex> Dllb.MetaAST.NodeTypes.to_dllb_kind(:function_call)
      "function_call"

  """
  @spec to_dllb_kind(atom()) :: String.t()
  def to_dllb_kind(type) when is_atom(type), do: Atom.to_string(type)

  @doc """
  Converts a dllb `kind` string back to a node type atom.

  Returns `{:ok, atom}` if the string is a recognized type, `:error` otherwise.

  ## Examples

      iex> Dllb.MetaAST.NodeTypes.from_dllb_kind("function_def")
      {:ok, :function_def}

      iex> Dllb.MetaAST.NodeTypes.from_dllb_kind("nope")
      :error

  """
  @spec from_dllb_kind(String.t()) :: {:ok, atom()} | :error
  def from_dllb_kind(kind) when is_binary(kind) do
    case Map.fetch(@string_to_atom_map, kind) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end
end
