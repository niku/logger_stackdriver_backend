import Config

case Mix.env() do
  :test ->
    config :goth, disabled: true
end
