defmodule Pinchflat.Downloading.DownloadOptionBuilder do
  @moduledoc """
  Builds the options for yt-dlp to download media based on the given media profile.
  """

  alias Pinchflat.Sources
  alias Pinchflat.Sources.Source
  alias Pinchflat.Media.MediaItem
  alias Pinchflat.Downloading.OutputPathBuilder
  alias Pinchflat.Downloading.QualityOptionBuilder

  alias Pinchflat.Utils.FilesystemUtils, as: FSUtils

  @doc """
  Builds the options for yt-dlp to download media based on the given media's profile.

  Returns {:ok, [Keyword.t()]}
  """
  def build(%MediaItem{} = media_item_with_preloads, override_opts \\ []) do
    media_profile = media_item_with_preloads.source.media_profile

    built_options =
      default_options(override_opts) ++
        subtitle_options(media_profile) ++
        thumbnail_options(media_item_with_preloads) ++
        metadata_options(media_profile) ++
        quality_options(media_profile) ++
        sponsorblock_options(media_profile) ++
        output_options(media_item_with_preloads) ++
        config_file_options(media_item_with_preloads)

    {:ok, built_options}
  end

  @doc """
  Builds the output path for yt-dlp to download media based on the given source's
  or media_item's media profile. Uses the source's override output path template if it exists.

  Accepts a %MediaItem{} or %Source{} struct. If a %Source{} struct is passed, it
  will use a default %MediaItem{} struct with the given source. Optionally accepts
  a map of template options that override the defaults (and any custom variables
  with the same name) when rendering the template.

  Returns binary()
  """
  def build_output_path_for(record, additional_template_options \\ %{})

  def build_output_path_for(%Source{} = source_with_preloads, additional_template_options) do
    build_output_path_for(%MediaItem{source: source_with_preloads}, additional_template_options)
  end

  def build_output_path_for(%MediaItem{} = media_item_with_preloads, additional_template_options) do
    output_path_template = Sources.output_path_template(media_item_with_preloads.source)

    build_output_path(output_path_template, media_item_with_preloads, additional_template_options)
  end

  @doc """
  Builds the quality options for yt-dlp to download media based on the given source's
  or media_item's media profile. Useful for helping predict final filepath of downloaded
  media.

  returns [Keyword.t()]
  """
  def build_quality_options_for(%Source{} = source_with_preloads) do
    build_quality_options_for(%MediaItem{source: source_with_preloads})
  end

  def build_quality_options_for(%MediaItem{} = media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile

    quality_options(media_profile)
  end

  defp default_options(override_opts) do
    overwrite_behaviour = Keyword.get(override_opts, :overwrite_behaviour, :force_overwrites)

    [
      :no_progress,
      overwrite_behaviour,
      # This makes the date metadata conform to what jellyfin expects
      parse_metadata: "%(upload_date>%Y-%m-%d)s:(?P<meta_date>.+)"
    ]
  end

  defp subtitle_options(media_profile) do
    download_subs? = media_profile.download_subs == true
    embed_subs? = media_profile.embed_subs == true
    uses_sub_langs? = download_subs? or embed_subs?

    [
      # Force SRT for now - MAY provide as an option in the future
      if(download_subs?, do: [:write_subs, convert_subs: "srt"], else: []),
      if(embed_subs? and media_profile.preferred_resolution != :audio, do: [:embed_subs], else: []),
      if(media_profile.download_auto_subs == true and uses_sub_langs?, do: [:write_auto_subs], else: []),
      if(uses_sub_langs?, do: [sub_langs: media_profile.sub_langs], else: [])
    ]
    |> Enum.concat()
  end

  defp thumbnail_options(media_item_with_preloads) do
    media_profile = media_item_with_preloads.source.media_profile

    [
      if media_profile.download_thumbnail == true do
        thumbnail_save_location = determine_thumbnail_location(media_item_with_preloads)

        [:write_thumbnail, convert_thumbnail: "jpg", output: "thumbnail:#{thumbnail_save_location}"]
      else
        []
      end,
      if(media_profile.embed_thumbnail == true, do: [:embed_thumbnail, convert_thumbnail: "jpg"], else: [])
    ]
    |> Enum.concat()
  end

  defp metadata_options(media_profile) do
    [
      if(media_profile.download_metadata == true, do: [:write_info_json, :clean_info_json], else: []),
      if(media_profile.embed_metadata == true, do: [:embed_metadata], else: [])
    ]
    |> Enum.concat()
  end

  defp quality_options(media_profile) do
    QualityOptionBuilder.build(media_profile)
  end

  defp sponsorblock_options(media_profile) do
    categories = media_profile.sponsorblock_categories
    behaviour = media_profile.sponsorblock_behaviour

    case {behaviour, categories} do
      {_, []} -> []
      {:remove, _} -> [sponsorblock_remove: Enum.join(categories, ",")]
      {:mark, _} -> [sponsorblock_mark: Enum.join(categories, ",")]
      {:disabled, _} -> []
    end
  end

  # This is put here instead of the CommandRunner module because it should only
  # be applied to downloading - if it were in CommandRunner it would apply to
  # all yt-dlp commands (like indexing)
  defp config_file_options(media_item) do
    base_dir = Path.join(Application.get_env(:pinchflat, :extras_directory), "yt-dlp-configs")
    # Ordered by priority - the first file has the highest priority
    filenames = [
      "media-item-#{media_item.id}-config.txt",
      "source-#{media_item.source_id}-config.txt",
      "media-profile-#{media_item.source.media_profile_id}-config.txt",
      "base-config.txt"
    ]

    config_filepaths =
      Enum.reduce(filenames, [], fn filename, acc ->
        filepath = Path.join(base_dir, filename)

        if FSUtils.exists_and_nonempty?(filepath) do
          [filepath | acc]
        else
          acc
        end
      end)

    Enum.map(config_filepaths, fn filepath -> {:config_locations, filepath} end)
  end

  defp output_options(media_item_with_preloads) do
    [
      output: build_output_path_for(media_item_with_preloads)
    ]
  end

  defp build_output_path(string, media_item_with_preloads, additional_template_options) do
    additional_options_map = Map.merge(output_options_map(media_item_with_preloads), additional_template_options)
    {:ok, output_path} = OutputPathBuilder.build(string, additional_options_map)

    Path.join(base_directory(), output_path)
  end

  defp output_options_map(media_item_with_preloads) do
    source = media_item_with_preloads.source

    %{
      "media_item_id" => to_string(media_item_with_preloads.id),
      "source_id" => to_string(source.id),
      "media_profile_id" => to_string(source.media_profile_id),
      "source_custom_name" => source.custom_name,
      "source_collection_id" => source.collection_id,
      "source_collection_name" => source.collection_name,
      "source_collection_type" => to_string(source.collection_type),
      "media_playlist_index" => pad_int(media_item_with_preloads.playlist_index),
      "media_upload_date_index" => pad_int(media_item_with_preloads.upload_date_index)
    }
  end

  # The thumbnail must share the media file's basename (differing only in
  # extension) for media center apps to pick it up as the episode thumbnail -
  # Plex in particular only matches an exactly-named sidecar image
  defp determine_thumbnail_location(media_item_with_preloads) do
    build_output_path_for(media_item_with_preloads)
  end

  defp pad_int(integer, count \\ 2, padding \\ "0") do
    integer
    |> to_string()
    |> String.pad_leading(count, padding)
  end

  defp base_directory do
    Application.get_env(:pinchflat, :media_directory)
  end
end
