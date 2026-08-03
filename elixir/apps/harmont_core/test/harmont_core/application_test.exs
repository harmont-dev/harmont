defmodule HarmontCore.ApplicationTest do
  use ExUnit.Case, async: true

  test "Goth is a child only when the GCS storage adapter is selected" do
    assert HarmontCore.Application.storage_children(Harmont.Storage.Gcs) ==
             [{Goth, name: Harmont.Goth}]

    assert HarmontCore.Application.storage_children(Harmont.Storage.Local) == []
    # The catch-all also covers an absent config key (nil).
    assert HarmontCore.Application.storage_children(nil) == []
  end
end
