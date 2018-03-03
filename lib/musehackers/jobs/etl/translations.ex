defmodule Musehackers.Jobs.Etl.Translations do
  @moduledoc """
  Simple ETL tool to fetch latest Helio translations and store them in a resource table
  """

  use GenServer
  require Logger
  import Musehackers.Jobs.Etl.Helpers
  alias Musehackers.Clients
  alias NimbleCSV.RFC4180, as: CSV
  alias NimbleCSV.ParseError

  def googledoc_export_link do
    "http://docs.google.com/feeds/download/spreadsheets/Export?key=todo&exportFormat=csv&gid=0"
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, name: __MODULE__)
  end

  def init(_) do
    try do
      source_url = googledoc_export_link()
      # turned off for now
      # Logger.info IO.ANSI.magenta <> "Starting Helio translations update job" <> IO.ANSI.reset
      # schedule_work()
      {:ok, source_url}
    rescue
      exception ->
         Logger.error inspect exception
         :ignore
    end
  end

  # Async call used by schedule_work() with Process.send_after
  def handle_info(:process, source_url) do
    extract_transform_load(source_url)
    schedule_work()
    {:noreply, source_url}
  end

  # Sync call used by web controller to fetch translations immediately:
  # GenServer.call(Musehackers.Jobs.Etl.Translations, :process)
  def handle_call(:process) do
    source_url = googledoc_export_link()
    extract_transform_load(source_url)
    {:ok, source_url}
  end

  defp extract_transform_load(source_url) do
    with {:ok, body} <- download(source_url),
         {:ok, translations_map} = transform(body),
    do: {} # TODO %Resource{} from translations_map, Clients.update_resource(:translations, translations_resource)
  end

  def transform(body) do
    with {:ok, parsed_csv} <- parse_csv(body),
         {:ok, cleaned_up_csv} <- remove_draft_translations(parsed_csv),
         {:ok, locales_list} <- transform_translations_map(cleaned_up_csv),
    do: {:ok, %{"translations": %{"locale": locales_list}}}
  end

  defp schedule_work do
    wait = 1000 * 60 * 60 * 12 # 12 hours
    Process.send_after(self(), :process, wait)
  end

  defp parse_csv(body) do
    try do
      parsed_list = CSV.parse_string(body, headers: false)
      {:ok, parsed_list}
    rescue
      ParseError -> {:error, "Failed to parse CSV"}
    end
  end

  defp remove_draft_translations(translations) do
    headers = Enum.at(translations, 0)
    result = translations
      |> Enum.map(fn(x) ->
        # Iterate sublists to remove columns marked as incomplete
        Enum.filter(x, fn(y) ->
          idx = Enum.find_index(x, fn(z) -> z == y end)
          is_draft = (String.downcase(Enum.at(headers, idx)) =~ "todo")
          !is_draft
        end)
      end)
    {:ok, result}
  end

  defp transform_translations_map(translations) do
    ids = Enum.at(translations, 1) |> Enum.with_index(0)
    names = Enum.at(translations, 2)
    formulas = Enum.at(translations, 3)

    # At this point raw data is like:
    # [
    #  ["defaults::newproject::firstcommit", "The name of the very first changeset", "Project started", "Проект создан", "プロジェクト開始"],
    #  ["defaults::newproject::name", "Default names or the new items created by user", "New project", "Новый проект", "新規プロジェクト"],
    #  ["Plural forms:", "", "", "", "", ""],
    #  ["{x} input channels", "", "{x} input channel\n{x} input channels", "{x} входной канал\n{x} входных канала\n{x} входных каналов", "{x} 入力チャンネル"],
    #  ["{x} output channels", "", "{x} output channel\n{x} output channels", "{x} выходной канал\n{x} выходных канала\n{x} выходных каналов", "{x} 出力チャンネル"]
    # ]
    data = remove_headers(translations)

    # Convert sub-lists values into tuples with indexes for simplier pasring:
    indexed_data = data |> Enum.map(fn(x) -> Enum.with_index(x, 0) end)

    result = ids
      |> Enum.flat_map(fn{x, i} ->
        case x != "ID"  && x != "" do
          true -> [%{
              "id": x,
              "name": Enum.at(names, i),
              "pluralEquation": Enum.at(formulas, i),
              "literal": extract_singulars(indexed_data, i),
              "pluralLiteral": extract_plurals(indexed_data, i)
            }]
          false -> []
        end
      end)
    {:ok, result}
  end

  defp extract_singulars(translations, locale_index) do
    translations
      |> Enum.flat_map(fn(x) ->
        name = Enum.at(x, 0) |> elem(0);
        translation = Enum.at(x, locale_index) |> elem(0);
        case translation == "" || name =~ "{x}" do
          false -> [%{
            "name": name,
            "translation": translation
          }]
          true -> []
        end
      end)
  end

  defp extract_plurals(translations, locale_index) do
    translations
      |> Enum.flat_map(fn(x) ->
        name = Enum.at(x, 0) |> elem(0);
        translations = Enum.at(x, locale_index) |> elem(0);
        case translations != "" && name =~ "{x}" do
          true -> [%{
            "name": name,
            "translation": split_plural_forms(translations)
          }]
          false -> []
        end
      end)
  end

  defp split_plural_forms(string) do
    string
      |> String.split(["\n", "\r"])
      |> Enum.with_index(1)
      |> Enum.map(fn{x, i} -> 
        %{
          "name": x,
          "pluralForm": Integer.to_string(i)
        }
      end)
  end

  defp remove_headers(translations) do
    translations
      |> Enum.with_index(0)
      |> Enum.filter(fn{_, i} -> i > 3 end)
      |> Enum.map(fn{x, _} -> x end)
  end
end
