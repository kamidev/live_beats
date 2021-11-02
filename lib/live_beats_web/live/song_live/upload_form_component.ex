defmodule LiveBeatsWeb.SongLive.UploadFormComponent do
  use LiveBeatsWeb, :live_component

  alias LiveBeats.{MediaLibrary, ID3}
  alias LiveBeatsWeb.SongLive.SongEntryComponent

  @max_songs 10

  @impl true
  def update(%{song: song} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign(changesets: %{})
     |> allow_upload(:mp3,
       song_id: song.id,
       auto_upload: true,
       progress: &handle_progress/3,
       accept: ~w(.mp3),
       max_entries: @max_songs,
       max_file_size: 20_000_000
     )}
  end

  @impl true
  def handle_event("validate", %{"_target" => ["mp3"]}, socket) do
    {:noreply, socket}
  end

  def handle_event("validate", %{"songs" => songs_params, "_target" => ["songs", _, _]}, socket) do
    new_socket =
      Enum.reduce(songs_params, socket, fn {ref, song_params}, acc ->
        new_changeset =
          acc
          |> get_changeset(ref)
          |> Ecto.Changeset.apply_changes()
          |> MediaLibrary.change_song(song_params)
          |> Map.put(:action, :validate)

        update_changeset(acc, new_changeset, ref)
      end)

    {:noreply, new_socket}
  end

  defp consume_entry(socket, ref, store_func) when is_function(store_func) do
    {entries, []} = uploaded_entries(socket, :mp3)
    entry = Enum.find(entries, fn entry -> entry.ref == ref end)
    consume_uploaded_entry(socket, entry, fn meta -> store_func.(meta.path) end)
  end

  def handle_event("save", %{"songs" => song_params}, socket) do
    changesets = socket.assigns.changesets

    case MediaLibrary.import_songs(changesets, &consume_entry(socket, &1, &2)) do
      {:ok, songs} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{map_size(songs)} song(s) uploaded")
         |> push_redirect(to: Routes.song_index_path(socket, :index))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "There were problems uploading your songs")}
    end
  end

  defp get_changeset(socket, entry_ref) do
    case Enum.find(socket.assigns.changesets, fn {ref, _changeset} -> ref === entry_ref end) do
      {^entry_ref, changeset} -> changeset
      nil -> nil
    end
  end

  defp put_new_changeset(socket, entry) do
    if get_changeset(socket, entry.ref) do
      socket
    else
      if Enum.count(socket.assigns.changesets) > @max_songs do
        raise RuntimeError, "file upload limited exceeded"
      end

      attrs = MediaLibrary.parse_file_name(entry.client_name)
      changeset = MediaLibrary.change_song(%MediaLibrary.Song{}, attrs)

      update_changeset(socket, changeset, entry.ref)
    end
  end

  defp update_changeset(socket, %Ecto.Changeset{} = changeset, entry_ref) do
    update(socket, :changesets, &Map.put(&1, entry_ref, changeset))
  end

  defp handle_progress(:mp3, entry, socket) do
    send_update(SongEntryComponent, id: entry.ref, progress: entry.progress)
    {:noreply, put_new_changeset(socket, entry)}
  end

  defp put_tmp_mp3(changeset, path) do
    {:ok, tmp_path} = Plug.Upload.random_file("tmp_mp3")
    File.cp!(path, tmp_path)
    Ecto.Changeset.put_change(changeset, :tmp_mp3_path, tmp_path)
  end

  defp file_error(%{kind: :too_large} = assigns), do: ~H|larger than 10MB|
  defp file_error(%{kind: :not_accepted} = assigns), do: ~H|not a valid MP3 file|
  defp file_error(%{kind: :too_many_files} = assigns), do: ~H|too many files|
end