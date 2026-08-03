defmodule HarmontWeb.ErrorJSONTest do
  use HarmontWeb.ConnCase, async: true

  test "renders 404" do
    assert HarmontWeb.ErrorJSON.render("404.json", %{}) == %{
             errors: %{detail: "Not Found"}
           }
  end

  test "renders 500" do
    assert HarmontWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
