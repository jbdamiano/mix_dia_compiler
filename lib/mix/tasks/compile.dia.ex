defmodule Mix.Tasks.Compile.Dia do
  use Mix.Task
  alias Mix.Compilers.Erlang
  alias :filelib, as: Filelib
  alias :diameter_dict_util, as: DiaDictUtil
  alias :diameter_codegen, as: DiaCodegen

  @recursive true
  @manifest ".compile.dia"

  @moduledoc """
  Compiles Diameter source files.

  ## Command line options

  There are no command line options.

  ## Configuration

    * `:erlc_paths` - directories to find source files. Defaults to `["src"]`.

    * `:dia_options` - compilation options that apply
      to Diameter's compiler.

      For a list of the many more available options,
      see [`:diameter_make`](http://erlang.org/doc/man/diameter_make.html).
      Note that the `:outdir` option is overridden by this compiler.

    * `:dia_erl_compile_opts` list of options that will be passed to
      Mix.Compilers.Erlang.compile/6

      Following options are supported:

        * :force        - boolean
        * :verbose      - boolean
        * :all_warnings - boolean
  """

  @doc """
  Runs this task.
  """
  @spec run(OptionParser.argv) :: :ok | :noop
  def run(_args) do
    project      = Mix.Project.config
    erlang_compile_opts = project[:dia_erl_compile_opts] || []
    options      = project[:dia_options] || []

    dia_path = Path.join(Path.expand("."), "dia/")
    files = Mix.Utils.extract_files([dia_path], "*.dia")




    order = case compile_order(files) do
      {:error, reason} -> Mix.raise "cannot retrive file order: #{inspect reason}"
      {:ok, order} -> order
    end

    order |> Enum.each(fn input ->
      output = Path.join(Path.expand("."), "src/")
      :ok = Filelib.ensure_dir(output)
      app_path = Mix.Project.app_path(project)
      include_path = to_charlist Path.join(app_path, project[:erlc_include_path])
      :ok = Path.join(include_path, "dummy.hrl") |> Filelib.ensure_dir
      compile_path = to_charlist Mix.Project.compile_path(project)
      environment = Mix.env()
      int_erlc_option = if environment == :prod do
        []
      else
        [:debug_info]
      end

      case DiaDictUtil.parse({:path, input}, [{:include, compile_path}]) do

        {:ok, spec} ->
          filename = dia_filename(input, spec)
          _ = DiaCodegen.from_dict(filename, spec, [{:outdir, 'src'} | options], :erl)
          _ = DiaCodegen.from_dict(filename, spec, [{:outdir, include_path} | options], :hrl)
          file = to_charlist(Path.join("src", filename))

          erlc_options = project[:erlc_options] || int_erlc_option
          erlc_options = erlc_options ++ [{:outdir, compile_path}, {:i, include_path}, :report, :debug_info] ++ erlang_compile_opts

          case :compile.file(file, erlc_options) do
            {:ok, module} ->
              {:ok, module, []}
            {:ok, module, warnings} ->
              {:ok, module, warnings}
            {:ok, module, _binary, warnings} ->
              {:ok, module, warnings}
            {:error, errors, warnings} ->
              {:error, errors, warnings}
            :error ->
              {:error, [], []}
          end
        error -> Mix.raise "Diameter compiler error: #{inspect error}"
      end
    end)
  end



  defp compile_order(diafiles) do
    graph = :digraph.new()

    diamods = diafiles |> Enum.map(fn f ->
      dict = f |> Path.basename() |> Path.rootname()
      {:"#{dict}", f}
    end) |> Enum.into(%{})

    diamods |> Enum.each(fn ({dict, f}) ->
      case File.read(f) do
        {:ok, bin} ->
          inherits0 = String.split(bin, ["\n", "\r"], trim: true)
          inherits1 = inherits0 |> Enum.map(fn x -> String.split(x, [" ", "\t"], trim: true) || x end)

          inherits = inherits1 |> Enum.filter( fn x ->
                                                  if Enum.at(x, 0) == "@inherits" do
                                                    true
                                                  else
                                                    false
                                                  end
                                                end) |> Enum.map(fn x-> Enum.at(x, 1) end)
          add(graph, {dict, inherits})

        {:error,_reason} -> :ok
      end
    end)

    order = case :digraph_utils.topsort(graph) do
      false ->
        case :digraph_utils.is_acyclic(graph) do
          true -> {:error, :no_sort}
          false -> [:error, :cycle]
        end
      v ->
        v |> List.foldl([], fn x, acc ->
          key = case x do
            n when is_atom(n) -> n
            n -> :erlang.list_to_atom(n)
          end

          case Map.get(diamods,key, :undefined) do
            :undefined -> acc
            [file] -> [file |acc]
            file -> [file |acc]
          end
        end)
    end
    :true = :digraph.delete(graph)
    {:ok, order}

  end


  defp add(graph, {pkgname, deps}) do


    v = case :digraph.vertex(graph, pkgname) do
      false ->
        :digraph.add_vertex(graph, pkgname)
      {v, _} -> v
    end

    deps |> Enum.each(fn name1 ->
      name = String.to_charlist(name1)

      v3 = case :digraph.vertex(graph, name) do
          false ->
            :digraph.add_vertex(graph, name)
          {v2, _} -> v2
      end
      :digraph.add_edge(graph, v, v3)
    end)
  end

  @doc """
  Returns Dia manifests.
  """
  def manifests, do: [manifest()]
  defp manifest, do: Path.join(Mix.Project.manifest_path, @manifest)

  @doc """
  Cleans up compilation artifacts.
  """
  def clean do
    Erlang.clean(manifest())
  end

  defp dia_filename(file, spec) do
    case spec[:name] do
      nil -> Path.basename(file) |> Path.rootname |> to_charlist
      :undefined -> Path.basename(file) |> Path.rootname |> to_charlist
      name -> name
    end
  end
end
