defmodule PinchflatWeb.Helpers.LayoutHelpers do
  @moduledoc """
  Methods for choosing the layout a controller renders with.

  These are simple, but the onboarding layout decision is repeated across every
  controller that can render a page while onboarding is still in progress.
  """

  alias Pinchflat.Settings
  alias PinchflatWeb.Layouts

  @doc """
  Returns the onboarding layout while onboarding is in progress, otherwise the app layout.

  Returns {module(), atom()}
  """
  def get_layout do
    if Settings.get!(:onboarding) do
      {Layouts, :onboarding}
    else
      {Layouts, :app}
    end
  end
end
