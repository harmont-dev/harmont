defmodule HarmontVm.BackendTest do
  use ExUnit.Case, async: false

  test "provider/0 is the configured backend module's last segment, underscored" do
    prev = Application.get_env(:harmont_vm, :backend)
    on_exit(fn -> Application.put_env(:harmont_vm, :backend, prev) end)

    Application.put_env(:harmont_vm, :backend, HarmontVm.Backend.Daytona)
    assert HarmontVm.Backend.provider() == "daytona"
  end
end
