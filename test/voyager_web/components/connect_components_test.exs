defmodule VoyagerWeb.ConnectComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Phoenix.Component, only: [to_form: 2]

  alias VoyagerWeb.ConnectComponents

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp count(html, selector), do: html |> query(selector) |> Enum.count()
  defp attr(html, selector, name), do: html |> query(selector) |> LazyHTML.attribute(name)

  defp path_field(attrs \\ []) do
    form = to_form(%{"key_path" => ""}, as: :ssh)

    render_component(
      &ConnectComponents.path_field/1,
      Keyword.merge([field: form[:key_path], label: "Identity file"], attrs)
    )
  end

  describe "path_field/1" do
    test "renders Browse disabled and wired to the input" do
      html = path_field()

      assert count(html, "button#ssh_key_path-browse[disabled]") == 1
      assert count(html, "#ssh_key_path-browse[phx-hook]") == 1
      assert attr(html, "#ssh_key_path-browse", "data-input-id") == ["ssh_key_path"]
      assert count(html, "input#ssh_key_path") == 1
    end

    test "starts browsing in the expanded start_dir" do
      assert attr(path_field(), "#ssh_key_path-browse", "data-default-path") ==
               [Path.expand("~/.ssh")]

      assert attr(path_field(start_dir: "/etc/ssh"), "#ssh_key_path-browse", "data-default-path") ==
               ["/etc/ssh"]
    end

    test "limits the tooltip to runs outside the desktop app" do
      assert attr(path_field(), "#ssh_key_path-browse-tip", "data-tooltip-show-when") ==
               ["browser"]
    end

    test "disabling it locks the button and the input" do
      assert count(path_field(), "#ssh_key_path-browse[data-locked]") == 0
      assert count(path_field(), "input#ssh_key_path[disabled]") == 0

      disabled = path_field(disabled: true)
      assert count(disabled, "#ssh_key_path-browse[data-locked]") == 1
      assert count(disabled, "input#ssh_key_path[disabled]") == 1
    end
  end
end
