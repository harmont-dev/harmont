defmodule HarmontVm.Backend.HandleIdTest do
  use ExUnit.Case, async: true

  alias HarmontVm.Backend.{Daytona, Freestyle, Local, Runloop}

  test "Local.handle_id/1 returns the handle name" do
    assert Local.handle_id(%{dir: "/tmp/x", name: "job-123"}) == "job-123"
  end

  test "Runloop.handle_id/1 returns the devbox id" do
    assert Runloop.handle_id(%{client: :ignored, devbox_id: "dbx_abc"}) == "dbx_abc"
  end

  test "Daytona.handle_id/1 returns the sandbox id" do
    assert Daytona.handle_id(%{client: :ignored, sandbox_id: "sbx_def"}) == "sbx_def"
  end

  test "Freestyle.handle_id/1 returns the vm id" do
    assert Freestyle.handle_id(%{vm_id: "vm_ghi"}) == "vm_ghi"
  end
end
